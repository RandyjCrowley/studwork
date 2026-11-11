-- v1.3.1 (R19): moved from packages/framework/client/Hud/Slices.spec.luau with the reader
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

	it("reads the per-item odds (v1.6.0) from the framework field", function()
		local state = {
			framework = { itemOdds = { NestEgg = { egg1 = { luck = 2.8, item = "egg1", items = {} } } } },
			modules = {},
		}
		expect(State.itemOdds(state, "NestEgg", "egg1").luck).toBe(2.8)
		expect(State.itemOdds(state, "NestEgg", "egg2")).toBeNil()
		expect(next(State.itemOdds(modular)) == nil).toBe(true)
		expect(next(State.itemOdds(modular, "NestEgg")) == nil).toBe(true)
	end)
end)
