-- Boot test (core-v1.3.0 step 4b-IIb): the sandbox's real Config, game module and ServerConfig
-- boot through the StudWork server start (framework + kit wrappers + compat bridge) in the
-- multi-server sim, with exactly the expected modules and no errors; a player loads and leaves.
-- the sim lives outside the Rojo tree (Lune only), so the require is untyped
local F = (require :: any)("packages/framework/test/sim/Fixtures.luau")

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

describe("_sandbox boot", function()
	it("boots its real Config through StudWork with its module list and no errors", function()
		local r = F.bootGame("games/_sandbox/default.project.json")
		expect(r.state).toBe("running")
		expect(r.names).toEqual(EXPECTED)
		expect(r.loaded).toBe(true)
		expect(r.errors).toEqual({})
		expect(r.bootWarnings).toEqual({})
	end)
end)
