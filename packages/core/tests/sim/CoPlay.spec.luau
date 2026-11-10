--[[
	Co-play with mocked friends (known-issues: "real friend co-play multiplier").
	Real Friends + Economy + Data; IsFriendsWithAsync answers come from world.friends (with
	latency and injectable failures). balance.friends.coPlayMultiplier = 1.5 in the fixture.
]]

local F = require(script.Parent.Fixtures)

local function joinAll(world, s, ids: { number }, opts: { [number]: any }?)
	local players = {}
	for _, id in ids do
		table.insert(players, s:join(id, opts and opts[id]))
	end
	assert(
		world:advanceUntil(function()
			for _, p in players do
				if not s:isLoaded(p) then
					return false
				end
			end
			return true
		end, 30),
		"all loaded"
	)
	world:advance(1) -- friend lookups (0.05 s each) finish
	return table.unpack(players)
end

local function coPlayFires(s, player)
	local list = {}
	for _, args in s.signals.CoPlay.history do
		if args[1] == player then
			table.insert(list, { friends = args[2], kind = args[3] })
		end
	end
	return list
end

describe("co-play with friends in the same server", function()
	it("detects friends, fires CoPlay once per gain and applies/removes the multiplier", function()
		local world = F.world()
		world:setFriends(41, 42)
		local s = F.server(world)
		local a, b, c = joinAll(world, s, { 41, 42, 43 })
		local Friends, Economy = s.services.Friends, s.services.Economy

		expect(#Friends.friendsInServer(a)).toBe(1)
		expect(Friends.friendsInServer(a)[1].UserId).toBe(b.UserId)
		expect(#Friends.friendsInServer(c)).toBe(0)
		expect(Economy.getMultiplier(a)).toBeNear(1.5)
		expect(Economy.getMultiplier(b)).toBeNear(1.5)
		expect(Economy.getMultiplier(c)).toBeNear(1)
		expect(#coPlayFires(s, a)).toBe(1)
		expect(coPlayFires(s, a)[1].kind).toBe("server")
		expect(#coPlayFires(s, c)).toBe(0)

		-- periodic re-checks don't fire again while nothing was gained
		world:advance(65, 0.25)
		expect(#coPlayFires(s, a)).toBe(1)

		s:leave(b)
		world:advance(0.1)
		expect(#Friends.friendsInServer(a)).toBe(0)
		expect(Economy.getMultiplier(a)).toBeNear(1)
		expect(#world:errors()).toBe(0)
	end)

	it("the multiplier really scales income (owned gem: 10/s -> 15/s)", function()
		local world = F.world()
		world:setFriends(44, 45)
		local s = F.server(world)
		local a = joinAll(world, s, { 44 })
		s.services.Inventory.add(a, "gem", { source = "drop" })
		expect(s.services.Economy.getRate(a)).toBeNear(10)
		joinAll(world, s, { 45 })
		expect(s.services.Economy.getRate(a)).toBeNear(15)
		local before = s:data(a).currency.Coins
		world:advance(4)
		expect(s:data(a).currency.Coins - before).toBeNear(60, 1e-6)
	end)

	it("reports kind = invite when the referrer is a friend in the server", function()
		local world = F.world()
		world:setFriends(46, 47)
		local s = F.server(world)
		joinAll(world, s, { 46 })
		local b = joinAll(world, s, { 47 }, { [47] = { referredBy = 46 } })
		local fires = coPlayFires(s, b)
		expect(#fires).toBe(1)
		expect(fires[1].kind).toBe("invite")
	end)

	it("an API failure keeps the last known state and retries on the next check", function()
		local world = F.world()
		world:setFriends(48, 49)
		world.friendFailures = 100 -- every lookup fails for now
		local s = F.server(world)
		local a = joinAll(world, s, { 48, 49 })
		expect(#s.services.Friends.friendsInServer(a)).toBe(0)
		expect(#world:errors()).toBe(0) -- failures are pcall'd, not thread errors
		world.friendFailures = 0
		world:advance(31, 0.25) -- checkIntervalSec = 30
		expect(#s.services.Friends.friendsInServer(a)).toBe(1)
		expect(s.services.Economy.getMultiplier(a)).toBeNear(1.5)
	end)

	it("no multiplier when coPlayMultiplier is not configured, but CoPlay still fires", function()
		local world = F.world()
		world.config.balance.friends.coPlayMultiplier = nil
		world:setFriends(50, 51)
		local s = F.server(world)
		local a = joinAll(world, s, { 50, 51 })
		expect(#coPlayFires(s, a)).toBe(1)
		expect(s.services.Economy.getMultiplier(a)).toBeNear(1)
	end)
end)
