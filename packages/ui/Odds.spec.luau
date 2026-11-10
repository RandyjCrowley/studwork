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
