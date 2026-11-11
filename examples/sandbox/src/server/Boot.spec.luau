-- Boot test (core-v1.3.0 step 4b-IIb): the sandbox's real Config, game module and ServerConfig
-- boot through the StudWork server start (framework + real kit modules) in the
-- multi-server sim, with exactly the expected modules and no errors; a player loads and leaves.
local StudWork = require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"))
local F = StudWork.test.sim -- the multi-server sim (module-api.md §19.5)

local EXPECTED = {
	"Items",
	"Rarity",
	"Inventory",
	"Economy",
	"Upgrades",
	"Rebirth",
	"Offline",
	"Streak",
	"Friends",
	"Mail",
	"Plot",
	"Sandbox", -- the game's own module, added by the framework
}

describe("sandbox boot", function()
	it("boots its real Config through StudWork with its module list and no errors", function()
		local r = F.bootGame("examples/sandbox/default.project.json")
		expect(r.state).toBe("running")
		expect(r.names).toEqual(EXPECTED)
		expect(r.loaded).toBe(true)
		expect(r.errors).toEqual({})
		expect(r.bootWarnings).toEqual({})
	end)
end)
