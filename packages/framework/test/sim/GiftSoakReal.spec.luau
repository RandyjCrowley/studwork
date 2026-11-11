--[[
	R1 soak on the REAL path (core-v1.3.0 Phase 2): agent C's 2400-gift scenario
	(packages/kits/social/Mail/server/GiftSoak.spec.luau drives the pure parts with fakes) re-run
	through the real modules in the multi-server sim:
	  - 24 senders on 3 servers, 100 gems each, gifting everything to one user who never logs in;
	  - real Inventory.sendGift -> real Mail (outbox, Escrow) -> the framework's ctx.data.shared on
	    the World's mock DataStore (one store shared by the 3 servers) -> real ProfileStore 1.0.3
	    MessageAsync, whose queue keeps at most 1000 messages and DROPS THE OLDEST beyond that
	    (the control case below proves the drop is real here);
	  - the 14-day return runs on the framework clock (ctx.now = the World clock), checked when
	    the senders log back in.
	After every phase each of the 2400 uids is in exactly one place: a sender's inventory /
	outbox / mailbox, or a sender's `sent` while the recipient's escrow record says "p" and the
	message is in the recipient's ProfileStore queue.
]]

local F = require(script.Parent.Fixtures)

local DAY = 86400
local RECIPIENT = 9000
local SENDERS = 24
local EACH = 100
local CAP = 100
local SHARED_STORE = "StudWorkShared_" .. F.GAME_ID

local function refOf(server, name: string): any
	for _, ref in server.runtime.order do
		if ref.name == name then
			return ref
		end
	end
	error("no module " .. name)
end

local function api(server, name: string): any
	return server.runtime.apis[refOf(server, name)]
end

local function joinLoaded(world, s, userId: number)
	local p = s:join(userId)
	assert(
		world:advanceUntil(function()
			return s:isLoaded(p)
		end, 60),
		"loaded " .. userId
	)
	return p
end

local function released(world, userId: number): boolean
	return world:advanceUntil(function()
		return F.lockHolder(world, userId) == nil
	end, 120)
end

-- the recipient's ProfileStore message queue (GlobalUpdates) as stored right now
local function queue(world): { any }
	local raw = world:peek(F.STORE, F.key(RECIPIENT))
	local updates = raw and raw.GlobalUpdates
	local list = {}
	if type(updates) == "table" and type(updates[2]) == "table" then
		for _, update in updates[2] do
			local message = update[2] -- Data's envelope { m = module, p = payload }
			table.insert(list, if type(message) == "table" and message.p then message.p else message)
		end
	end
	return list
end

local function record(world): { [string]: any }
	return world:peek(SHARED_STORE, "Mail/r:" .. RECIPIENT) or {}
end

local function count(t: any): number
	local n = 0
	for _ in (if type(t) == "table" then t else {}) do
		n += 1
	end
	return n
end

local function newWorld(extra: any?)
	local config = {
		modules = { "Items", "Inventory", "Mail" },
		config = {
			Inventory = { inventory = { cap = 2 * EACH } },
			Mail = { mail = { giftCap = CAP, returnAfterDays = 14 } },
		},
	}
	for module, c in extra or {} do
		config.config[module] = c -- e.g. { Mail = { mail = { giftCap = 50 } } }
	end
	local world = F.world({ config = config })
	local servers = { F.server(world), F.server(world), F.server(world) }
	return world, servers
end

-- where every uid is right now: data(userId) -> sectioned save (live when online, stored otherwise)
local function custody(world, senders: { number }, data: (number) -> any): { [string]: number }
	local seen: { [string]: number } = {}
	local function add(uid: any)
		if type(uid) == "string" then
			seen[uid] = (seen[uid] or 0) + 1
		end
	end
	local rec = record(world)
	local inQueue: { [string]: boolean } = {}
	for _, msg in queue(world) do
		inQueue[msg.id] = true
	end
	for _, userId in senders do
		local d = data(userId) or {}
		for uid in (d.inventory or {}).inventory or {} do
			add(uid)
		end
		local mail = (d.mail or {}).mail or {}
		for _, entry in mail.outbox or {} do
			add(entry.payload.item.uid)
		end
		for key, entry in mail.sent or {} do
			local r = rec[key]
			if r and r.s == "p" and inQueue[key] then
				add(entry.payload.item.uid)
			end
		end
		for _, entry in mail.box or {} do
			add(entry.payload.item.uid)
		end
	end
	return seen
end

local function assertConserved(world, senders: { number }, uids: { string }, data: (number) -> any)
	local seen = custody(world, senders, data)
	local lost, doubled = 0, 0
	for _, uid in uids do
		local n = seen[uid] or 0
		if n == 0 then
			lost += 1
		elseif n > 1 then
			doubled += 1
		end
	end
	expect(lost).toBe(0)
	expect(doubled).toBe(0)
end

local function stored(world): (number) -> any
	return function(userId: number): any
		return F.saved(world, userId)
	end
end

local function homeCount(world, senders: { number }): number
	local n = 0
	for _, userId in senders do
		n += count((F.section(world, userId, "inventory") or {}).inventory)
	end
	return n
end

-- every sender logs in (round robin over the servers), lets Mail run, and leaves
local function visit(world, servers, senders: { number })
	local online = {}
	for i, userId in senders do
		local s = servers[(i - 1) % #servers + 1]
		table.insert(online, { s = s, p = joinLoaded(world, s, userId) })
	end
	world:advance(120, 0.5) -- outbox flush, the return sweep, hand-backs and their claims
	for _, o in online do
		o.s:leave(o.p)
	end
	for _, userId in senders do
		assert(released(world, userId), "released " .. userId)
	end
end

describe("R1 soak on the real path: 2400 gifts to a recipient who never logs in", function()
	it("caps the queue, hands every refused and every uncollected gift back, loses nothing", function()
		local world, servers = newWorld()
		local senders, uids = {}, {}
		local online = {}
		for i = 1, SENDERS do
			local s = servers[(i - 1) % #servers + 1]
			local p = joinLoaded(world, s, i)
			for _ = 1, EACH do
				local item = api(s, "Inventory").add(p, "gem", { source = "drop" })
				assert(item, "add")
				table.insert(uids, item.uid)
			end
			table.insert(senders, i)
			table.insert(online, { s = s, p = p })
		end
		expect(#uids).toBe(SENDERS * EACH)

		-- every sender gifts every item; the servers run between senders
		local accepted = 0
		for _, o in online do
			local mine = {}
			for uid in o.s:section(o.p, "inventory").inventory do
				table.insert(mine, uid)
			end
			table.sort(mine)
			for _, uid in mine do
				local ok = api(o.s, "Inventory").sendGift(o.p, RECIPIENT, uid, "gift")
				if ok then
					accepted += 1
				end
			end
			world:advance(5, 0.25)
		end
		world:advance(120, 0.5)
		expect(accepted > CAP).toBe(true)
		local byServer = {}
		for _, o in online do
			byServer[o.p.UserId] = o
		end
		local live = function(userId: number): any
			local o = byServer[userId]
			return o.s:sections(o.p)
		end
		assertConserved(world, senders, uids, live)
		-- at most CAP escrowed gifts ever reached the recipient's queue; the rest bounced home
		expect(#queue(world)).toBe(CAP)
		expect(count(record(world))).toBe(CAP)
		local home = 0
		for _, userId in senders do
			home += count(live(userId).inventory.inventory)
		end
		expect(home).toBe(SENDERS * EACH - CAP)

		for _, o in online do
			o.s:leave(o.p)
		end
		for _, userId in senders do
			assert(released(world, userId), "released " .. userId)
		end
		assertConserved(world, senders, uids, stored(world))

		-- 13 days later (framework clock): nothing comes back yet
		world:advance(13 * DAY, 600)
		visit(world, servers, senders)
		assertConserved(world, senders, uids, stored(world))
		expect(homeCount(world, senders)).toBe(SENDERS * EACH - CAP)
		expect(#queue(world)).toBe(CAP)

		-- day 15: every uncollected gift is back with its sender, exactly once
		world:advance(2 * DAY, 600)
		visit(world, servers, senders)
		assertConserved(world, senders, uids, stored(world))
		expect(homeCount(world, senders)).toBe(SENDERS * EACH)
		for _, userId in senders do
			expect(
				(
					next(
						(F.section(world, userId, "mail") or {}).mail
								and F.section(world, userId, "mail").mail.sent
							or {}
					)
				)
			).toBeNil()
		end
		-- the queue never dropped anything: it never grew past the cap
		expect(#queue(world)).toBe(CAP)
		local returned = 0
		for _, r in record(world) do
			if r.s == "r" then
				returned += 1
			end
		end
		expect(returned).toBe(CAP)
		expect(#world:errors()).toBe(0)
	end)

	it("shared-store outages only delay: no gift is lost or doubled", function()
		local world, servers = newWorld({ Mail = { mail = { giftCap = 50, returnAfterDays = 14 } } })
		local senders, uids, online = {}, {}, {}
		for i = 1, 6 do
			local s = servers[(i - 1) % #servers + 1]
			local p = joinLoaded(world, s, i)
			for _ = 1, EACH do
				table.insert(uids, api(s, "Inventory").add(p, "gem", { source = "drop" }).uid)
			end
			table.insert(senders, i)
			table.insert(online, { s = s, p = p })
		end
		-- every 3rd shared-store call fails for the first 10 minutes (retries, then outbox backoff)
		local n = 0
		world:failFor(600, function(_op, store)
			if store ~= SHARED_STORE then
				return false
			end
			n += 1
			return n % 3 == 0
		end)
		for _, o in online do
			local mine = {}
			for uid in o.s:section(o.p, "inventory").inventory do
				table.insert(mine, uid)
			end
			table.sort(mine)
			for _, uid in mine do
				api(o.s, "Inventory").sendGift(o.p, RECIPIENT, uid, "gift")
			end
			world:advance(5, 0.25)
		end
		world:advance(1800, 0.5)
		for _, o in online do
			o.s:leave(o.p)
		end
		for _, userId in senders do
			assert(released(world, userId), "released " .. userId)
		end
		expect(n > 0).toBe(true)
		assertConserved(world, senders, uids, stored(world))
		expect(#queue(world) <= 50).toBe(true)
		world:advance(15 * DAY, 600)
		visit(world, servers, senders)
		visit(world, servers, senders)
		assertConserved(world, senders, uids, stored(world))
		expect(homeCount(world, senders)).toBe(6 * EACH)
		expect(#world:errors()).toBe(0)
	end)

	it("control: without the escrow, ProfileStore's queue really drops past 1000", function()
		local world, servers = newWorld()
		local s = servers[1]
		local p = joinLoaded(world, s, 1)
		local Mail = api(s, "Mail")
		for i = 1, 1005 do
			local h = s:spawn(Mail.send, RECIPIENT, "soak_note", { n = i }, "note-" .. i)
			world:advanceUntil(function()
				return h.done
			end, 30, 0.25)
		end
		local q = queue(world)
		expect(#q).toBe(1000)
		expect(q[1].id).toBe("note-6") -- the 5 oldest were dropped
		s:leave(p)
		expect(#world:errors()).toBe(0)
	end)
end)
