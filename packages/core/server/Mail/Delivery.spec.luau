local Delivery = require(script.Parent.Delivery)

-- Fake server: one clock, a manual scheduler, a persisted MailState per player.
local function world()
	local w: any = {
		t = 1000,
		timers = {},
		active = {},
		saved = {}, -- player -> MailState (what Data would persist)
		events = {},
		warnings = {},
		processed = 0,
	}
	local deps = {
		now = function()
			return w.t
		end,
		delay = function(seconds, fn)
			w.seq = (w.seq or 0) + 1
			table.insert(w.timers, { at = w.t + seconds, fn = fn, seconds = seconds, seq = w.seq })
		end,
		isActive = function(p)
			return w.active[p] == true
		end,
		getMail = function(p)
			return w.saved[p]
		end,
		update = function(p, fn)
			if not w.active[p] then
				return false
			end
			fn(w.saved[p])
			return true
		end,
		analytics = function(p, name, value)
			table.insert(w.events, { player = p, name = name, value = value })
		end,
		warn = function(msg)
			table.insert(w.warnings, msg)
		end,
		config = function()
			return w.config
		end,
		onBoxChanged = function(p, held)
			if w.onBoxChanged then
				w.onBoxChanged(p, held)
			end
		end,
	}
	w.d = Delivery.new(deps)
	function w.join(p)
		w.active[p] = true
		w.saved[p] = w.saved[p] or { seen = {}, attempts = {}, dead = {} }
	end
	function w.leave(p)
		w.active[p] = false
		w.d.forget(p)
	end
	function w.processedFn()
		return function()
			w.processed += 1
		end
	end
	-- Advance the clock and run due timers (in order).
	function w.advance(seconds)
		local target = w.t + seconds
		while true do
			table.sort(w.timers, function(a, b)
				if a.at == b.at then
					return a.seq < b.seq
				end
				return a.at < b.at
			end)
			local first = w.timers[1]
			if first == nil or first.at > target then
				break
			end
			table.remove(w.timers, 1)
			w.t = first.at
			first.fn()
		end
		w.t = target
	end
	return w
end

local function msg(id, kind)
	return { id = id, kind = kind or "gift", payload = { n = 1 }, sentAt = 1 }
end

describe("Mail.Delivery", function()
	it("delivers once and records seen before processed", function()
		local w = world()
		local p = {}
		w.join(p)
		local runs, attempt = 0, nil
		w.d.register("gift", function(_, payload, info)
			runs += 1
			attempt = info.attempt
			expect(payload.n).toBe(1)
			return nil
		end)
		w.d.deliver(p, msg("a"), w.processedFn())
		expect(runs).toBe(1)
		expect(attempt).toBe(1)
		expect(w.processed).toBe(1)
		expect(w.saved[p].seen.a).toBe(1000)
	end)

	it("handler error: not processed, retried with backoff, dead-lettered after N", function()
		local w = world()
		local p = {}
		w.join(p)
		local attempts = {}
		w.d.register("gift", function(_, _, info)
			table.insert(attempts, info.attempt)
			error("boom")
		end)
		w.d.deliver(p, msg("a"), w.processedFn())
		expect(w.processed).toBe(0)
		expect(w.saved[p].attempts.a).toBe(1)
		expect(w.timers[1].seconds).toBe(Delivery.backoff(1))
		expect(Delivery.backoff(2)).toBe(Delivery.backoff(1) * Delivery.BACKOFF_FACTOR)
		expect(Delivery.backoff(100)).toBe(Delivery.BACKOFF_MAX)
		w.advance(Delivery.backoff(1) - 0.5)
		expect(#attempts).toBe(1) -- not yet
		w.advance(10000)
		expect(#attempts).toBe(Delivery.MAX_ATTEMPTS)
		expect(attempts[2]).toBe(2)
		expect(w.processed).toBe(1)
		expect(w.saved[p].attempts.a).toBeNil()
		local dead = w.saved[p].dead[1]
		expect(dead.id).toBe("a")
		expect(dead.kind).toBe("gift")
		expect(dead.attempts).toBe(Delivery.MAX_ATTEMPTS)
		expect(dead.error).toContain("boom")
		expect(dead.payload.n).toBe(1)
		expect(#w.events).toBe(1)
		expect(w.events[1].name).toBe("MailDeadLetter")
		expect(w.events[1].value).toBe(Delivery.MAX_ATTEMPTS)
		expect(w.saved[p].seen.a).toBeNil()
	end)

	it("returning false holds the message in the mailbox: processed, no attempt counted", function()
		local w = world()
		local p = {}
		w.join(p)
		local changes = {}
		w.onBoxChanged = function(_, held)
			table.insert(changes, held)
		end
		w.d.register("gift", function()
			return false
		end)
		w.t = 2000
		w.d.deliver(p, msg("a"), w.processedFn())
		expect(w.processed).toBe(1)
		expect(w.saved[p].attempts.a).toBeNil()
		local entry = w.saved[p].box.a
		expect(entry.id).toBe("a")
		expect(entry.kind).toBe("gift")
		expect(entry.payload.n).toBe(1)
		expect(entry.sentAt).toBe(1)
		expect(entry.heldAt).toBe(2000)
		expect(#w.timers).toBe(0)
		expect(#changes).toBe(1)
		expect(changes[1]).toBe(true)
	end)

	it("player leaves mid-delivery: not processed, attempts persisted, next session continues", function()
		local w = world()
		local p = {}
		w.join(p)
		local fail = true
		local seenAttempts = {}
		w.d.register("gift", function(_, _, info)
			table.insert(seenAttempts, info.attempt)
			if fail then
				error("x")
			end
			return true
		end)
		w.d.deliver(p, msg("a"), w.processedFn())
		w.leave(p)
		w.advance(10000)
		expect(#seenAttempts).toBe(1) -- no retries after leave
		expect(w.processed).toBe(0)
		expect(w.saved[p].attempts.a).toBe(1)
		-- next session: ProfileStore re-delivers
		fail = false
		w.join(p)
		w.d.deliver(p, msg("a"), w.processedFn())
		expect(seenAttempts[2]).toBe(2)
		expect(w.processed).toBe(1)
		expect(w.saved[p].attempts.a).toBeNil()
	end)

	it("player leaves while a handler runs: never processed", function()
		local w = world()
		local p = {}
		w.join(p)
		w.d.register("gift", function()
			w.leave(p) -- e.g. handler yielded and the player left
			return true
		end)
		w.d.deliver(p, msg("a"), w.processedFn())
		expect(w.processed).toBe(0)
		expect(w.saved[p].seen.a).toBeNil()
	end)

	it("server shutdown stops retries and processing", function()
		local w = world()
		local p = {}
		w.join(p)
		local runs = 0
		w.d.register("gift", function()
			runs += 1
			error("x")
		end)
		w.d.deliver(p, msg("a"), w.processedFn())
		w.d.stop()
		w.advance(10000)
		expect(runs).toBe(1)
		expect(w.processed).toBe(0)
		w.d.deliver(p, msg("b"), w.processedFn())
		expect(runs).toBe(1)
		expect(w.saved[p].attempts.a).toBe(1)
	end)

	it("duplicates: same id later, and same key twice in flight, run handlers once", function()
		local w = world()
		local p = {}
		w.join(p)
		local runs = 0
		w.d.register("gift", function()
			runs += 1
			return true
		end)
		w.d.deliver(p, msg("k"), w.processedFn())
		w.d.deliver(p, msg("k"), w.processedFn())
		expect(runs).toBe(1)
		expect(w.processed).toBe(2)

		-- two copies of a key arriving while the first is still retrying
		local w2 = world()
		w2.join(p)
		local fail, runs2 = true, 0
		w2.d.register("gift", function()
			runs2 += 1
			if fail then
				error("not yet")
			end
			return true
		end)
		w2.d.deliver(p, msg("k"), w2.processedFn())
		w2.d.deliver(p, msg("k"), w2.processedFn())
		expect(runs2).toBe(1)
		fail = false
		w2.advance(10000)
		expect(runs2).toBe(2)
		expect(w2.processed).toBe(2)
	end)

	it("two handlers where one fails: not processed, both re-run on retry", function()
		local w = world()
		local p = {}
		w.join(p)
		local a, b, failB = 0, 0, true
		w.d.register("gift", function()
			a += 1
			return true
		end)
		w.d.register("gift", function()
			b += 1
			if failB then
				error("b failed")
			end
			return true
		end)
		w.d.deliver(p, msg("m"), w.processedFn())
		expect(a).toBe(1)
		expect(b).toBe(1)
		expect(w.processed).toBe(0)
		failB = false
		w.advance(Delivery.backoff(1))
		expect(a).toBe(2)
		expect(b).toBe(2)
		expect(w.processed).toBe(1)
	end)

	it("stays pending until a handler registers, without counting attempts", function()
		local w = world()
		local p, q = {}, {}
		w.join(p)
		w.join(q)
		w.d.deliver(p, msg("x", "bottle"), w.processedFn())
		w.d.deliver(q, msg("y", "bottle"), w.processedFn())
		expect(w.processed).toBe(0)
		expect(w.saved[p].attempts.x).toBeNil()
		w.leave(q) -- offline players are not delivered to
		local runs = 0
		w.d.register("bottle", function()
			runs += 1
			return true
		end)
		expect(runs).toBe(1)
		expect(w.processed).toBe(1)
		expect(w.saved[p].seen.x).toBe(1000)
	end)

	it("disconnect removes the handler", function()
		local w = world()
		local p = {}
		w.join(p)
		local runs = 0
		local off = w.d.register("gift", function()
			runs += 1
			return true
		end)
		off()
		w.d.deliver(p, msg("a"), w.processedFn())
		expect(runs).toBe(0)
		expect(w.processed).toBe(0)
	end)

	it("malformed messages are consumed and warned once", function()
		local w = world()
		local p = {}
		w.join(p)
		w.d.deliver(p, "junk", w.processedFn())
		w.d.deliver(p, { id = "bad id!", kind = "gift", payload = {} }, w.processedFn())
		w.d.deliver(p, { kind = "has space", payload = {} }, w.processedFn())
		expect(w.processed).toBe(3)
		expect(#w.warnings).toBe(1)
	end)

	it("v1.0 messages without an id get a deterministic id", function()
		local w = world()
		local p = {}
		w.join(p)
		local id
		w.d.register("gift", function(_, _, info)
			id = info.id
			return true
		end)
		w.d.deliver(p, { kind = "gift", payload = {}, sentAt = 42 }, w.processedFn())
		expect(id).toBe(Delivery.legacyId("gift", 42, {}))
		expect(string.sub(id, 1, 15)).toBe("legacy-gift-42-")
		expect(w.processed).toBe(1)
	end)

	it("N6: two legacy messages of one kind in the same second with different payloads both run", function()
		local w = world()
		local p = {}
		w.join(p)
		local got = {}
		w.d.register("gift", function(_, payload)
			table.insert(got, payload.item)
			return true
		end)
		w.d.deliver(p, { kind = "gift", payload = { item = "a" }, sentAt = 42 }, w.processedFn())
		w.d.deliver(p, { kind = "gift", payload = { item = "b" }, sentAt = 42 }, w.processedFn())
		expect(#got).toBe(2)
		expect(w.processed).toBe(2)
		-- key order does not change the id; a different payload does
		expect(Delivery.legacyId("k", 1, { a = 1, b = { 2, 3 } })).toBe(
			Delivery.legacyId("k", 1, { b = { 2, 3 }, a = 1 })
		)
		expect(Delivery.legacyId("k", 1, { a = 1 }) == Delivery.legacyId("k", 1, { a = 2 })).toBe(false)
	end)

	it("bounds seen (oldest pruned) and dead (oldest dropped)", function()
		local seen = {}
		for i = 1, Delivery.MAX_SEEN + 10 do
			seen["id" .. i] = i
		end
		Delivery.pruneSeen(seen, Delivery.MAX_SEEN)
		local n = 0
		for _ in seen do
			n += 1
		end
		expect(n).toBe(Delivery.MAX_SEEN)
		expect(seen.id1).toBeNil()
		expect(seen.id10).toBeNil()
		expect(seen.id11).toBe(11)

		local w = world()
		local p = {}
		w.join(p)
		w.d.register("gift", function()
			error("x")
		end)
		for i = 1, Delivery.MAX_DEAD + 3 do
			w.d.deliver(p, msg("d" .. i), w.processedFn())
		end
		w.advance(100000)
		expect(#w.saved[p].dead).toBe(Delivery.MAX_DEAD)
		expect(w.saved[p].dead[1].id).toBe("d4")
	end)
end)

describe("Mail.Delivery mailbox (N1)", function()
	local function heldWorld(cfg)
		local w = world()
		w.config = cfg
		local p = {}
		w.join(p)
		w.room = false
		w.runs = 0
		w.d.register("gift", function(_, _, info)
			w.runs += 1
			w.lastInfo = info
			if w.boom then
				error("boom")
			end
			if w.claimHook then
				w.claimHook()
			end
			return w.room
		end)
		return w, p
	end

	it("errors count toward maxAttempts, false never does (config maxAttempts + backoff)", function()
		local w, p = heldWorld({ maxAttempts = 3, backoff = { base = 1, factor = 3, max = 5 } })
		w.boom = true
		w.d.deliver(p, msg("e"), w.processedFn())
		expect(w.saved[p].attempts.e).toBe(1)
		expect(w.timers[1].seconds).toBe(1)
		w.advance(1)
		expect(w.timers[1].seconds).toBe(3)
		w.advance(3)
		expect(w.processed).toBe(1) -- 3rd error -> dead letter
		expect(w.saved[p].dead[1].attempts).toBe(3)
		-- false: held at once, whatever the attempts setting
		w.boom = false
		w.d.deliver(p, msg("f"), w.processedFn())
		expect(w.saved[p].box.f).never.toBeNil()
		expect(w.saved[p].attempts.f).toBeNil()
		expect(w.processed).toBe(2)
	end)

	it("settings: defaults and config overrides, invalid values fall back", function()
		local d = Delivery.settings(nil)
		expect(d.maxAttempts).toBe(10)
		expect(d.base).toBe(30)
		expect(d.factor).toBe(2)
		expect(d.max).toBe(900)
		expect(d.mailboxCap).toBe(100)
		local c = Delivery.settings({
			maxAttempts = 2,
			mailboxCap = 0 / 0,
			backoff = { base = -1, factor = 4, max = 8 },
		})
		expect(c.maxAttempts).toBe(2)
		expect(c.mailboxCap).toBe(100)
		expect(c.base).toBe(30)
		expect(Delivery.backoff(1, { backoff = { base = 2, factor = 4, max = 8 } })).toBe(2)
		expect(Delivery.backoff(2, { backoff = { base = 2, factor = 4, max = 8 } })).toBe(8)
		expect(Delivery.backoff(3, { backoff = { base = 2, factor = 4, max = 8 } })).toBe(8)
		expect(Delivery.backoff(1)).toBe(30)
		expect(Delivery.backoff(100)).toBe(900)
	end)

	it("an id already in the box is a duplicate: processed, handlers not run", function()
		local w, p = heldWorld()
		w.d.deliver(p, msg("h"), w.processedFn())
		expect(w.runs).toBe(1)
		w.d.deliver(p, msg("h"), w.processedFn())
		expect(w.runs).toBe(1)
		expect(w.processed).toBe(2)
	end)

	it("box at mailboxCap: nothing written, not processed, warned once", function()
		local w, p = heldWorld({ mailboxCap = 2 })
		w.d.deliver(p, msg("1"), w.processedFn())
		w.d.deliver(p, msg("2"), w.processedFn())
		w.d.deliver(p, msg("3"), w.processedFn())
		w.d.deliver(p, msg("4"), w.processedFn())
		expect(w.processed).toBe(2)
		expect(w.saved[p].box["3"]).toBeNil()
		expect(Delivery.boxCount(w.saved[p])).toBe(2)
		local full = 0
		for _, m in w.warnings do
			if string.find(m, "mailbox full", 1, true) then
				full += 1
			end
		end
		expect(full).toBe(1)
		-- next session (room in the box) the queued copy is offered again and held
		w.room = true
		expect(w.d.claim(p, "1")).toBe(true)
		w.room = false
		w.leave(p)
		w.join(p)
		w.d.deliver(p, msg("3"), w.processedFn())
		expect(w.saved[p].box["3"]).never.toBeNil()
	end)

	it("pending: copies, oldest heldAt first, tie by id; empty when not loaded", function()
		local w, p = heldWorld()
		w.t = 50
		w.d.deliver(p, msg("b"), w.processedFn())
		w.d.deliver(p, msg("a"), w.processedFn())
		w.t = 10
		w.d.deliver(p, msg("z"), w.processedFn())
		local list = w.d.pending(p)
		expect(#list).toBe(3)
		expect(list[1].id).toBe("z")
		expect(list[2].id).toBe("a")
		expect(list[3].id).toBe("b")
		list[1].kind = "changed"
		expect(w.saved[p].box.z.kind).toBe("gift")
		w.active[p] = false
		expect(#w.d.pending(p)).toBe(0)
	end)

	it("claim: ok removes from box, writes seen, notifies; attempt numbering", function()
		local w, p = heldWorld()
		local changes = {}
		w.onBoxChanged = function(_, held)
			table.insert(changes, held)
		end
		w.d.deliver(p, msg("c"), w.processedFn())
		w.room = true
		w.t = 3000
		local ok, reason = w.d.claim(p, "c")
		expect(ok).toBe(true)
		expect(reason).toBeNil()
		expect(w.lastInfo.attempt).toBe(1)
		expect(w.saved[p].box.c).toBeNil()
		expect(w.saved[p].seen.c).toBe(3000)
		expect(changes[1]).toBe(true)
		expect(changes[2]).toBe(false)
		-- re-delivery of the same id afterwards is a duplicate
		local runs = w.runs
		w.d.deliver(p, msg("c"), w.processedFn())
		expect(w.runs).toBe(runs)
	end)

	it("claim: still_held / error stay in the box (never dead-lettered); attempt grows on errors", function()
		local w, p = heldWorld({ maxAttempts = 1 })
		w.d.deliver(p, msg("s"), w.processedFn())
		local ok, reason = w.d.claim(p, "s")
		expect(ok).toBe(false)
		expect(reason).toBe("still_held")
		w.boom = true
		ok, reason = w.d.claim(p, "s")
		expect(reason).toBe("error")
		ok, reason = w.d.claim(p, "s")
		expect(reason).toBe("error")
		expect(w.lastInfo.attempt).toBe(2)
		expect(#w.saved[p].dead).toBe(0)
		expect(w.saved[p].box.s).never.toBeNil()
		w.boom = false
		w.room = true
		ok = w.d.claim(p, "s")
		expect(ok).toBe(true)
		expect(w.lastInfo.attempt).toBe(3)
		expect(w.saved[p].attempts.s).toBeNil()
	end)

	it("claim reasons: not_found, not_loaded, no_handler, busy", function()
		local w, p = heldWorld()
		w.d.deliver(p, msg("x"), w.processedFn())
		expect(select(2, w.d.claim(p, "nope"))).toBe("not_found")
		expect(select(2, w.d.claim(p, 5))).toBe("not_found")
		-- busy: a handler re-enters claim for the same message
		local inner
		w.claimHook = function()
			w.claimHook = nil
			inner = table.pack(w.d.claim(p, "x"))
		end
		w.room = true
		expect(w.d.claim(p, "x")).toBe(true)
		expect(inner[2]).toBe("busy")
		-- no handler for the kind
		w.saved[p].box.k = { id = "k", kind = "other", payload = {}, sentAt = 1, heldAt = 1 }
		expect(select(2, w.d.claim(p, "k"))).toBe("no_handler")
		w.active[p] = false
		expect(select(2, w.d.claim(p, "k"))).toBe("not_loaded")
	end)

	it("replay moves a dead letter into the mailbox", function()
		local w, p = heldWorld({ maxAttempts = 1 })
		w.boom = true
		w.d.deliver(p, msg("d"), w.processedFn())
		expect(#w.saved[p].dead).toBe(1)
		expect(select(2, w.d.replay(p, "missing"))).toBe("not_found")
		expect(w.d.replay(p, "d")).toBe(true)
		expect(#w.saved[p].dead).toBe(0)
		expect(w.saved[p].box.d.kind).toBe("gift")
		w.boom = false
		w.room = true
		expect(w.d.claim(p, "d")).toBe(true)
	end)
end)
