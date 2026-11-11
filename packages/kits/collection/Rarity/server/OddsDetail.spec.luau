local RollMath = require(script.Parent.RollMath)
local SeededRng = require(script.Parent.SeededRng)

local TIERS = { common = "Common", rare = "Rare", epic = "Epic", legend = "Legendary" }
local function tierOf(id: string): any
	return TIERS[id]
end
local ENTRIES = {
	{ itemId = "common", weight = 60 },
	{ itemId = "rare", weight = 25 },
	{ itemId = "epic", weight = 12 },
	{ itemId = "legend", weight = 3 },
}
local MUTATIONS = {
	{ id = "Gold", name = "Gold", multiplier = 2, weight = 3 },
	{ id = "Rainbow", name = "Rainbow", multiplier = 5 }, -- default weight 1
	{ id = "Broken", name = "Broken", multiplier = 1, weight = 0 }, -- never picked
	{ id = "Nan", name = "Nan", multiplier = 1, weight = 0 / 0 }, -- never picked
}
local CHANCE = 0.2
local PITY = { threshold = 10, minTier = "Epic" }

local function key(itemId: string, mutation: string?): string
	return itemId .. "|" .. (mutation or "-")
end

describe("RollMath.oddsDetail", function()
	local list = RollMath.buildWeights(ENTRIES, tierOf, nil, nil)
	local d = RollMath.oddsDetail("T", true, list, PITY, CHANCE, MUTATIONS)

	it("lists base odds, mutation odds (default weight 1, ignored weights) and pity", function()
		expect(d.tableId).toBe("T")
		expect(d.paid).toBe(true)
		expect(d.items.legend).toBeNear(0.03, 1e-12)
		expect(d.mutationChance).toBe(0.2)
		expect(#d.mutations).toBe(2)
		expect(d.mutations[1].id).toBe("Gold")
		expect(d.mutations[1].probability).toBeNear(0.15, 1e-12)
		expect(d.mutations[2].probability).toBeNear(0.05, 1e-12)
		local pity = d.pity :: any
		expect(pity.threshold).toBe(10)
		expect(pity.items.epic).toBeNear(0.8, 1e-12)
		expect(pity.items.legend).toBeNear(0.2, 1e-12)
		expect(pity.items.common).toBeNil()
	end)

	it("outcomes cover item x (none + mutations) and sum to 1", function()
		expect(#d.outcomes).toBe(4 * 3)
		local sum = 0
		for _, o in d.outcomes do
			sum += o.probability
		end
		expect(sum).toBeNear(1, 1e-12)
	end)

	it("handles no mutations, chance >= 1 and pity that cannot apply", function()
		local none = RollMath.oddsDetail("T", false, list, nil, 0.5, nil)
		expect(none.mutationChance).toBe(0)
		expect(#none.outcomes).toBe(4)
		expect(none.pity).toBeNil()
		local always = RollMath.oddsDetail("T", false, list, nil, 3, MUTATIONS)
		expect(always.mutationChance).toBe(1)
		expect(#always.outcomes).toBe(8) -- no "no mutation" outcome
		local zero = RollMath.oddsDetail("T", false, list, nil, 0.5, { MUTATIONS[3] })
		expect(zero.mutationChance).toBe(0)
		local commons = RollMath.buildWeights({ { itemId = "common", weight = 1 } }, tierOf, nil, nil)
		expect(RollMath.oddsDetail("T", false, commons, PITY, 0, nil).pity).toBeNil()
		expect(RollMath.oddsDetail("T", false, list, { threshold = 0, minTier = "Epic" }, 0, nil).pity).toBeNil()
	end)
end)

describe("RollMath.step Monte Carlo (same step as Rarity.rollInto)", function()
	local list = RollMath.buildWeights(ENTRIES, tierOf, nil, nil)
	local d = RollMath.oddsDetail("T", true, list, PITY, CHANCE, MUTATIONS)
	local N = 200000

	it("empirical outcome frequencies match oddsDetail within 4 SE (pity off)", function()
		local rng = SeededRng.new(20261110)
		local counts: { [string]: number } = {}
		for _ = 1, N do
			local r = RollMath.step(list, nil, 0, CHANCE, MUTATIONS, rng) :: any
			local k = key(r.entry.itemId, r.mutation)
			counts[k] = (counts[k] or 0) + 1
		end
		local maxDev, maxZ = 0, 0
		local seen = 0
		for _, o in d.outcomes do
			local k = key(o.itemId, o.mutation)
			local f = (counts[k] or 0) / N
			seen += counts[k] or 0
			local se = math.sqrt(o.probability * (1 - o.probability) / N)
			local dev = math.abs(f - o.probability)
			maxDev = math.max(maxDev, dev)
			maxZ = math.max(maxZ, dev / se)
			expect(dev).toBeLessThan(4 * se)
		end
		expect(seen).toBe(N) -- no outcome outside the disclosed list
		print(
			string.format(
				"[MonteCarlo] %d rolls, %d outcomes: max |dev| = %.5f, max z = %.2f",
				N,
				#d.outcomes,
				maxDev,
				maxZ
			)
		)
	end)

	it("forced rolls match pity.items and misses never exceed threshold - 1", function()
		local rng = SeededRng.new(777)
		local count, streak, maxStreak, forcedN = 0, 0, 0, 0
		local forcedCounts: { [string]: number } = {}
		for _ = 1, N do
			local r = RollMath.step(list, PITY :: any, count, CHANCE, MUTATIONS, rng) :: any
			if r.forced then
				forcedN += 1
				forcedCounts[r.entry.itemId] = (forcedCounts[r.entry.itemId] or 0) + 1
			end
			count = r.pityCount
			if r.entry.tier == "Common" or r.entry.tier == "Rare" then
				streak += 1
				maxStreak = math.max(maxStreak, streak)
			else
				streak = 0
			end
		end
		expect(maxStreak <= PITY.threshold - 1).toBe(true)
		expect(forcedN).toBeGreaterThan(1000)
		local pityItems = (d.pity :: any).items
		local maxDev = 0
		for id, p in pityItems do
			local f = (forcedCounts[id] or 0) / forcedN
			local se = math.sqrt(p * (1 - p) / forcedN)
			maxDev = math.max(maxDev, math.abs(f - p))
			expect(math.abs(f - p)).toBeLessThan(4 * se)
		end
		expect(forcedCounts.common).toBeNil()
		print(
			string.format(
				"[MonteCarlo] pity: %d forced of %d, max |dev| = %.5f, max miss streak = %d",
				forcedN,
				N,
				maxDev,
				maxStreak
			)
		)
	end)
end)

describe("RollMath.oddsDetail with luck (v1.2, N4)", function()
	it("reports luck / luckDisclosed and uses the luck-weighted list", function()
		local plain =
			RollMath.oddsDetail("T", true, RollMath.buildWeights(ENTRIES, tierOf, nil, nil), PITY, 0, nil)
		expect(plain.luck).toBe(1)
		expect(plain.luckDisclosed).toBe(false)
		local lucky = RollMath.oddsDetail(
			"T",
			true,
			RollMath.buildWeights(ENTRIES, tierOf, 2, nil),
			PITY,
			0,
			nil,
			2,
			true
		)
		expect(lucky.luck).toBe(2)
		expect(lucky.luckDisclosed).toBe(true)
		-- weights 60 / 50 / 24 / 6 (total 140)
		expect(lucky.items.legend).toBeNear(6 / 140, 1e-12)
		expect(lucky.items.common).toBeNear(60 / 140, 1e-12)
		local nanLuck = RollMath.oddsDetail(
			"T",
			true,
			RollMath.buildWeights(ENTRIES, tierOf, nil, nil),
			nil,
			0,
			nil,
			0 / 0
		)
		expect(nanLuck.luck).toBe(1)
	end)
end)

-- Hard requirement (W_B.md 6): >= 200k seeded rolls at luck 1, 1.5 and 3 through RollMath.step
-- (with mutations; plus a pity table) against oddsDetail(..., luck): every outcome within 4 SE.
describe("RollMath.step Monte Carlo at luck 1, 1.5, 3", function()
	local N = 200000
	for i, luck in { 1, 1.5, 3 } do
		it(string.format("luck x%s: outcomes match oddsDetail within 4 SE", tostring(luck)), function()
			local list = RollMath.buildWeights(ENTRIES, tierOf, luck, nil)
			local d = RollMath.oddsDetail("T", true, list, PITY, CHANCE, MUTATIONS, luck, true)
			expect(d.luck).toBe(luck)
			local rng = SeededRng.new(4242 + i)
			local counts: { [string]: number } = {}
			for _ = 1, N do
				local r = RollMath.step(list, nil, 0, CHANCE, MUTATIONS, rng) :: any
				local k = key(r.entry.itemId, r.mutation)
				counts[k] = (counts[k] or 0) + 1
			end
			local maxDev, maxZ, seen = 0, 0, 0
			for _, o in d.outcomes do
				local k = key(o.itemId, o.mutation)
				local f = (counts[k] or 0) / N
				seen += counts[k] or 0
				local se = math.sqrt(o.probability * (1 - o.probability) / N)
				local dev = math.abs(f - o.probability)
				maxDev = math.max(maxDev, dev)
				maxZ = math.max(maxZ, dev / se)
				expect(dev).toBeLessThan(4 * se)
			end
			expect(seen).toBe(N)
			print(
				string.format(
					"[MonteCarlo] luck x%s: %d rolls, %d outcomes: max |dev| = %.5f, max z = %.2f",
					tostring(luck),
					N,
					#d.outcomes,
					maxDev,
					maxZ
				)
			)
		end)

		it(string.format("luck x%s: pity table forced rolls match pity.items", tostring(luck)), function()
			local list = RollMath.buildWeights(ENTRIES, tierOf, luck, nil)
			local d = RollMath.oddsDetail("T", true, list, PITY, CHANCE, MUTATIONS, luck, true)
			local pityItems = (d.pity :: any).items
			local rng = SeededRng.new(9000 + i)
			local count, streak, maxStreak, forcedN = 0, 0, 0, 0
			local forcedCounts: { [string]: number } = {}
			for _ = 1, N do
				local r = RollMath.step(list, PITY :: any, count, CHANCE, MUTATIONS, rng) :: any
				if r.forced then
					forcedN += 1
					forcedCounts[r.entry.itemId] = (forcedCounts[r.entry.itemId] or 0) + 1
				end
				count = r.pityCount
				if r.entry.tier == "Common" or r.entry.tier == "Rare" then
					streak += 1
					maxStreak = math.max(maxStreak, streak)
				else
					streak = 0
				end
			end
			expect(maxStreak <= PITY.threshold - 1).toBe(true)
			expect(forcedN).toBeGreaterThan(1000)
			local maxZ = 0
			for id, p in pityItems do
				local f = (forcedCounts[id] or 0) / forcedN
				local se = math.sqrt(p * (1 - p) / forcedN)
				maxZ = math.max(maxZ, math.abs(f - p) / se)
				expect(math.abs(f - p)).toBeLessThan(4 * se)
			end
			print(
				string.format(
					"[MonteCarlo] luck x%s pity: %d forced of %d, max z = %.2f, max miss streak = %d",
					tostring(luck),
					forcedN,
					N,
					maxZ,
					maxStreak
				)
			)
		end)
	end
end)
