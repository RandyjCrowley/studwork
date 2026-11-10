local Gift = require(script.Parent.Gift)
local Delivery = require(script.Parent.Parent.Mail.Delivery)
local Outbox = require(script.Parent.Parent.Mail.Outbox)
local Transaction = require(script.Parent.Parent.Data.Transaction)

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local o = {}
	for k, x in v do
		o[k] = deepCopy(x)
	end
	return o
end

local function encode(v: any): string
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

local function sortedKeys(t: any): { any }
	local keys = {}
	if type(t) == "table" then
		for k in t do
			table.insert(keys, k)
		end
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

--[[
	Simulated world: users with a persisted profile + a ProfileStore message queue, up to two
	"servers" each with its own Delivery (receiver side) and Outbox (sender side), the real
	Data/Transaction for every update, and failure knobs (save fails, MessageAsync fails, crash).

	ProfileStore model: a message handed to deliver() is "received" for that session (never
	offered again in it); processed() locks it; a SUCCESSFUL save of the profile removes locked
	messages from the stored queue. A crash/failed final save loses memory and the locks.
]]
local function newWorld(opts: any?)
	opts = opts or {}
	local w: any = {
		t = 1000,
		users = {},
		sessions = {}, -- userId -> session
		servers = {},
		timers = {},
		caps = {},
		rngState = opts.seed or 1,
		pSaveFail = opts.pSaveFail or 0,
		pSendFail = opts.pSendFail or 0,
		mailboxCap = opts.mailboxCap or 100,
		history = {}, -- every message ever queued (for re-delivery)
		keySeq = 0,
		log = {},
	}

	function w.rand(): number -- deterministic LCG in [0, 1)
		w.rngState = (w.rngState * 1103515245 + 12345) % 2147483648
		return w.rngState / 2147483648
	end
	function w.pick(list: { any }): any
		if #list == 0 then
			return nil
		end
		return list[1 + math.floor(w.rand() * #list)]
	end

	function w.addUser(userId: number, items: { string }, cap: number)
		local inventory = {}
		for _, uid in items do
			inventory[uid] = { uid = uid, itemId = "fish", acquiredAt = 1, source = "roll" }
		end
		w.users[userId] = {
			persisted = { inventory = inventory, mail = { seen = {}, attempts = {}, dead = {} } },
			queue = {},
		}
		w.caps[userId] = cap
	end

	local function sessionOf(player: any): any
		local s = w.sessions[player.UserId]
		if s and s.player == player then
			return s
		end
		return nil
	end

	local function update(s: any, fn: (data: any) -> ()): boolean
		if s == nil or w.sessions[s.player.UserId] ~= s then
			return false
		end
		Transaction.run(s.tx, s.memory, fn)
		return true
	end

	function w.save(userId: number, force: boolean?): boolean
		local s = w.sessions[userId]
		if s == nil then
			return false
		end
		if not force and w.rand() < w.pSaveFail then
			return false
		end
		local u = w.users[userId]
		u.persisted = deepCopy(s.memory)
		for i = #u.queue, 1, -1 do
			if s.locks[u.queue[i]] then
				table.remove(u.queue, i)
			end
		end
		s.locks = {}
		return true
	end

	local function messageAsync(entry: any): boolean
		if w.rand() < w.pSendFail then
			return false
		end
		local qe = {
			msg = { id = entry.key, kind = entry.kind, payload = deepCopy(entry.payload), sentAt = entry.at },
			to = entry.toUserId,
		}
		table.insert(w.users[entry.toUserId].queue, qe)
		table.insert(w.history, qe)
		return true
	end

	function w.makeServer(sv: number)
		local server: any = { id = sv, gen = (w.servers[sv] and w.servers[sv].gen or 0) + 1 }
		local function isActive(player: any): boolean
			local s = sessionOf(player)
			return s ~= nil and s.server == server
		end
		local function delay(seconds: number, fn: () -> ())
			table.insert(w.timers, { at = w.t + seconds, fn = fn, server = server })
		end
		server.delivery = Delivery.new({
			now = function()
				return w.t
			end,
			delay = delay,
			isActive = isActive,
			getMail = function(player)
				local s = sessionOf(player)
				return s and s.memory.mail
			end,
			update = function(player, fn)
				return update(sessionOf(player), function(d)
					fn(d.mail)
				end)
			end,
			analytics = function() end,
			warn = function(m)
				table.insert(w.log, m)
			end,
			config = function()
				return { mailboxCap = w.mailboxCap }
			end,
		})
		server.delivery.register(Gift.KIND, function(player, payload)
			local s = sessionOf(player)
			local result
			local ok = update(s, function(d)
				result = Gift.receiveInto(d, payload, {
					itemExists = function(itemId)
						return itemId == "fish"
					end,
					cap = w.caps[player.UserId],
					now = w.t,
				})
			end)
			if not ok then
				error("not loaded")
			end
			return result ~= "full"
		end)
		server.outbox = Outbox.new({
			now = function()
				return w.t
			end,
			delay = delay,
			isActive = isActive,
			getOutbox = function(player)
				local s = sessionOf(player)
				return s and s.memory.mail.outbox
			end,
			save = function(player)
				return w.save(player.UserId)
			end,
			send = messageAsync,
			remove = function(player, key)
				return update(sessionOf(player), function(d)
					d.mail.outbox[key] = nil
				end)
			end,
			backoff = function(n)
				return 5 * n
			end,
			warn = function(m)
				table.insert(w.log, m)
			end,
		})
		w.servers[sv] = server
		return server
	end

	-- ProfileStore hands every not-yet-received stored message to the session.
	function w.poll(userId: number)
		local s = w.sessions[userId]
		if s == nil then
			return
		end
		for _, qe in table.clone(w.users[userId].queue) do
			if not s.received[qe] and w.sessions[userId] == s then
				s.received[qe] = true
				s.server.delivery.deliver(s.player, qe.msg, function()
					s.locks[qe] = true
				end)
			end
		end
	end

	function w.join(userId: number, sv: number)
		assert(w.sessions[userId] == nil, "already loaded")
		local server = w.servers[sv] or w.makeServer(sv)
		local s = {
			player = { UserId = userId },
			server = server,
			memory = deepCopy(w.users[userId].persisted),
			tx = Transaction.newState(),
			received = {},
			locks = {},
		}
		w.sessions[userId] = s
		server.outbox.markLoaded(s.player)
		server.outbox.flush(s.player)
		w.poll(userId)
	end

	local function drop(userId: number)
		local s = w.sessions[userId]
		w.sessions[userId] = nil
		s.server.delivery.forget(s.player)
		s.server.outbox.forget(s.player)
	end

	function w.leave(userId: number, force: boolean?)
		if w.sessions[userId] == nil then
			return
		end
		w.save(userId, force) -- final save; a failure loses the session's memory (like a crash)
		drop(userId)
	end

	function w.crash(sv: number)
		for userId, s in table.clone(w.sessions) do
			if s.server.id == sv then
				drop(userId)
			end
		end
		local old = w.servers[sv]
		if old then
			old.delivery.stop()
			for i = #w.timers, 1, -1 do
				if w.timers[i].server == old then
					table.remove(w.timers, i)
				end
			end
		end
		w.servers[sv] = nil
	end

	-- Inventory.sendGift's update: remove + outbox in ONE transaction, flush after commit.
	function w.gift(fromId: number, toId: number, uid: string): boolean
		local s = w.sessions[fromId]
		if s == nil then
			return false
		end
		w.keySeq += 1
		local key = "g-" .. w.keySeq
		local queue = {}
		local removed
		local ok = pcall(update, s, function(d)
			local tx = {
				player = s.player,
				data = d,
				after = function(fn)
					table.insert(queue, fn)
				end,
			}
			removed = Gift.takeInto(tx, toId, uid, key, nil, function(tx2, to, kind, payload, k)
				return (
					Outbox.writeInto(tx2, to, kind, payload, k, w.t, encode, function()
						s.server.outbox.flush(s.player)
					end)
				)
			end)
		end)
		if ok and removed then
			for _, fn in queue do
				fn()
			end
			return true
		end
		return false
	end

	function w.claimAll(userId: number)
		local s = w.sessions[userId]
		if s == nil then
			return
		end
		for _, entry in s.server.delivery.pending(s.player) do
			s.server.delivery.claim(s.player, entry.id)
		end
	end

	function w.advance(seconds: number)
		local target = w.t + seconds
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

	-- What a fresh server would see for a user: live memory when loaded, else the store.
	function w.view(userId: number): any
		local s = w.sessions[userId]
		return if s then s.memory else w.users[userId].persisted
	end

	-- uid -> number of places holding it (see the invariant in the spec below).
	function w.holders(): ({ [string]: number }, { string })
		local count: { [string]: number } = {}
		local where: { string } = {}
		local function add(uid: string, place: string)
			count[uid] = (count[uid] or 0) + 1
			table.insert(where, uid .. "@" .. place)
		end
		local outboxKeys = {}
		for _, userId in sortedKeys(w.users) do
			local v = w.view(userId)
			for uid in v.inventory do
				add(uid, "inv" .. userId)
			end
			for _, entry in (v.mail.box or {}) do
				add(entry.payload.item.uid, "box" .. userId)
			end
			for key, entry in (v.mail.outbox or {}) do
				outboxKeys[key] = true
				-- Already delivered (sent, removal not saved yet): the resend is a duplicate.
				local tv = w.view(entry.toUserId)
				if tv.mail.seen[key] == nil and (tv.mail.box == nil or tv.mail.box[key] == nil) then
					add(entry.payload.item.uid, "outbox" .. userId)
				end
			end
		end
		for _, userId in sortedKeys(w.users) do
			local v = w.view(userId)
			local seenKeys = {}
			for _, qe in w.users[userId].queue do
				local key = qe.msg.id
				local redundant = outboxKeys[key]
					or seenKeys[key]
					or v.mail.seen[key] ~= nil
					or (v.mail.box ~= nil and v.mail.box[key] ~= nil)
				if not redundant then
					seenKeys[key] = true
					add(qe.msg.payload.item.uid, "queue" .. userId)
				end
			end
		end
		return count, where
	end

	return w
end

describe("Inventory.Gift (pure steps)", function()
	it("payload carries the same instance fields, from and reason", function()
		local p = Gift.payload({
			uid = "u",
			itemId = "fish",
			mutation = "Gold",
			meta = { a = 1 },
			source = "roll",
			acquiredAt = 5,
		}, 7, "bday")
		expect(p.item.uid).toBe("u")
		expect(p.item.mutation).toBe("Gold")
		expect(p.item.meta.a).toBe(1)
		expect(p.item.source).toBe("roll")
		expect(p.item.acquiredAt).toBe(5)
		expect(p.from).toBe(7)
		expect(p.reason).toBe("bday")
	end)

	it(
		"takeInto: not owned / paid source -> nil, nothing changed; sendInto refusal discards the update",
		function()
			local root = {
				inventory = {
					a = { uid = "a", itemId = "fish", source = "roll", acquiredAt = 1 },
					p = { uid = "p", itemId = "fish", source = "paid:egg", acquiredAt = 1 },
					c = { uid = "c", itemId = "fish", source = "paidcur:gems", acquiredAt = 1 },
				},
				mail = { seen = {}, attempts = {}, dead = {} },
			}
			local state = Transaction.newState()
			local function run(uid, accept)
				local got
				local sent = 0
				local ok = pcall(Transaction.run, state, root, function(d)
					local tx = { player = { UserId = 1 }, data = d, after = function() end }
					got = Gift.takeInto(tx, 2, uid, "g-1", nil, function()
						sent += 1
						return accept
					end)
				end)
				return ok, got, sent
			end
			local ok, got, sent = run("zzz", true)
			expect(ok).toBe(true)
			expect(got).toBeNil()
			expect(sent).toBe(0)
			ok, got = run("p", true)
			expect(got).toBeNil()
			ok, got = run("c", true)
			expect(got).toBeNil()
			ok = run("a", false)
			expect(ok).toBe(false)
			expect(root.inventory.a).never.toBeNil() -- discarded: the item can't leave without its message
			ok, got, sent = run("a", true)
			expect(ok).toBe(true)
			expect(got.uid).toBe("a")
			expect(sent).toBe(1)
			expect(root.inventory.a).toBeNil()
		end
	)

	it(
		"receiveInto: added keeps uid/mutation/meta/source, acquiredAt = now; duplicate; full; errors",
		function()
			local data: any = { inventory = { x = { uid = "x", itemId = "fish", acquiredAt = 1 } } }
			local opts = {
				itemExists = function(id)
					return id == "fish"
				end,
				cap = 2,
				now = 99,
			}
			local item = {
				uid = "u",
				itemId = "fish",
				mutation = "Gold",
				meta = { k = "v" },
				source = "roll",
				acquiredAt = 3,
			}
			local result, inst = Gift.receiveInto(data, { item = item, from = 1 }, opts)
			expect(result).toBe("added")
			expect(inst.uid).toBe("u")
			expect(inst.mutation).toBe("Gold")
			expect(inst.meta.k).toBe("v")
			expect(inst.source).toBe("roll")
			expect(inst.acquiredAt).toBe(99)
			expect((Gift.receiveInto(data, { item = item }, opts))).toBe("duplicate")
			local other = table.clone(item)
			other.uid = "w"
			expect((Gift.receiveInto(data, { item = other }, opts))).toBe("full")
			expect(data.inventory.w).toBeNil()
			local bad = table.clone(item)
			bad.uid = "q"
			bad.itemId = "dragon"
			expect(function()
				Gift.receiveInto({ inventory = {} }, { item = bad }, opts)
			end).toThrow("unknown item")
			expect(function()
				Gift.receiveInto({ inventory = {} }, { nope = true }, opts)
			end).toThrow("malformed")
		end
	)
end)

describe("Inventory gifting end to end (simulated servers)", function()
	it(
		"Example Gifts: stranger in another server with a full inventory claims after freeing a slot",
		function()
			local w = newWorld()
			w.addUser(1, { "wish" }, 10)
			w.addUser(2, { "b1", "b2" }, 2) -- full
			w.join(1, 1)
			w.join(2, 2)
			expect(w.gift(1, 2, "wish")).toBe(true)
			expect(w.view(1).inventory.wish).toBeNil()
			expect((next(w.view(1).mail.outbox or {}))).toBeNil() -- sent and removed
			w.poll(2) -- the receiver's server picks the message up
			local box = w.sessions[2].server.delivery.pending(w.sessions[2].player)
			expect(#box).toBe(1)
			expect(box[1].kind).toBe(Gift.KIND)
			expect(w.view(2).inventory.wish).toBeNil()
			local s2 = w.sessions[2]
			expect(select(2, s2.server.delivery.claim(s2.player, box[1].id))).toBe("still_held")
			-- free a slot (sell b1), then claim
			Transaction.run(s2.tx, s2.memory, function(d)
				d.inventory.b1 = nil
			end)
			expect(s2.server.delivery.claim(s2.player, box[1].id)).toBe(true)
			expect(w.view(2).inventory.wish.uid).toBe("wish")
			w.leave(1, true)
			w.leave(2, true)
			-- exactly once everywhere, and nothing left in queues/boxes/outboxes
			local count = w.holders()
			expect(count.wish).toBe(1)
			expect(#w.users[2].queue).toBe(0)
			expect((next(w.users[2].persisted.mail.box))).toBeNil()
			-- next session: the message is not delivered again
			w.join(2, 1)
			expect(#w.sessions[2].server.delivery.pending(w.sessions[2].player)).toBe(0)
			expect(w.holders().wish).toBe(1)
		end
	)

	it("offline receiver: delivered on their next load", function()
		local w = newWorld()
		w.addUser(1, { "a" }, 5)
		w.addUser(2, {}, 5)
		w.join(1, 1)
		expect(w.gift(1, 2, "a")).toBe(true)
		expect(#w.users[2].queue).toBe(1)
		w.join(2, 2)
		expect(w.view(2).inventory.a).never.toBeNil()
		expect(w.holders().a).toBe(1)
	end)

	local function propertyRun(seed: number, steps: number)
		local w = newWorld({ seed = seed, pSaveFail = 0.25, pSendFail = 0.3, mailboxCap = 3 })
		w.addUser(1, { "a1", "a2", "a3" }, 3)
		w.addUser(2, { "b1", "b2" }, 2)
		local all = { "a1", "a2", "a3", "b1", "b2" }
		local trace = {}
		local function check(label)
			local count, where = w.holders()
			for _, uid in all do
				if count[uid] ~= 1 then
					error(
						string.format(
							"seed %d after %s: %s held %s times [%s]\n%s",
							seed,
							label,
							uid,
							tostring(count[uid]),
							table.concat(where, " "),
							table.concat(trace, "\n")
						),
						0
					)
				end
			end
		end
		for step = 1, steps do
			local userId = if w.rand() < 0.5 then 1 else 2
			local other = 3 - userId
			local r = w.rand()
			local label
			if r < 0.12 then
				if w.sessions[userId] == nil then
					local sv = if w.rand() < 0.5 then 1 else 2
					label = `join {userId} s{sv}`
					w.join(userId, sv)
				else
					label = `leave {userId}`
					w.leave(userId)
				end
			elseif r < 0.18 then
				local sv = if w.rand() < 0.5 then 1 else 2
				label = `crash s{sv}`
				w.crash(sv)
			elseif r < 0.40 then
				local s = w.sessions[userId]
				local uid = s and w.pick(sortedKeys(s.memory.inventory))
				label = `gift {userId}->{other} {tostring(uid)}`
				if uid then
					w.gift(userId, other, uid)
				end
			elseif r < 0.52 then
				label = `poll {userId}`
				w.poll(userId)
			elseif r < 0.62 then
				label = `claim {userId}`
				w.claimAll(userId)
			elseif r < 0.72 then
				label = `save {userId}`
				w.save(userId)
			elseif r < 0.80 then
				local cap = 1 + math.floor(w.rand() * 4)
				label = `cap {userId}={cap}`
				w.caps[userId] = cap
			elseif r < 0.88 then
				local qe = w.pick(w.history)
				label = `redeliver {qe and qe.msg.id or "-"}`
				if qe then
					table.insert(w.users[qe.to].queue, { msg = deepCopy(qe.msg), to = qe.to })
				end
			else
				label = "advance"
				w.advance(5 + math.floor(w.rand() * 40))
			end
			table.insert(trace, `{step}: {label}`)
			if #trace > 400 then
				table.remove(trace, 1)
			end
			check(label)
		end
		-- Drain: no more failures, room for everything, everyone online, deliver/flush/claim.
		w.pSaveFail = 0
		w.pSendFail = 0
		w.caps[1] = 100
		w.caps[2] = 100
		for round = 1, 6 do
			for _, userId in { 1, 2 } do
				if w.sessions[userId] == nil then
					w.join(userId, round % 2 + 1)
				end
			end
			w.advance(1000)
			for _, userId in { 1, 2 } do
				local s = w.sessions[userId]
				s.server.outbox.flush(s.player)
				w.poll(userId)
				w.claimAll(userId)
				w.save(userId, true)
			end
			check(`drain {round}`)
			for _, userId in { 1, 2 } do
				w.leave(userId, true)
			end
		end
		check("drained")
		local owners = {}
		for _, uid in all do
			local n = 0
			for _, userId in { 1, 2 } do
				local v = w.users[userId].persisted
				if v.inventory[uid] then
					n += 1
				end
			end
			owners[uid] = n
			expect(n).toBe(1) -- ends in exactly one inventory
		end
		for _, userId in { 1, 2 } do
			local v = w.users[userId].persisted
			expect((next(v.mail.box or {}))).toBeNil()
			expect((next(v.mail.outbox or {}))).toBeNil()
			expect(#w.users[userId].queue).toBe(0)
		end
		return w
	end

	it(
		"property: gifted items are never duplicated or lost (crashes, failed saves/sends, full inventories, re-delivery)",
		function()
			local gifts = 0
			for seed = 1, 40 do
				local w = propertyRun(seed, 300)
				gifts += w.keySeq
			end
			expect(gifts).toBeGreaterThan(300)
		end
	)
end)
