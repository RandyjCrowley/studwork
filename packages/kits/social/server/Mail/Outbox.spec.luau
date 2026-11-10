local Outbox = require(script.Parent.Outbox)
local Transaction = require(script.Parent.Parent.Parent.Parent.Parent.core.server.Data.Transaction)

local function encode(v)
	-- tiny JSON-size stand-in: good enough for MailValidate's size check
	local n = 0
	local function walk(x)
		n += 4
		if type(x) == "table" then
			for k, c in x do
				n += #tostring(k)
				walk(c)
			end
		elseif type(x) == "string" then
			n += #x
		end
	end
	walk(v)
	return string.rep("x", n)
end

-- One sender: persisted profile + memory (real Transaction), injectable save/send results.
local function world()
	local w: any = {
		t = 100,
		timers = {},
		sent = {},
		saves = 0,
		saveOk = true,
		sendOk = true,
		active = true,
		warnings = {},
	}
	w.player = { UserId = 1 }
	w.persisted = { mail = { seen = {}, attempts = {}, dead = {} }, inventory = {} }
	local function deepCopy(v)
		if type(v) ~= "table" then
			return v
		end
		local o = {}
		for k, x in v do
			o[k] = deepCopy(x)
		end
		return o
	end
	function w.load()
		w.memory = deepCopy(w.persisted)
		w.tx = Transaction.newState()
		w.active = true
	end
	function w.crash()
		w.active = false
		w.memory = nil
		w.timers = {}
		w.o.forget(w.player)
	end
	function w.update(fn)
		if not w.active then
			return false
		end
		Transaction.run(w.tx, w.memory, fn)
		return true
	end
	w.o = Outbox.new({
		now = function()
			return w.t
		end,
		delay = function(s, fn)
			table.insert(w.timers, { at = w.t + s, fn = fn, s = s })
		end,
		isActive = function()
			return w.active
		end,
		getOutbox = function()
			return w.memory and w.memory.mail.outbox
		end,
		save = function()
			w.saves += 1
			if w.onSave then
				w.onSave()
			end
			if w.saveOk then
				w.persisted = deepCopy(w.memory)
			end
			return w.saveOk
		end,
		send = function(entry)
			if w.onSend then
				w.onSend(entry)
			end
			if w.sendOk then
				table.insert(w.sent, entry.key)
			end
			return w.sendOk
		end,
		remove = function(_, key)
			return w.update(function(d)
				d.mail.outbox[key] = nil
			end)
		end,
		backoff = function(n)
			return 10 * n
		end,
		warn = function(m)
			table.insert(w.warnings, m)
		end,
	})
	function w.write(key, extra)
		local queue = {}
		local ok
		w.update(function(d)
			local tx = {
				player = w.player,
				data = d,
				after = function(fn)
					table.insert(queue, fn)
				end,
			}
			if extra then
				extra(d)
			end
			ok = Outbox.writeInto(tx, 2, "core_gift", { n = 1 }, key, w.t, encode, function()
				w.o.flush(w.player)
			end)
		end)
		return ok, queue
	end
	function w.advance(s)
		local target = w.t + s
		while true do
			table.sort(w.timers, function(a, b)
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
	w.load()
	return w
end

describe("Mail.Outbox", function()
	it("writeInto validates (userId, kind, payload, required key) and rejects a duplicate key", function()
		local w = world()
		local function try(to, kind, payload, key)
			local ok
			w.update(function(d)
				local tx = { player = w.player, data = d, after = function() end }
				ok = Outbox.writeInto(tx, to, kind, payload, key, 1, encode, function() end)
			end)
			return ok
		end
		expect(try(0, "k", {}, "a")).toBe(false)
		expect(try(2, "bad kind!", {}, "a")).toBe(false)
		expect(try(2, "k", "x", "a")).toBe(false)
		expect(try(2, "k", {}, nil)).toBe(false)
		expect(try(2, "k", {}, "has space")).toBe(false)
		expect(w.memory.mail.outbox).toBeNil()
		expect(try(2, "k", { a = 1 }, "a")).toBe(true)
		expect(try(2, "k", { a = 2 }, "a")).toBe(false)
		expect(w.memory.mail.outbox.a.payload.a).toBe(1)
		expect(w.memory.mail.outbox.a.toUserId).toBe(2)
	end)

	it("flush after commit: saves first, then sends with the key, then removes the entry", function()
		local w = world()
		local order = {}
		w.onSave = function()
			table.insert(order, "save")
		end
		w.onSend = function()
			table.insert(order, "send")
		end
		local ok, queue = w.write("k1")
		expect(ok).toBe(true)
		expect(#queue).toBe(1)
		expect(#w.sent).toBe(0) -- nothing before commit
		queue[1]()
		expect(order[1]).toBe("save")
		expect(order[2]).toBe("send")
		expect(w.sent[1]).toBe("k1")
		expect(w.persisted.mail.outbox.k1).never.toBeNil() -- the save that made it durable
		expect(w.memory.mail.outbox.k1).toBeNil()
	end)

	it("save fails: nothing is sent, retried with backoff while online", function()
		local w = world()
		w.saveOk = false
		local _, queue = w.write("k1")
		queue[1]()
		expect(#w.sent).toBe(0)
		expect(#w.timers).toBe(1)
		expect(w.timers[1].s).toBe(10)
		w.advance(10)
		expect(w.timers[1].s).toBe(20)
		w.saveOk = true
		w.advance(20)
		expect(w.sent[1]).toBe("k1")
		expect(#w.timers).toBe(0)
		expect(w.o.attempts(w.player)).toBe(0)
	end)

	it("send fails: entry kept, retried; a confirmed entry is not saved again", function()
		local w = world()
		w.sendOk = false
		local _, queue = w.write("k1")
		queue[1]()
		expect(w.saves).toBe(1)
		expect(w.memory.mail.outbox.k1).never.toBeNil()
		w.sendOk = true
		w.advance(10)
		expect(w.saves).toBe(1)
		expect(w.sent[1]).toBe("k1")
		expect(w.memory.mail.outbox.k1).toBeNil()
	end)

	it("offline: no retries; next load flushes leftovers without a save", function()
		local w = world()
		w.sendOk = false
		local _, queue = w.write("k1")
		queue[1]()
		w.crash()
		expect(#w.timers).toBe(0)
		w.sendOk = true
		w.load()
		w.o.markLoaded(w.player)
		w.o.flush(w.player)
		expect(w.saves).toBe(1) -- only the first one
		expect(w.sent[1]).toBe("k1")
	end)

	it("crash before the save: the entry (and its cause) never existed, nothing sent", function()
		local w = world()
		w.write("k1", function(d)
			d.inventory.u1 = nil
		end)
		w.crash()
		w.load()
		w.o.markLoaded(w.player)
		w.o.flush(w.player)
		expect(#w.sent).toBe(0)
		expect(w.memory.mail.outbox).toBeNil()
	end)

	it("crash after send but before the removal is saved: resent with the SAME key", function()
		local w = world()
		local _, queue = w.write("k1")
		queue[1]()
		expect(w.persisted.mail.outbox.k1).never.toBeNil()
		w.crash()
		w.load()
		w.o.markLoaded(w.player)
		w.o.flush(w.player)
		expect(#w.sent).toBe(2)
		expect(w.sent[2]).toBe("k1")
	end)

	it("a flush requested while one runs runs again right after (new entry saved too)", function()
		local w = world()
		local _, q1 = w.write("k1")
		w.onSend = function(entry)
			if entry.key == "k1" then
				w.onSend = nil
				local _, q2 = w.write("k2")
				q2[1]() -- re-entrant flush request
			end
		end
		q1[1]()
		expect(#w.sent).toBe(2)
		expect(w.saves).toBe(2)
		expect(w.memory.mail.outbox.k2).toBeNil()
	end)
end)
