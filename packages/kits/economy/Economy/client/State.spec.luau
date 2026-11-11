-- core-v1.3.1 (R19): moved from packages/framework/client/Hud/{Slices,Visibility}.spec.luau with
-- the readers (assertions unchanged).
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

local function enabled(list)
	return function(name)
		return table.find(list, name) ~= nil
	end
end

describe("Economy client State (was Hud.Slices / Hud.Visibility)", function()
	it("reads the pinned keys from state.modules", function()
		expect(State.currency(modular, "Coins")).toBe(120)
		expect(State.currency(modular, "Gems")).toBe(0)
		expect(State.ratePerSec(modular)).toBe(7)
	end)

	it("handles a disabled module and unloaded state", function()
		local s = { loaded = false, modules = {} }
		expect(State.currency(s, "Coins")).toBe(0)
		expect(State.ratePerSec(s)).toBeNil()
	end)

	it("still reads a v1.2 flat state", function()
		local flat = { loaded = true, data = { currency = { Coins = 5 } }, ratePerSec = 3, mailbox = { {} } }
		expect(State.currency(flat, "Coins")).toBe(5)
		expect(State.ratePerSec(flat)).toBe(3)
	end)

	it("shows currency and rate with Economy", function()
		expect(State.shown(enabled({ "Economy", "Rebirth" }), {})).toEqual({ currency = true, rate = true })
	end)

	it("hides currency and rate without Economy", function()
		local shown = State.shown(enabled({}), {})
		expect(shown.currency).toBe(false)
		expect(shown.rate).toBe(false)
	end)

	it("hides the rate when showRate = false", function()
		local shown = State.shown(enabled({ "Economy" }), { showRate = false })
		expect(shown.currency).toBe(true)
		expect(shown.rate).toBe(false)
	end)
end)
