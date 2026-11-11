--[[
	SLOW (tools/test-sim): randomized soak over the real Data/ProfileStore stack.
	3 servers, 16 players hopping between them for 6 virtual hours, random DataStore latency
	spikes and failures, one server crash and one shutdown. Every player keeps a ledger of the
	coins granted in sessions whose save was CONFIRMED (saveAsync == true right before leaving);
	invariants:
	  - a loaded profile never has fewer coins than its confirmed ledger (no lost saves),
	    and never more than everything ever granted (no duplication);
	  - never two writers (Fixtures.writerViolations);
	  - no errors in simulated threads.
	Deterministic: fixed seed.
]]

local F = require(script.Parent.Fixtures)

local SEED = 20261110
local PLAYERS = 16
local DURATION = 6 * 3600

describe("soak: players hopping between servers with flaky DataStore", function()
	it("keeps every confirmed save and never duplicates or double-writes", function()
		local rng = Random and Random.new(SEED) or nil
		local seed = SEED
		local function rand(): number
			if rng then
				return rng:NextNumber()
			end
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end

		local world = F.world({ config = { balance = { offline = { capSeconds = 0, minSeconds = 1e9 } } } })
		local servers = { F.server(world), F.server(world), F.server(world) }
		local where: { [number]: any } = {} -- userId -> { server, player }
		local confirmed: { [number]: number } = {}
		local granted: { [number]: number } = {}
		local userIds = {}
		for i = 1, PLAYERS do
			userIds[i] = 1000 + i
			confirmed[userIds[i]] = 0
			granted[userIds[i]] = 0
		end

		local function liveServers()
			local list = {}
			for _, s in servers do
				if s.alive then
					table.insert(list, s)
				end
			end
			return list
		end

		local crashed, shutDown = false, false
		local checks = 0
		while world.scheduler.now < DURATION do
			world.latency = if rand() < 0.1 then 3 else 0.2
			if rand() < 0.03 then
				world:failNext(1 + math.floor(rand() * 3))
			end
			if not crashed and world.scheduler.now > DURATION / 3 then
				crashed = true
				servers[1]:crash()
				table.insert(servers, F.server(world))
			end
			if not shutDown and world.scheduler.now > 2 * DURATION / 3 then
				shutDown = true
				servers[2]:shutdown()
				table.insert(servers, F.server(world))
			end
			for _, userId in userIds do
				local at = where[userId]
				if at and (not at.server.alive or at.player.Parent == nil) then
					where[userId] = nil -- crashed/kicked: unconfirmed grants may be lost
					at = nil
				end
				local roll = rand()
				if at == nil and roll < 0.3 then
					local live = liveServers()
					local s = live[1 + math.floor(rand() * #live)]
					where[userId] = { server = s, player = s:join(userId), joinedAt = world.scheduler.now }
				elseif at and at.server:isLoaded(at.player) then
					checks += 1
					local coins = at.server:data(at.player).currency.Coins or 0
					if at.checked == nil then
						at.checked = true
						assert(
							coins >= confirmed[userId],
							string.format(
								"user %d lost a confirmed save: %d < %d",
								userId,
								coins,
								confirmed[userId]
							)
						)
						assert(coins <= granted[userId], string.format("user %d duplicated coins", userId))
						at.base = coins
					end
					if roll < 0.5 then
						local amount = 1 + math.floor(rand() * 50)
						if at.server.services.Economy.grant(at.player, amount, "soak") then
							granted[userId] += amount
						end
					elseif roll < 0.6 then
						local s, p = at.server, at.player
						local h = s:spawn(function()
							return s.services.Data.saveAsync(p)
						end)
						local expected = s:data(p).currency.Coins or 0
						world:advanceUntil(function()
							return h.done
						end, 40, 0.25)
						if h.result == true then
							confirmed[userId] = math.max(confirmed[userId], expected)
							s:leave(p)
							where[userId] = nil
						end
					end
				end
			end
			world:advance(5 + rand() * 20, 0.25)
		end

		expect(checks).toBeGreaterThan(50)
		for _, userId in userIds do
			expect(#F.writerViolations(world, userId)).toBe(0)
		end
		expect(#world:errors()).toBe(0)
	end)
end)
