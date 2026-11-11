local Slices = require(script.Parent.Slices)

-- core-v1.3.1 (R19): the kit-specific readers (currency, rate, mailbox, odds, inventory, plot name)
-- moved with their assertions to the kits' client/State.spec.luau; these are the generic readers
-- they replaced, on the same pinned keys.
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

describe("Hud.Slices (per-module client slices, no FlatState)", function()
	it("reads the pinned keys from state.modules", function()
		expect(Slices.isModular(modular)).toBe(true)
		expect(Slices.data(modular, "Economy").currency.Coins).toBe(120)
		expect(Slices.extra(modular, "Economy", "ratePerSec")).toBe(7)
		expect(#Slices.extra(modular, "Mail", "mailbox")).toBe(2)
		expect(Slices.extra(modular, "Plot", "plotName")).toBe("Plot3")
		expect(Slices.extra(modular, "Rarity", "odds").Chest).never.toBeNil()
		expect(#Slices.data(modular, "Inventory").inventory).toBe(1)
	end)

	it("handles disabled modules and unloaded state", function()
		local s = { loaded = false, modules = {} }
		expect(Slices.data(s, "Economy")).toBeNil()
		expect(Slices.extra(s, "Economy", "ratePerSec")).toBeNil()
		expect(Slices.extra(s, "Mail", "mailbox")).toBeNil()
		expect(Slices.loaded(s)).toBe(false)
		expect(Slices.loaded(modular)).toBe(true)
	end)

	it("still reads a v1.2 flat state", function()
		local flat = { loaded = true, data = { currency = { Coins = 5 } }, ratePerSec = 3, mailbox = { {} } }
		expect(Slices.isModular(flat)).toBe(false)
		expect(Slices.data(flat, "Economy").currency.Coins).toBe(5)
		expect(Slices.extra(flat, "Economy", "ratePerSec")).toBe(3)
		expect(#Slices.extra(flat, "Mail", "mailbox")).toBe(1)
	end)
end)
