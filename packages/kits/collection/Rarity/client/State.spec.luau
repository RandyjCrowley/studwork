-- core-v1.3.1 (R19): moved from packages/framework/client/Hud/Slices.spec.luau with the reader
-- (assertion unchanged).
local State = require(script.Parent.State)

local modular = {
	loaded = true,
	framework = { paidRandomRestricted = false },
	modules = {
		Economy = { data = { currency = { Coins = 120 } }, extra = { ratePerSec = 7, multiplier = 2 } },
		Mail = { extra = { mailbox = { { id = "m1" }, { id = "m2" } } } },
		Plot = { extra = { plotName = "Plot3" } },
		Rarity = { extra = { odds = { Chest = { items = {} } } } },
		Inventory = { data = { inventory = { { uid = "u1" } } } },
	},
}

describe("Rarity client State (was Hud.Slices)", function()
	it("reads the pinned keys from state.modules", function()
		expect(State.odds(modular).Chest).never.toBeNil()
	end)
end)
