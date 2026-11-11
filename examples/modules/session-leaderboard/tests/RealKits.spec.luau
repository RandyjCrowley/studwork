--!nocheck
-- Override case (f): the example module booted next to the REAL kit modules (Items, Inventory,
-- Economy through StudWork.start in the multi-server sim, compat bridge included), from the
-- fixture game's own Rojo project (tests/fixture-game). Economy's real income ticks fire
-- CurrencyChanged, which the leaderboard counts as points through its optional dependency.
-- Needs examples/ in the sim's source roots (packages/framework/test/sim/Loader.luau ROOTS).
local F = (require :: any)("packages/framework/test/sim/Fixtures.luau")

local PROJECT = "examples/modules/session-leaderboard/tests/fixture-game/default.project.json"

local function refOf(server: any, name: string): any
	for _, ref in server.runtime.order do
		if ref.name == name then
			return ref
		end
	end
	error("module not booted: " .. name)
end

describe("SessionLeaderboard with the real kit modules (case f)", function()
	it(
		"boots alongside Items, Inventory and Economy and turns real income into points and a saved best",
		function()
			local world = F.world()
			local server = F.gameServer(world, PROJECT)
			local names = {}
			for _, ref in server.runtime.order do
				table.insert(names, ref.name)
			end
			expect(names).toEqual({
				"Items",
				"Inventory",
				"Economy",
				"SessionLeaderboard",
				"LeaderboardFixture",
			})
			expect(server.runtime.state).toBe("running")

			local p = server:join(1)
			expect(world:advanceUntil(function()
				return server:isLoaded(p)
			end, 30)).toBe(true)
			world:advance(10)

			local leaderboard = server.runtime.apis[refOf(server, "SessionLeaderboard")]
			local economy = server.runtime.apis[refOf(server, "Economy")]
			local coins = economy.balance(p)
			expect(coins > 0).toBe(true) -- the starter pebble earns
			expect(leaderboard.earned(p)).toBe(coins) -- every coin earned this session is a point
			local top = leaderboard.top()
			expect(#top).toBe(1)
			expect(top[1].userId).toBe(1)

			server:leave(p)
			world:advance(10)
			local raw = world:peek("PlayerData_leaderboard-fixture", F.key(1)) -- the store is named after gameId
			local saved = raw and raw.Data
			expect(saved.sessionLeaderboard.best > 0).toBe(true)
			expect(saved.sessionLeaderboard.sessions).toBe(1)
			expect(world:errors()).toEqual({})
		end
	)
end)
