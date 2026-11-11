--[[
	R1 soak (known issue R1, core-v1.3.0 agent C): 2000+ gifts to one recipient, driven through the
	REAL pure Mail parts (Outbox, Gifts, Escrow, Delivery) with a fake ProfileStore message queue
	that keeps at most 1000 messages per user and DROPS THE OLDEST beyond that, exactly like
	ProfileStore's MAX_MESSAGE_QUEUE. Every item is tracked by uid; after every step each uid must
	be in exactly one place:
	  sender inventory | sender outbox | sender `sent` with escrow state "p" (in the queue) |
	  sender mailbox | recipient inventory | recipient mailbox
	and the queue must never drop a message.
]]

local Delivery = require(script.Parent.Delivery)
local Escrow = require(script.Parent.Escrow)
local Gifts = require(script.Parent.Gifts)
local Outbox = require(script.Parent.Outbox)

local DAY = 86400
local QUEUE_LIMIT = 1000
local KIND = "core_gift"
local RECIPIENT = 9000

local function newWorld(opts: any?)
	local o = opts or {}
	local w: any = {
		t = 1_000_000,
		timers = {},
		queues = {}, -- userId -> { raw messages }
		dropped = 0,
		maxQueue = 0,
		players = {},
		store = Escrow.memoryStore(o.failEvery),
		cap = o.cap or 100,
		returnAfter = (o.returnAfterDays or 14) * DAY,
		invCap = o.invCap or 1_000_000,
		uids = {},
	}
	w.escrow = Escrow.new(w.store)

	function w.delay(seconds: number, fn: () -> ())
		table.insert(w.timers, { at = w.t + seconds, fn = fn })
	end
	function w.advance(seconds: number)
		local stop = w.t + seconds
		while true do
			table.sort(w.timers, function(a, b)
				return a.at < b.at
			end)
			local nextTimer = w.timers[1]
			if nextTimer == nil or nextTimer.at > stop then
				break
			end
			table.remove(w.timers, 1)
			w.t = math.max(w.t, nextTimer.at)
			nextTimer.fn()
		end
		w.t = stop
	end

	function w.push(userId: number, raw: any)
		local q = w.queues[userId] or {}
		w.queues[userId] = q
		table.insert(q, raw)
		while #q > QUEUE_LIMIT do
			table.remove(q, 1)
			w.dropped += 1
		end
		w.maxQueue = math.max(w.maxQueue, #q)
	end

	-- one player: inventory (uid -> true), mail state, the pure parts wired like Mail/init.luau
	function w.player(userId: number)
		local p: any =
			{ UserId = userId, inv = {}, mail = { seen = {}, attempts = {}, dead = {} }, active = false }
		w.players[userId] = p
		local function update(_: any, fn: (mail: any) -> ()): boolean
			if not p.active then
				return false
			end
			fn(p.mail)
			return true
		end
		p.delivery = Delivery.new({
			now = function()
				return w.t
			end,
			delay = w.delay,
			isActive = function()
				return p.active
			end,
			getMail = function()
				return p.mail
			end,
			update = update,
			analytics = function() end,
			warn = function() end,
			take = function(_: any, msg: any): string
				return w.escrow.take(userId, msg.id)
			end,
			consumed = function(_: any, msg: any)
				w.escrow.release(userId, msg.id)
			end,
		})
		-- Inventory's core_gift handler: full inventory -> held
		p.delivery.register(KIND, function(_: any, payload: any): boolean
			local count = 0
			for _ in p.inv do
				count += 1
			end
			local uid = payload.item.uid
			if p.inv[uid] then
				return true -- duplicate copy: idempotent
			end
			if count >= w.invCap then
				return false
			end
			p.inv[uid] = true
			return true
		end)
		local function handBack(entry: any, why: string)
			local id
			update(p, function(mail)
				id = Gifts.handBackInto(mail, entry, why, w.t)
			end)
			p.delivery.claim(p, id) -- auto-claim, as Mail does
		end
		p.handBack = handBack
		p.outbox = Outbox.new({
			now = function()
				return w.t
			end,
			delay = w.delay,
			isActive = function()
				return p.active
			end,
			getOutbox = function()
				return p.mail.outbox
			end,
			save = function()
				return true
			end,
			send = function(entry: any): boolean
				w.push(entry.toUserId, {
					id = entry.key,
					kind = entry.kind,
					payload = entry.payload,
					sentAt = entry.at,
					t = entry.t,
					from = entry.from,
				})
				return true
			end,
			remove = function(_: any, key: string): boolean
				return update(p, function(mail)
					Gifts.recordSent(mail, key)
				end)
			end,
			backoff = function()
				return 30
			end,
			warn = function() end,
			prepare = function(_: any, entry: any): string
				local verdict = Gifts.prepare(w.escrow, entry, w.cap)
				if verdict == "full" then
					handBack(entry, "full")
					return "done"
				end
				return verdict
			end,
		})
		return p
	end

	function w.join(p: any)
		p.active = true
		p.outbox.markLoaded(p)
		local q = w.queues[p.UserId] or {}
		for _, raw in table.clone(q) do
			p.delivery.deliver(p, raw, function()
				local i = table.find(q, raw)
				if i then
					table.remove(q, i)
				end
			end)
		end
		p.outbox.flush(p)
	end

	function w.leave(p: any)
		p.active = false
		p.delivery.forget(p)
		p.outbox.forget(p)
	end

	function w.give(p: any, n: number)
		for i = 1, n do
			local uid = `u{p.UserId}-{i}`
			p.inv[uid] = true
			table.insert(w.uids, uid)
		end
	end

	-- Inventory.sendGift: the item leaves the inventory and enters the outbox in ONE tx; a
	-- refused write discards the tx (the item stays).
	function w.gift(p: any, toUserId: number, uid: string): boolean
		local key = "gift-" .. uid
		local working = table.clone(p.mail)
		working.outbox = if p.mail.outbox then table.clone(p.mail.outbox) else nil
		local tx = { data = { mail = working }, after = function() end }
		local ok = Outbox.writeInto(
			tx,
			toUserId,
			KIND,
			{ item = { uid = uid, itemId = "gem" } },
			key,
			w.t,
			function(v)
				return tostring(v)
			end,
			function() end
		)
		if not ok then
			return false
		end
		working.outbox[key].t = true
		working.outbox[key].from = p.UserId
		p.mail = working
		p.inv[uid] = nil
		p.outbox.flush(p)
		return true
	end

	function w.sweep(p: any)
		for _, item in Gifts.due(p.mail, w.t, w.returnAfter) do
			local verdict = Gifts.reclaim(w.escrow, item.key, item.entry)
			local e = item.entry
			if verdict == "return" then
				p.handBack({ key = item.key, kind = e.kind, payload = e.payload, at = e.at }, "returned")
			elseif verdict == "forget" then
				p.mail.sent[item.key] = nil
			end
		end
	end

	-- where each uid is right now
	function w.custody(): { [string]: number }
		local count: { [string]: number } = {}
		local function add(uid: any)
			if type(uid) == "string" then
				count[uid] = (count[uid] or 0) + 1
			end
		end
		local record = w.store.values[Escrow.recordKey(RECIPIENT)] or {}
		for _, p in w.players do
			for uid in p.inv do
				add(uid)
			end
			for _, entry in p.mail.outbox or {} do
				add(entry.payload.item.uid)
			end
			for key, entry in p.mail.sent or {} do
				local r = record[key]
				if r and r.s == Escrow.PENDING then
					add(entry.payload.item.uid)
				end
			end
			for _, entry in p.mail.box or {} do
				add(entry.payload.item.uid)
			end
		end
		return count
	end

	function w.assertConserved()
		local count = w.custody()
		local lost, doubled = 0, 0
		for _, uid in w.uids do
			local n = count[uid] or 0
			if n == 0 then
				lost += 1
			elseif n > 1 then
				doubled += 1
			end
		end
		expect(lost).toBe(0)
		expect(doubled).toBe(0)
		expect(w.dropped).toBe(0)
	end

	return w
end

local function senders(w: any, n: number, each: number): { any }
	local list = {}
	for i = 1, n do
		local p = w.player(i)
		w.give(p, each)
		w.join(p)
		table.insert(list, p)
	end
	return list
end

local function giftAll(w: any, list: { any }): (number, number)
	local accepted, refused = 0, 0
	for _, p in list do
		local mine = {}
		for uid in p.inv do
			table.insert(mine, uid)
		end
		table.sort(mine)
		for _, uid in mine do
			if w.gift(p, RECIPIENT, uid) then
				accepted += 1
			else
				refused += 1
			end
		end
	end
	return accepted, refused
end

local function inv(p: any): number
	local n = 0
	for _ in p.inv do
		n += 1
	end
	return n
end

local function queued(w: any): number
	return #(w.queues[RECIPIENT] or {})
end

describe("R1 soak: 2400 gifts to a recipient who never logs in", function()
	it("caps the queue, hands every refused and every uncollected gift back, loses nothing", function()
		local w = newWorld({ cap = 100 })
		local list = senders(w, 24, 100) -- 2400 items
		w.player(RECIPIENT) -- never joins
		giftAll(w, list)
		w.assertConserved()
		-- at most `cap` escrowed gifts ever reach the recipient's queue; the rest bounced
		expect(queued(w)).toBe(100)
		expect(w.maxQueue <= 100).toBe(true)
		expect(Escrow.count(w.store.values[Escrow.recordKey(RECIPIENT)])).toBe(100)
		local home = 0
		for _, p in list do
			home += inv(p)
		end
		expect(home).toBe(2300) -- refused gifts came straight back (auto-claimed)

		-- 13 days: nothing returns yet
		w.advance(13 * DAY)
		for _, p in list do
			w.sweep(p)
		end
		w.assertConserved()
		home = 0
		for _, p in list do
			home += inv(p)
		end
		expect(home).toBe(2300)

		-- day 15: every uncollected gift is back with its sender
		w.advance(2 * DAY)
		for _, p in list do
			w.sweep(p)
		end
		w.assertConserved()
		home = 0
		for _, p in list do
			home += inv(p)
			expect((next(p.mail.sent or {}))).toBeNil()
		end
		expect(home).toBe(2400)
		expect(w.dropped).toBe(0)
	end)

	it("a recipient who finally logs in after the returns gets nothing twice", function()
		local w = newWorld({ cap = 100 })
		local list = senders(w, 21, 100) -- 2100 items
		local r = w.player(RECIPIENT)
		giftAll(w, list)
		w.advance(15 * DAY)
		for _, p in list do
			w.sweep(p)
		end
		w.join(r) -- reads the 100 returned copies from the queue
		w.assertConserved()
		expect(inv(r)).toBe(0)
		expect(queued(w)).toBe(0) -- consumed (dropped as "returned")
		expect(w.store.values[Escrow.recordKey(RECIPIENT)]).toBeNil() -- record cleaned up
		-- the cap is free again: new gifts flow
		local p = list[1]
		w.give(p, 1)
		expect(w.gift(p, RECIPIENT, w.uids[#w.uids])).toBe(true)
		w.assertConserved()
	end)

	it("a recipient who logs in before the deadline keeps what they took; the senders forget it", function()
		local w = newWorld({ cap = 100 })
		local list = senders(w, 20, 100)
		local r = w.player(RECIPIENT)
		giftAll(w, list)
		w.advance(3 * DAY)
		w.join(r)
		w.assertConserved()
		expect(inv(r)).toBe(100)
		w.leave(r)
		-- 2nd wave: the cap was released when the recipient consumed the first 100
		local accepted = 0
		for _, p in list do
			local mine = {}
			for uid in p.inv do
				table.insert(mine, uid)
			end
			table.sort(mine)
			for _, uid in mine do
				if w.gift(p, RECIPIENT, uid) then
					accepted += 1
				end
			end
		end
		expect(queued(w)).toBe(100)
		w.assertConserved()
		w.advance(15 * DAY)
		for _, p in list do
			w.sweep(p)
		end
		w.assertConserved()
		expect(inv(r)).toBe(100) -- kept the first wave
		local home = 0
		for _, p in list do
			home += inv(p)
			expect((next(p.mail.sent or {}))).toBeNil()
		end
		expect(home).toBe(1900)
	end)

	it("a full recipient inventory holds gifts in the mailbox: never returned, never lost", function()
		local w = newWorld({ cap = 100, invCap = 10 })
		local list = senders(w, 20, 100)
		local r = w.player(RECIPIENT)
		giftAll(w, list)
		w.join(r) -- 10 into the inventory, 90 held in the mailbox (custody: recipient)
		expect(inv(r)).toBe(10)
		expect(#r.delivery.pending(r)).toBe(90)
		w.advance(30 * DAY)
		for _, p in list do
			w.sweep(p)
		end
		w.assertConserved()
		expect(#r.delivery.pending(r)).toBe(90) -- no time limit on held mail
	end)

	it("a sender crash between reclaim and the hand-back returns the gift exactly once", function()
		local w = newWorld({ cap = 5 })
		local list = senders(w, 1, 5)
		w.player(RECIPIENT)
		giftAll(w, list)
		w.advance(15 * DAY)
		local p = list[1]
		-- reclaim wins in the store, then the server dies before the hand-back commits
		for _, item in Gifts.due(p.mail, w.t, w.returnAfter) do
			expect(Gifts.reclaim(w.escrow, item.key, item.entry)).toBe("return")
		end
		w.leave(p)
		w.join(p)
		w.sweep(p) -- the next session repeats the reclaim: still "return", same mailbox ids
		w.assertConserved()
		expect(inv(p)).toBe(5)
	end)

	it("store failures only delay: no gift is lost or doubled", function()
		local w = newWorld({ cap = 50, failEvery = 7 })
		local list = senders(w, 21, 100)
		local r = w.player(RECIPIENT)
		giftAll(w, list)
		for _ = 1, 20 do
			w.advance(60) -- outbox retries after backoff
		end
		w.assertConserved()
		w.advance(15 * DAY)
		for _ = 1, 5 do
			for _, p in list do
				w.sweep(p)
			end
		end
		w.join(r)
		for _ = 1, 20 do
			w.advance(900)
		end
		w.assertConserved()
		expect(w.maxQueue <= 50).toBe(true)
	end)
end)

describe("R7: duplicate detection against R1's numbers", function()
	it("a resend of any of 2000 processed gifts is still recognised", function()
		local w = newWorld({ cap = 2000 })
		local list = senders(w, 20, 100)
		local r = w.player(RECIPIENT)
		r.active = true
		local copies = {}
		for _, p in list do
			for uid in p.inv do
				local raw = {
					id = "gift-" .. uid,
					kind = KIND,
					payload = { item = { uid = uid, itemId = "gem" } },
					sentAt = w.t,
				}
				table.insert(copies, raw)
			end
		end
		for _, raw in copies do
			r.delivery.deliver(r, raw, function() end)
			w.t += 1
		end
		expect(inv(r)).toBe(2000)
		-- the receiver loses every item (sold, gifted on), then every message is resent
		r.inv = {}
		for _, raw in copies do
			r.delivery.deliver(r, raw, function() end)
		end
		expect(inv(r)).toBe(0)
	end)
end)
