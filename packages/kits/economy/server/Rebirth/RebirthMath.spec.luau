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

describe("RebirthMath.keptInventory (Decision 2)", function()
	local DEFS: { [string]: any } = {
		plain = { keepOnRebirth = nil },
		always = { keepOnRebirth = true },
		never = { keepOnRebirth = false },
	}
	local function getDef(id: string): any
		return DEFS[id]
	end
	local INV = {
		u1 = { itemId = "plain", source = "paid:Egg" },
		u2 = { itemId = "plain", source = "roll" },
		u3 = { itemId = "plain" },
		u4 = { itemId = "always", source = "roll" },
		u5 = { itemId = "never", source = "paid:Egg" },
		u6 = { itemId = "ghost", source = "roll" },
		u7 = { itemId = "plain", source = "xpaid:Egg" },
	}
	it("keeps paid copies, wipes free ones, honours overrides, keeps unknown ids", function()
		local kept, unknown = RebirthMath.keptInventory(INV, getDef)
		expect(kept.u1).toBe(INV.u1)
		expect(kept.u2).toBeNil()
		expect(kept.u3).toBeNil()
		expect(kept.u4).toBe(INV.u4)
		expect(kept.u5).toBeNil()
		expect(kept.u6).toBe(INV.u6)
		expect(kept.u7).toBeNil()
		expect(unknown).toEqual({ "ghost" })
	end)
	it("does not mutate the input inventory", function()
		RebirthMath.keptInventory(INV, getDef)
		expect(INV.u2.itemId).toBe("plain")
	end)
	it("keeps everything when no defs can be resolved", function()
		local kept = RebirthMath.keptInventory(INV, function(): any
			return nil
		end)
		local n = 0
		for _ in kept do
			n += 1
		end
		expect(n).toBe(7)
	end)
end)
