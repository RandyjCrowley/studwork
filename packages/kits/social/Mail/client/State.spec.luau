-- v1.3.1 (R19): moved from packages/framework/client/Hud/{Slices,Visibility}.spec.luau with
-- the readers (Visibility.mailboxCount -> State.count; assertions unchanged).
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

describe("Mail client State (was Hud.Slices / Hud.Visibility)", function()
	it("reads the pinned keys from state.modules", function()
		expect(#State.mailbox(modular)).toBe(2)
		expect(State.count(modular)).toBe(2)
	end)

	it("handles a disabled module and unloaded state", function()
		local s = { loaded = false, modules = {} }
		expect(#State.mailbox(s)).toBe(0)
		expect(State.count(s)).toBe(0)
	end)

	it("still reads a v1.2 flat state", function()
		local flat = { loaded = true, data = { currency = { Coins = 5 } }, ratePerSec = 3, mailbox = { {} } }
		expect(State.count(flat)).toBe(1)
	end)

	it("shows the mailbox slot only with Mail", function()
		expect(State.shown(enabled({ "Mail" }))).toBe(true)
		expect(State.shown(enabled({ "Economy" }))).toBe(false)
		expect(State.shown(enabled({ "Economy", "Rebirth" }))).toBe(false)
	end)

	it("counts mailbox entries", function()
		expect(State.count({ mailbox = { {}, {}, {} } })).toBe(3)
		expect(State.count({})).toBe(0)
		expect(State.count({ mailbox = "bad" })).toBe(0)
		expect(State.count(nil)).toBe(0)
	end)
end)
