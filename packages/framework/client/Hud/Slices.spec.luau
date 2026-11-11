local Slices = require(script.Parent.Slices)
local Visibility = require(script.Parent.Visibility)

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
		expect(Slices.currency(modular, "Coins")).toBe(120)
		expect(Slices.currency(modular, "Gems")).toBe(0)
		expect(Slices.ratePerSec(modular)).toBe(7)
		expect(#Slices.mailbox(modular)).toBe(2)
		expect(Slices.plotName(modular)).toBe("Plot3")
		expect(Slices.odds(modular).Chest).never.toBeNil()
		expect(#Slices.inventory(modular)).toBe(1)
		expect(Visibility.mailboxCount(modular)).toBe(2)
	end)

	it("handles disabled modules and unloaded state", function()
		local s = { loaded = false, modules = {} }
		expect(Slices.currency(s, "Coins")).toBe(0)
		expect(Slices.ratePerSec(s)).toBeNil()
		expect(#Slices.mailbox(s)).toBe(0)
		expect(Visibility.mailboxCount(s)).toBe(0)
		expect(Slices.loaded(s)).toBe(false)
	end)

	it("still reads a v1.2 flat state", function()
		local flat = { loaded = true, data = { currency = { Coins = 5 } }, ratePerSec = 3, mailbox = { {} } }
		expect(Slices.currency(flat, "Coins")).toBe(5)
		expect(Slices.ratePerSec(flat)).toBe(3)
		expect(Visibility.mailboxCount(flat)).toBe(1)
	end)
end)
