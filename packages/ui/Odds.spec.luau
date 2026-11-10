local Odds = require(script.Parent.Odds)

local ORDER = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Mythic = 6, Secret = 7 }
local DEFS = {
	{ id = "a", name = "Apple", rarity = "Common" },
	{ id = "b", name = "Bolt", rarity = "Rare" },
	{ id = "c", name = "Crown", rarity = "Secret" },
	{ id = "d", name = "Drum", rarity = "Common" },
}
local ODDS = { a = 0.5, b = 0.1, c = 0.0001, d = 0.3999, z = 0, q = 0 / 0 }

describe("Odds.rows", function()
	it("sorts by rarity, rarest last, ties by probability", function()
		local rows = Odds.rows(ODDS, DEFS, ORDER)
		local ids = {}
		for _, r in rows do
			table.insert(ids, r.id)
		end
		expect(ids).toEqual({ "a", "d", "b", "c" })
		expect(rows[4].rarity).toBe("Secret")
		expect(rows[1].name).toBe("Apple")
	end)
	it("sorts by probability", function()
		local rows = Odds.rows(ODDS, DEFS, ORDER, "probability")
		expect(rows[1].id).toBe("a")
		expect(rows[#rows].id).toBe("c")
	end)
	it("drops zero / NaN chances and keeps unknown ids", function()
		local rows = Odds.rows({ x = 0.25, z = 0 }, DEFS, ORDER)
		expect(#rows).toBe(1)
		expect(rows[1].name).toBe("x")
		expect(rows[1].rarity).toBeNil()
	end)
	it("totals probabilities", function()
		expect(Odds.total(Odds.rows(ODDS, DEFS, ORDER))).toBeNear(1, 1e-9)
	end)
end)

local DETAIL = {
	tableId = "Egg",
	paid = true,
	items = { a = 0.9, c = 0.1 },
	mutationChance = 0.1,
	mutations = {
		{ id = "Gold", name = "Golden", probability = 0.07 },
		{ id = "Rainbow", name = "Rainbow", probability = 0.03 },
		{ id = "Zero", name = "Zero", probability = 0 },
	},
	outcomes = {
		{ itemId = "a", probability = 0.81 },
		{ itemId = "a", mutation = "Gold", probability = 0.063 },
		{ itemId = "a", mutation = "Rainbow", probability = 0.027 },
		{ itemId = "c", probability = 0.09 },
		{ itemId = "c", mutation = "Gold", probability = 0.007 },
		{ itemId = "c", mutation = "Rainbow", probability = 0.003 },
	},
	pity = { threshold = 50, minTier = "Legendary", items = { c = 1 } },
}

describe("Odds detail", function()
	it("mutationRows: most likely first, zero dropped", function()
		local rows = Odds.mutationRows(DETAIL)
		expect(#rows).toBe(2)
		expect(rows[1].name).toBe("Golden")
		expect(rows[2].probability).toBe(0.03)
		expect(#Odds.mutationRows(nil)).toBe(0)
	end)
	it("outcomeRows: one row per item x mutation, named, summing to 1", function()
		local rows = Odds.outcomeRows(DETAIL, DEFS, ORDER, "probability")
		expect(#rows).toBe(6)
		expect(rows[1].id).toBe("a|-")
		expect(rows[1].name).toBe("Apple")
		expect(rows[2].name).toBe("Crown")
		expect(rows[3].name).toBe("Golden Apple")
		expect(rows[#rows].name).toBe("Rainbow Crown")
		expect(rows[#rows].rarity).toBe("Secret")
		expect(Odds.total(rows)).toBeNear(1, 1e-9)
	end)
	it("pityLine", function()
		expect(Odds.pityLine(DETAIL)).toBe("Guaranteed Legendary+ at least every 50 rolls")
		expect(Odds.pityLine({ pity = { threshold = 1, minTier = "Epic" } })).toBe(
			"Guaranteed Epic+ on every roll"
		)
		expect(Odds.pityLine({})).toBeNil()
	end)
end)

describe("Odds.luckLine (v1.2)", function()
	it("shows the luck only for luck-disclosed details with luck ~= 1", function()
		expect(Odds.luckLine({ luckDisclosed = true, luck = 1.5 })).toBe("Includes your luck x1.5")
		expect(Odds.luckLine({ luckDisclosed = true, luck = 3 })).toBe("Includes your luck x3")
		expect(Odds.luckLine({ luckDisclosed = true, luck = 1.25 })).toBe("Includes your luck x1.25")
		expect(Odds.luckLine({ luckDisclosed = true, luck = 1 })).toBeNil()
		expect(Odds.luckLine({ luckDisclosed = false, luck = 2 })).toBeNil()
		expect(Odds.luckLine({ luck = 2 })).toBeNil()
		expect(Odds.luckLine({ luckDisclosed = true, luck = 0 / 0 })).toBeNil()
		expect(Odds.luckLine({ luckDisclosed = true, luck = "2" })).toBeNil()
		expect(Odds.luckLine(nil)).toBeNil()
	end)
end)
