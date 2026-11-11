--[[
	Offline payout on return (known-issues: "the offline payout" after leave -> rejoin).
	Real Data + Offline + Economy + Items on the mock DataStore. The rate comes from owned items
	(income.source = "owned"): one "gem" = 10 coins/s.
]]

local F = require(script.Parent.Fixtures)

local RATE = 10

local function loaded(world, server, player): boolean
	return world:advanceUntil(function()
		return server:isLoaded(player)
	end, 30)
end

local function released(world, userId: number): boolean
	return world:advanceUntil(function()
		return F.lockHolder(world, userId) == nil
	end, 30)
end

-- First session: own one gem, then leave. Returns the world, a fresh server and the user id.
local function firstSession(offline: any?, userId: number)
	local world = F.world({ config = { balance = { offline = offline } } })
	local a = F.server(world)
	local p = a:join(userId)
	assert(loaded(world, a, p), "first load")
	assert(a.services.Inventory.add(p, "gem", { source = "drop" }), "gem")
	world:advance(2)
	a:leave(p)
	assert(released(world, userId), "release")
	return world, a
end

-- Rejoins after `away` seconds on `server`; returns player, onReturn calls, offline grants.
local function rejoin(world, server, userId: number, away: number)
	world:advance(away, 1) -- big frames: nothing runs while the player is away
	local returns = {}
	local connection = server.services.Offline.onReturn(function(player, seconds)
		table.insert(returns, { player = player, seconds = seconds })
	end)
	local p = server:join(userId)
	assert(loaded(world, server, p), "rejoin load")
	world:advance(0.5)
	connection:Disconnect()
	return p, returns, F.grants(server, p, "offline")
end

describe("offline payout on return", function()
	it("pays floor(rate * secondsAway * payoutFraction) once, with a pop feedback", function()
		local world, a = firstSession(nil, 11)
		local p, returns, grants = rejoin(world, a, 11, 600)
		expect(#returns).toBe(1)
		local seconds = returns[1].seconds
		expect(seconds).toBeGreaterThanOrEqual(600)
		expect(seconds).toBeLessThanOrEqual(602)
		expect(#grants).toBe(1)
		expect(grants[1]).toBe(math.floor(RATE * seconds * 0.5))
		local popped = false
		for _, f in a.feedback do
			if f.player == p and f.kind == "pop" and f.text == "+" .. tostring(grants[1]) then
				popped = true
			end
		end
		expect(popped).toBe(true)
		expect(#world:errors()).toBe(0)
	end)

	it("caps secondsAway at offline.capSeconds", function()
		local world, a = firstSession(nil, 12)
		local _, returns, grants = rejoin(world, a, 12, 10 * 3600)
		expect(returns[1].seconds).toBe(3600)
		expect(grants[1]).toBe(math.floor(RATE * 3600 * 0.5))
	end)

	it("does nothing below offline.minSeconds (no handler, no grant)", function()
		local world, a = firstSession(nil, 13)
		local _, returns, grants = rejoin(world, a, 13, 30)
		expect(#returns).toBe(0)
		expect(#grants).toBe(0)
	end)

	it("autoPay = false: no grant, onReturn handlers still fire", function()
		local world, a = firstSession({ autoPay = false }, 14)
		local _, returns, grants = rejoin(world, a, 14, 900)
		expect(#returns).toBe(1)
		expect(returns[1].seconds).toBeGreaterThanOrEqual(900)
		expect(#grants).toBe(0)
	end)

	it("uses payoutFraction from the config", function()
		local world, a = firstSession({ payoutFraction = 0.25 }, 15)
		local _, returns, grants = rejoin(world, a, 15, 1000)
		expect(grants[1]).toBe(math.floor(RATE * returns[1].seconds * 0.25))
	end)

	it("pays on a different server too, and never on the first session", function()
		local world = firstSession(nil, 16)
		local b = F.server(world)
		local firstTime = {}
		b.services.Offline.onReturn(function(player)
			table.insert(firstTime, player.UserId)
		end)
		local newcomer = b:join(99)
		expect(loaded(world, b, newcomer)).toBe(true)
		world:advance(1)
		expect(#firstTime).toBe(0) -- sessions == 1: no offline handling

		local _, returns, grants = rejoin(world, b, 16, 300)
		expect(#returns).toBe(1)
		expect(grants[1]).toBe(math.floor(RATE * returns[1].seconds * 0.5))
	end)
end)
