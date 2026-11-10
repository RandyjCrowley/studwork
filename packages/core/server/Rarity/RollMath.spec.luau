local RollMath = require(script.Parent.RollMath)
local SeededRng = require(script.Parent.SeededRng)

local TIERS = {
	common = "Common",
	rare = "Rare",
	epic = "Epic",
	legend = "Legendary",
}
local function tierOf(id: string): any
	return TIERS[id]
end

local ENTRIES = {
	{ itemId = "common", weight = 70 },
	{ itemId = "rare", weight = 20 },
	{ itemId = "epic", weight = 9 },
	{ itemId = "legend", weight = 1 },
}

local function simulate(list, n: number, seed: number): { [string]: number }
	local rng = SeededRng.new(seed)
	local counts: { [string]: number } = {}
	for _ = 1, n do
		local e = RollMath.pick(list, rng())
		assert(e, "pick returned nil")
		counts[e.itemId] = (counts[e.itemId] or 0) + 1
	end
	return counts
end

describe("SeededRng", function()
	it("is deterministic and in [0, 1)", function()
		local a, b = SeededRng.new(42), SeededRng.new(42)
		for _ = 1, 1000 do
			local x = a()
			expect(x).toBe(b())
			expect(x >= 0 and x < 1).toBe(true)
		end
	end)
end)

describe("RollMath luck", function()
	it("sanitizes luck", function()
		expect(RollMath.sanitizeLuck(nil)).toBe(1)
		expect(RollMath.sanitizeLuck(0)).toBe(1)
		expect(RollMath.sanitizeLuck(-3)).toBe(1)
		expect(RollMath.sanitizeLuck(0 / 0)).toBe(1)
		expect(RollMath.sanitizeLuck(math.huge)).toBe(1)
		expect(RollMath.sanitizeLuck("5")).toBe(1)
		expect(RollMath.sanitizeLuck(2.5)).toBe(2.5)
		expect(RollMath.sanitizeLuck(1e9)).toBe(RollMath.MAX_LUCK)
	end)

	it("multiplies only tiers >= luckMinTier (default Rare)", function()
		local list = RollMath.buildWeights(ENTRIES, tierOf, 2, nil)
		local w = {}
		for _, e in list.entries do
			w[e.itemId] = e.weight
		end
		expect(w.common).toBe(70)
		expect(w.rare).toBe(40)
		expect(w.epic).toBe(18)
		expect(w.legend).toBe(2)
		expect(list.total).toBe(130)
		local epicOnly = RollMath.buildWeights(ENTRIES, tierOf, 2, "Epic")
		expect(epicOnly.total).toBe(70 + 20 + 18 + 2)
	end)

	it("raises the share of high tiers in simulated rolls", function()
		local base = simulate(RollMath.buildWeights(ENTRIES, tierOf, 1, nil), 20000, 7)
		local lucky = simulate(RollMath.buildWeights(ENTRIES, tierOf, 3, nil), 20000, 7)
		-- legend share: 1/100 -> 3/160
		expect(lucky.legend or 0).toBeGreaterThan((base.legend or 0) * 1.5)
		expect(lucky.common or 0).toBeLessThan(base.common or 0)
	end)

	it("drops unknown items and non-positive / non-finite weights", function()
		local list = RollMath.buildWeights({
			{ itemId = "common", weight = 1 },
			{ itemId = "ghost", weight = 5 },
			{ itemId = "rare", weight = 0 },
			{ itemId = "epic", weight = 0 / 0 },
			{ itemId = "legend", weight = -1 },
		}, tierOf, 1, nil)
		expect(#list.entries).toBe(1)
		expect(list.total).toBe(1)
	end)
end)

describe("RollMath weighted pick", function()
	it("matches weights within tolerance over 50k seeded rolls", function()
		local n = 50000
		local counts = simulate(RollMath.buildWeights(ENTRIES, tierOf, 1, nil), n, 12345)
		expect(counts.common / n).toBeNear(0.70, 0.01)
		expect(counts.rare / n).toBeNear(0.20, 0.01)
		expect(counts.epic / n).toBeNear(0.09, 0.01)
		expect(counts.legend / n).toBeNear(0.01, 0.003)
	end)

	it("maps u boundaries onto cumulative weights", function()
		local list = RollMath.buildWeights(ENTRIES, tierOf, 1, nil)
		expect((RollMath.pick(list, 0) :: any).itemId).toBe("common")
		expect((RollMath.pick(list, 0.6999) :: any).itemId).toBe("common")
		expect((RollMath.pick(list, 0.7) :: any).itemId).toBe("rare")
		expect((RollMath.pick(list, 0.995) :: any).itemId).toBe("legend")
		expect((RollMath.pick(list, 0.99999999) :: any).itemId).toBe("legend")
	end)

	it("returns nil for an empty list", function()
		expect(RollMath.pick({ entries = {}, total = 0 }, 0.5)).toBeNil()
	end)
end)

describe("RollMath odds", function()
	it("sums to 1 and equals weight / total (with luck)", function()
		for _, luck in { 1, 2, 7.5, 1e9 } do
			local list = RollMath.buildWeights(ENTRIES, tierOf, luck, nil)
			local odds = RollMath.odds(list)
			local sum = 0
			for _, p in odds do
				sum += p
			end
			expect(sum).toBeNear(1, 1e-12)
			for _, e in list.entries do
				expect(odds[e.itemId]).toBeNear(e.weight / list.total, 1e-12)
			end
		end
	end)

	it("sums duplicate entries of the same item", function()
		local odds = RollMath.odds(RollMath.buildWeights({
			{ itemId = "common", weight = 1 },
			{ itemId = "common", weight = 1 },
			{ itemId = "rare", weight = 2 },
		}, tierOf, 1, nil))
		expect(odds.common).toBeNear(0.5, 1e-12)
		expect(odds.rare).toBeNear(0.5, 1e-12)
	end)

	it("is empty for an empty table", function()
		local odds = RollMath.odds({ entries = {}, total = 0 })
		expect((next(odds))).toBeNil()
	end)
end)

describe("RollMath pity", function()
	it("validates pity config", function()
		expect(RollMath.validPity({ threshold = 10, minTier = "Epic" })).toBe(true)
		expect(RollMath.validPity({ threshold = 0, minTier = "Epic" })).toBe(false)
		expect(RollMath.validPity({ threshold = 2.5, minTier = "Epic" })).toBe(false)
		expect(RollMath.validPity({ threshold = 5, minTier = "Nope" })).toBe(false)
		expect(RollMath.validPity(nil)).toBe(false)
	end)

	it("forces on the threshold-th roll and resets on a hit", function()
		local threshold, minTier = 5, "Epic"
		local count = 0
		local forcedAt = nil
		-- always-common rolls until forced
		for roll = 1, threshold do
			if RollMath.pityForces(count, threshold) then
				forcedAt = roll
				break
			end
			count = RollMath.pityAfter(count, "Common", minTier)
		end
		expect(forcedAt).toBe(threshold)
		expect(count).toBe(threshold - 1)
		expect(RollMath.pityAfter(count, "Epic", minTier)).toBe(0)
		expect(RollMath.pityAfter(count, "Legendary", minTier)).toBe(0)
		expect(RollMath.pityAfter(2, "Rare", minTier)).toBe(3)
	end)

	it("restricts the pool to tiers >= minTier, or nil when none qualify", function()
		local list = RollMath.buildWeights(ENTRIES, tierOf, 1, nil)
		local r = RollMath.restrictTo(list, "Epic")
		assert(r, "expected a restricted list")
		expect(#r.entries).toBe(2)
		expect(r.total).toBe(10)
		local counts = simulate(r, 2000, 3)
		expect(counts.common).toBeNil()
		expect(counts.rare).toBeNil()
		local commonsOnly = RollMath.buildWeights({ { itemId = "common", weight = 1 } }, tierOf, 1, nil)
		expect(RollMath.restrictTo(commonsOnly, "Epic")).toBeNil()
	end)

	it("threshold 1 forces every roll", function()
		expect(RollMath.pityForces(0, 1)).toBe(true)
	end)
end)

describe("RollMath mutations", function()
	local MUTATIONS = {
		{ id = "Gold", name = "Gold", multiplier = 2, weight = 8 },
		{ id = "Rainbow", name = "Rainbow", multiplier = 5, weight = 2 },
		{ id = "Plain", name = "Plain", multiplier = 1 }, -- default weight 1
		{ id = "Never", name = "Never", multiplier = 9, weight = 0 },
	}

	it("rolls the chance, then picks by weight (default 1)", function()
		local rng = SeededRng.new(99)
		local n = 40000
		local counts: { [string]: number } = {}
		local hits = 0
		for _ = 1, n do
			local m = RollMath.rollMutation(0.25, MUTATIONS, rng)
			if m then
				hits += 1
				counts[m] = (counts[m] or 0) + 1
			end
		end
		expect(hits / n).toBeNear(0.25, 0.01)
		expect(counts.Gold / hits).toBeNear(8 / 11, 0.02)
		expect(counts.Rainbow / hits).toBeNear(2 / 11, 0.02)
		expect(counts.Plain / hits).toBeNear(1 / 11, 0.02)
		expect(counts.Never).toBeNil()
	end)

	it("never mutates with chance 0 / nil / NaN or no mutations, always with chance >= 1", function()
		local rng = SeededRng.new(1)
		for _ = 1, 200 do
			expect(RollMath.rollMutation(0, MUTATIONS, rng)).toBeNil()
			expect(RollMath.rollMutation(nil, MUTATIONS, rng)).toBeNil()
			expect(RollMath.rollMutation(0 / 0, MUTATIONS, rng)).toBeNil()
			expect(RollMath.rollMutation(1, {}, rng)).toBeNil()
			expect(RollMath.rollMutation(1, nil, rng)).toBeNil()
			expect(RollMath.rollMutation(5, MUTATIONS, rng)).never.toBeNil()
		end
	end)
end)
