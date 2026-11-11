local RebirthMath = require(script.Parent.RebirthMath)

local cfg = { baseCost = 5000, costGrowth = 3, multiplierPerRebirth = 0.5, maxRebirths = 3 }

describe("RebirthMath", function()
	it("cost = floor(base * growth ^ rebirths)", function()
		expect(RebirthMath.cost(5000, 3, 0)).toBe(5000)
		expect(RebirthMath.cost(5000, 3, 1)).toBe(15000)
		expect(RebirthMath.cost(5000, 3, 2)).toBe(45000)
		expect(RebirthMath.cost(100, 1.5, 3)).toBe(337) -- 337.5
	end)
	it("multiplier = 1 + rebirths * perRebirth", function()
		expect(RebirthMath.multiplier(0, 0.5)).toBe(1)
		expect(RebirthMath.multiplier(4, 0.5)).toBe(3)
	end)
	it("checks max before affordability", function()
		local ok, reason = RebirthMath.check(3, 1e12, cfg)
		expect(ok).toBe(false)
		expect(reason).toBe("maxed")
		ok, reason = RebirthMath.check(1, 14999, cfg)
		expect(ok).toBe(false)
		expect(reason).toBe("cannot_afford")
		local cost
		ok, reason, cost = RebirthMath.check(1, 15000, cfg)
		expect(ok).toBe(true)
		expect(reason).toBeNil()
		expect(cost).toBe(15000)
	end)
	it("defaults resetCurrencies to the primary", function()
		expect(RebirthMath.resetList(cfg, "Coins")).toEqual({ "Coins" })
		expect(RebirthMath.resetList({
			baseCost = 1,
			costGrowth = 1,
			multiplierPerRebirth = 0,
			resetCurrencies = { "A", "B" },
		}, "Coins")).toEqual({ "A", "B" })
	end)
end)
