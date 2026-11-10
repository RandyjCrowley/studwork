local SlotCache = require(script.Parent.SlotCache)
local Slots = require(script.Parent.Slots)

local function fixture()
	local parts = { slot2 = { tag = nil }, slot1 = { tag = "Shelf" }, slot10 = { tag = nil } }
	local cache = SlotCache.new(function()
		return parts
	end, function(part)
		return part.tag
	end, Slots.limit)
	return cache, parts
end

describe("Plot.SlotCache", function()
	it("scans once and reuses the map", function()
		local cache = fixture()
		local records, parts = cache:get(nil)
		cache:get(nil)
		cache:get(nil)
		expect(cache.scans).toBe(1)
		expect(#records).toBe(3)
		expect(records[1].id).toBe("slot1")
		expect(records[1].tag).toBe("Shelf")
		expect(records[3].id).toBe("slot10")
		expect(parts.slot2 ~= nil).toBe(true)
	end)
	it("applies slotCount without rescanning", function()
		local cache = fixture()
		expect(#(cache:get(2))).toBe(2)
		expect(#(cache:get(nil))).toBe(3)
		expect(cache.scans).toBe(1)
	end)
	it("rescans after invalidate", function()
		local cache, parts = fixture()
		cache:get(nil)
		parts.slot3 = { tag = nil }
		expect(#(cache:get(nil))).toBe(3) -- stale until invalidated
		cache:invalidate()
		expect(#(cache:get(nil))).toBe(4)
		expect(cache.scans).toBe(2)
	end)
	it("isSlotChange ignores visuals and non-slot parts", function()
		expect(SlotCache.isSlotChange(true, "slot1", false)).toBe(true)
		expect(SlotCache.isSlotChange(true, "slot1", true)).toBe(false) -- inside CoreDisplays
		expect(SlotCache.isSlotChange(true, nil, false)).toBe(false)
		expect(SlotCache.isSlotChange(true, "", false)).toBe(false)
		expect(SlotCache.isSlotChange(false, "slot1", false)).toBe(false)
	end)
end)

describe("Plot early-out order (M5)", function()
	it("precheck rejects unowned / already displayed items without a slot lookup", function()
		local cache = fixture()
		local displayed = { slot1 = "u1" }
		local owned = { u1 = true, u2 = true }
		expect(Slots.precheck(owned, displayed, "nope")).toBe(Slots.NOT_OWNED)
		expect(Slots.precheck(owned, displayed, "u1")).toBe(Slots.ALREADY_DISPLAYED)
		expect(cache.scans).toBe(0)
		expect(Slots.precheck(owned, displayed, "u2")).toBeNil()
	end)
	it("validateDisplay reports not_owned before slot errors", function()
		local _, reason = Slots.validateDisplay({
			slots = {},
			displayed = {},
			owned = {},
			uid = "x",
			slotId = "missing",
		})
		expect(reason).toBe(Slots.NOT_OWNED)
	end)
end)

describe("Plot.resetDisplayed (Rebirth reset step, M7)", function()
	local function data()
		return {
			displayed = { slot1 = "u1", slot2 = "gone" },
			inventory = { u1 = { uid = "u1" } },
			currency = { Coins = 5 },
		}
	end
	it("clears every slot by default", function()
		local d = data()
		Slots.resetDisplayed(d, nil)
		expect((next(d.displayed))).toBeNil()
	end)
	it("keepDisplayed keeps owned items but drops items that left the inventory", function()
		local d = data()
		Slots.resetDisplayed(d, true)
		expect(d.displayed.slot1).toBe("u1")
		expect(d.displayed.slot2).toBeNil()
	end)
	it("never writes other sections", function()
		local d = data()
		local inv, cur = d.inventory, d.currency
		Slots.resetDisplayed(d, false)
		expect(d.inventory == inv).toBe(true)
		expect(d.inventory.u1 ~= nil).toBe(true)
		expect(d.currency == cur).toBe(true)
		expect(d.currency.Coins).toBe(5)
	end)
end)
