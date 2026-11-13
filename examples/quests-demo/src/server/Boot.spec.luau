--!nocheck
-- Boot test: the quests demo's real Config, game module and ServerConfig boot through the StudWork
-- server start (framework + real kit modules) in the multi-server sim, with exactly the expected
-- modules, no errors and no boot warnings; a player loads, plays a few seconds and leaves.
local StudWork = require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"))
local F = StudWork.test.sim -- the multi-server sim (module-api.md §19.5)

local PROJECT = "examples/quests-demo/default.project.json"

local EXPECTED = {
	"Items",
	"Rarity",
	"Inventory",
	"Economy",
	"Quests",
	"Goals",
	"QuestsDemo", -- the game's own module, added by the framework
}

describe("quests-demo boot", function()
	it("boots its real Config through StudWork with its module list and no errors", function()
		local r = F.bootGame(PROJECT)
		expect(r.state).toBe("running")
		local names = table.clone(r.names)
		table.sort(names)
		local expected = table.clone(EXPECTED)
		table.sort(expected)
		expect(names).toEqual(expected)
		expect(r.loaded).toBe(true)
		expect(r.errors).toEqual({})
		expect(r.bootWarnings).toEqual({})
	end)

	it("logs no warning at all (every game.* string key is declared)", function()
		local world = F.world()
		local server = F.gameServer(world, PROJECT)
		local p = server:join(101)
		expect(world:advanceUntil(function()
			return server:isLoaded(p)
		end, 30)).toBe(true)
		world:advance(10)
		expect(server.warnings).toEqual({})
		expect(world:errors()).toEqual({})
	end)
end)
