local UpgradeMath = require(script.Parent.UpgradeMath)

describe("UpgradeMath.cost", function()
	it("follows floor(base * growth ^ level)", function()
		expect(UpgradeMath.cost(50, 1.6, 0, 25)).toBe(50)
		expect(UpgradeMath.cost(50, 1.6, 1, 25)).toBe(80)
		expect(UpgradeMath.cost(50, 1.6, 2, 25)).toBe(128)
		expect(UpgradeMath.cost(50, 1.6, 3, 25)).toBe(204) -- 204.8
	end)
	it("is nil at max level", function()
		expect(UpgradeMath.cost(100, 2, 9, 10)).toBe(51200)
		expect(UpgradeMath.cost(100, 2, 10, 10)).toBeNil()
		expect(UpgradeMath.cost(100, 2, 11, 10)).toBeNil()
	end)
	it("is nil on overflow", function()
		expect(UpgradeMath.cost(1e300, 1e10, 5, 100)).toBeNil()
	end)
end)

describe("UpgradeMath effects", function()
	local upgrades = {
		Boost = { effect = "incomeMultiplier", perLevel = 0.1, resetsOnRebirth = true },
		Bag = { effect = "inventoryCap", perLevel = 5, resetsOnRebirth = false },
		Misc = { effect = "custom", perLevel = 1 },
	}
	it("income factor is 1 + level * perLevel", function()
		expect(UpgradeMath.incomeFactor(0, 0.1)).toBe(1)
		expect(UpgradeMath.incomeFactor(5, 0.1)).toBeNear(1.5)
	end)
	it("cap bonus sums inventoryCap upgrades only", function()
		expect(UpgradeMath.capBonus(upgrades, { Boost = 3, Bag = 2, Misc = 4 })).toBe(10)
	end)
	it("rebirth keeps resetsOnRebirth == false and unknown ids", function()
		expect(UpgradeMath.afterRebirth(upgrades, { Boost = 3, Bag = 2, Misc = 4, Gone = 1 })).toEqual({
			Bag = 2,
			Gone = 1,
		})
	end)
end)
