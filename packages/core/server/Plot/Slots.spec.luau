local Slots = require(script.Parent.Slots)

local function rec(id: string, tag: string?)
	return { id = id, tag = tag }
end

local function idsOf(list): { string }
	local out = {}
	for _, s in list do
		table.insert(out, s.id)
	end
	return out
end

describe("Slots ordering", function()
	it("sorts naturally", function()
		expect(Slots.naturalLess("slot2", "slot10")).toBe(true)
		expect(Slots.naturalLess("slot10", "slot2")).toBe(false)
		expect(Slots.naturalLess("a", "a1")).toBe(true)
		expect(Slots.naturalLess("b", "a1")).toBe(false)
		expect(Slots.naturalLess("slot02", "slot2")).toBe(true)
		expect(Slots.naturalLess("slot2", "slot02")).toBe(false)
		local s = Slots.sort({ rec("slot10"), rec("slot2"), rec("slot1"), rec("slot2", "dup") })
		expect(idsOf(s)).toEqual({ "slot1", "slot2", "slot10" })
		expect(s[2].tag).toBeNil()
	end)
	it("limits to slotCount", function()
		local all = { rec("c"), rec("a"), rec("b") }
		expect(idsOf(Slots.limit(all, 2))).toEqual({ "a", "b" })
		expect(idsOf(Slots.limit(all, 2.7))).toEqual({ "a", "b" })
		expect(idsOf(Slots.limit(all, nil))).toEqual({ "a", "b", "c" })
		expect(idsOf(Slots.limit(all, 0))).toEqual({ "a", "b", "c" })
		expect(idsOf(Slots.limit(all, 0 / 0))).toEqual({ "a", "b", "c" })
		expect(idsOf(Slots.limit(all, 99))).toEqual({ "a", "b", "c" })
	end)
end)

describe("Slots tag filtering", function()
	it("untagged slots accept anything, tagged only matching items", function()
		expect(Slots.accepts(nil, nil)).toBe(true)
		expect(Slots.accepts("", { "X" })).toBe(true)
		expect(Slots.accepts("Shelf", nil)).toBe(false)
		expect(Slots.accepts("Shelf", { "Plant" })).toBe(false)
		expect(Slots.accepts("Shelf", { "Plant", "Shelf" })).toBe(true)
	end)
	it("firstFree skips taken and incompatible slots", function()
		local slots = { rec("s1", "Shelf"), rec("s2"), rec("s3", "Shelf"), rec("s4") }
		expect(Slots.firstFree(slots, {}, nil)).toBe("s2")
		expect(Slots.firstFree(slots, {}, { "Shelf" })).toBe("s1")
		expect(Slots.firstFree(slots, { s1 = "u" }, { "Shelf" })).toBe("s2")
		expect(Slots.firstFree(slots, { s2 = "u", s4 = "v" }, nil)).toBeNil()
	end)
end)

describe("Slots.validateDisplay", function()
	local slots = { rec("a"), rec("b", "Shelf") }
	local owned = { u1 = true, u2 = true }
	it("rejects not owned / already displayed", function()
		local id, why = Slots.validateDisplay({ slots = slots, displayed = {}, owned = owned, uid = "zz" })
		local _
		expect(id).toBeNil()
		expect(why).toBe(Slots.NOT_OWNED)
		_, why = Slots.validateDisplay({ slots = slots, displayed = { a = "u1" }, owned = owned, uid = "u1" })
		expect(why).toBe(Slots.ALREADY_DISPLAYED)
	end)
	it("explicit slot: no_slot, slot_taken, tag_mismatch, ok", function()
		local _, why =
			Slots.validateDisplay({ slots = slots, displayed = {}, owned = owned, uid = "u1", slotId = "x" })
		expect(why).toBe(Slots.NO_SLOT)
		_, why = Slots.validateDisplay({
			slots = slots,
			displayed = { a = "u2" },
			owned = owned,
			uid = "u1",
			slotId = "a",
		})
		expect(why).toBe(Slots.SLOT_TAKEN)
		_, why =
			Slots.validateDisplay({ slots = slots, displayed = {}, owned = owned, uid = "u1", slotId = "b" })
		expect(why).toBe(Slots.TAG_MISMATCH)
		local id = Slots.validateDisplay({
			slots = slots,
			displayed = {},
			owned = owned,
			uid = "u1",
			slotId = "b",
			itemTags = { "Shelf" },
		})
		expect(id).toBe("b")
	end)
	it("auto slot: first compatible free or no_free_slot", function()
		local id = Slots.validateDisplay({ slots = slots, displayed = {}, owned = owned, uid = "u1" })
		expect(id).toBe("a")
		local none, why =
			Slots.validateDisplay({ slots = slots, displayed = { a = "u2" }, owned = owned, uid = "u1" })
		expect(none).toBeNil()
		expect(why).toBe(Slots.NO_FREE_SLOT)
	end)
	it("slot outside the slotCount limit is no_slot", function()
		local limited = Slots.limit({ rec("s1"), rec("s2"), rec("s3") }, 2)
		local _, why = Slots.validateDisplay({
			slots = limited,
			displayed = {},
			owned = owned,
			uid = "u1",
			slotId = "s3",
		})
		expect(why).toBe(Slots.NO_SLOT)
	end)
end)

describe("Slots.stale", function()
	it("removes unowned uids and duplicates", function()
		local displayed = { s1 = "u1", s2 = "gone", s3 = "u1", s10 = "u2" }
		expect(Slots.stale(displayed, { u1 = true, u2 = true })).toEqual({ "s2", "s3" })
	end)
	it("removes entries for inactive slots only when the slot list is known", function()
		local displayed = { s1 = "u1", s9 = "u2" }
		local owned = { u1 = true, u2 = true }
		expect(Slots.stale(displayed, owned, { rec("s1") })).toEqual({ "s9" })
		expect(Slots.stale(displayed, owned, {})).toEqual({})
		expect(Slots.stale(displayed, owned, nil)).toEqual({})
	end)
	it("everything goes after a rebirth wipe", function()
		expect(Slots.stale({ a = "u1", b = "u2" }, {}, nil)).toEqual({ "a", "b" })
	end)
end)

describe("Slots.planAuto", function()
	it("fills compatible free slots in order and skips displayed items", function()
		local slots = { rec("s1", "Shelf"), rec("s2"), rec("s3") }
		local plan = Slots.planAuto(slots, { s2 = "old" }, {
			{ uid = "old" },
			{ uid = "a" },
			{ uid = "e", tags = { "Shelf" } },
			{ uid = "b" },
		})
		expect(plan).toEqual({ { uid = "a", slotId = "s3" }, { uid = "e", slotId = "s1" } })
	end)
	it("does not mutate displayed", function()
		local displayed = {}
		Slots.planAuto({ rec("s1") }, displayed, { { uid = "a" } })
		local k = next(displayed)
		expect(k).toBeNil()
	end)
end)

describe("Slots.pickPlot", function()
	it("picks by PlotOrder then natural name, skipping owned", function()
		local plots = {
			{ name = "Plot10", owned = false },
			{ name = "Plot2", owned = false },
			{ name = "Zed", order = 5, owned = false },
			{ name = "Alpha", order = 1, owned = true },
		}
		expect(Slots.pickPlot(plots)).toBe(3)
		plots[3].owned = true
		expect(Slots.pickPlot(plots)).toBe(2)
		plots[2].owned = true
		plots[1].owned = true
		expect(Slots.pickPlot(plots)).toBeNil()
	end)
	it("ignores NaN orders", function()
		local plots = { { name = "B", owned = false }, { name = "A", order = 0 / 0, owned = false } }
		expect(Slots.pickPlot(plots)).toBe(2)
	end)
end)
