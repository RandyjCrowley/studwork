--!strict
--[[
	Pure roll math for the collection kit's Rarity (zero Roblox dependencies; RNG injected as
	`nextNumber`, a function returning a uniform number in [0, 1)). Tested under Lune.

	Tiers: the module itself uses the "standard7" preset (Common < ... < Secret);
	RollMath.withTiers(tiers) returns the same functions bound to another ordered tier list
	(config.Rarity.tiers, shared/Tiers.luau). Tier comparisons use the list order.
	Luck: sanitizeLuck(luck) -> non-finite or <= 0 becomes 1, values above MAX_LUCK clamp to it.
	      Luck multiplies the weight of every entry whose tier >= luckMinTier (default "Rare" in
	      standard7; Tiers.defaultLuckMinTier for a custom list).
	Weights: entries with unknown items (tierOf -> nil) or non-positive/non-finite weights are
	      dropped, so getOdds and roll always agree.
	Pity (exact rule): `count` = consecutive rolls on this table whose result tier was below
	      minTier. When count >= threshold - 1, the roll is restricted to entries >= minTier, so
	      at most threshold - 1 misses happen in a row and the threshold-th roll is guaranteed.
	      Any result >= minTier resets count to 0; anything else adds 1. If the table has no entry
	      >= minTier the restriction cannot apply (the roll is unrestricted and pity = false).
	Mutation: with probability `chance` (clamped to 0..1), pick a mutation weighted by
	      Mutation.weight (default 1; non-positive/non-finite weights are never picked).
]]

local Tiers = require(
	game:GetService("ReplicatedStorage")
		:WaitForChild("Modules")
		:WaitForChild("Rarity")
		:WaitForChild("shared")
		:WaitForChild("Tiers")
)
local Util = require(script.Parent.Util)

type RarityTier = string
type Mutation = { id: string, name: string?, weight: number? }
type TableEntry = { itemId: string, weight: number }

export type WeightedEntry = { itemId: string, weight: number, tier: RarityTier }
export type WeightedList = { entries: { WeightedEntry }, total: number }
export type PityRule = { threshold: number, minTier: RarityTier }
export type StepResult = { entry: WeightedEntry, forced: boolean, mutation: string?, pityCount: number }

local function build(tierList: { any }): any
	local RollMath: any = {}
	local rank = Tiers.rankMap(tierList)
	local DEFAULT_LUCK_MIN_TIER: RarityTier = Tiers.defaultLuckMinTier(tierList)

	RollMath.MAX_LUCK = 100 -- engineering safety rail: luck above this is clamped
	RollMath.DEFAULT_LUCK_MIN_TIER = DEFAULT_LUCK_MIN_TIER
	RollMath.tiers = tierList

	local function isTier(value: any): boolean
		return type(value) == "string" and rank[value] ~= nil
	end
	RollMath.isTier = isTier

	-- true when `t` is at least `minTier` (an unknown tier ranks 0, below every real tier)
	local function atLeast(t: RarityTier, minTier: RarityTier): boolean
		return (rank[t] or 0) >= (rank[minTier] or 0)
	end
	RollMath.atLeast = atLeast

	function RollMath.sanitizeLuck(luck: any): number
		if not Util.isPositiveNumber(luck) then
			return 1
		end
		return math.min(luck :: number, RollMath.MAX_LUCK)
	end

	function RollMath.buildWeights(
		entries: { TableEntry },
		tierOf: (itemId: string) -> RarityTier?,
		luck: any,
		luckMinTier: RarityTier?
	): WeightedList
		local l = RollMath.sanitizeLuck(luck)
		local minTier: RarityTier = luckMinTier or DEFAULT_LUCK_MIN_TIER
		local list: { WeightedEntry } = {}
		local total = 0
		for _, entry in entries do
			local maybeTier: RarityTier? = tierOf(entry.itemId)
			if maybeTier ~= nil and Util.isPositiveNumber(entry.weight) then
				local tier: RarityTier = maybeTier
				local w = entry.weight
				if atLeast(tier, minTier) then
					w = w * l
				end
				local weighted: WeightedEntry = { itemId = entry.itemId, weight = w, tier = tier }
				table.insert(list, weighted)
				total += w
			end
		end
		return { entries = list, total = total }
	end

	-- Entries with tier >= minTier, or nil when there are none.
	function RollMath.restrictTo(list: WeightedList, minTier: RarityTier): WeightedList?
		local out: { WeightedEntry } = {}
		local total = 0
		for _, entry in list.entries do
			if atLeast(entry.tier, minTier) then
				table.insert(out, entry)
				total += entry.weight
			end
		end
		if #out == 0 or total <= 0 then
			return nil
		end
		return { entries = out, total = total }
	end

	-- u in [0, 1). Returns nil only for an empty list.
	function RollMath.pick(list: WeightedList, u: number): WeightedEntry?
		local n = #list.entries
		if n == 0 or list.total <= 0 then
			return nil
		end
		local target = u * list.total
		local acc = 0
		for _, entry in list.entries do
			acc += entry.weight
			if target < acc then
				return entry
			end
		end
		return list.entries[n] -- float rounding guard
	end

	-- Exact per-item probabilities (duplicate itemIds are summed). Sums to 1 (empty for no entries).
	function RollMath.odds(list: WeightedList): { [string]: number }
		local odds: { [string]: number } = {}
		if list.total <= 0 then
			return odds
		end
		for _, entry in list.entries do
			odds[entry.itemId] = (odds[entry.itemId] or 0) + entry.weight / list.total
		end
		return odds
	end

	function RollMath.validPity(pity: any): boolean
		return type(pity) == "table"
			and Util.isInteger(pity.threshold)
			and pity.threshold >= 1
			and isTier(pity.minTier)
	end

	function RollMath.pityForces(count: number, threshold: number): boolean
		return count >= threshold - 1
	end

	function RollMath.pityAfter(count: number, resultTier: RarityTier, minTier: RarityTier): number
		if atLeast(resultTier, minTier) then
			return 0
		end
		return count + 1
	end

	function RollMath.pickMutation(mutations: { Mutation }, u: number): string?
		local total = 0
		for _, m in mutations do
			local w = if m.weight == nil then 1 else m.weight
			if Util.isPositiveNumber(w) then
				total += w
			end
		end
		if total <= 0 then
			return nil
		end
		local target = u * total
		local acc = 0
		local last: string? = nil
		for _, m in mutations do
			local w = if m.weight == nil then 1 else m.weight
			if Util.isPositiveNumber(w) then
				acc += w
				last = m.id
				if target < acc then
					return m.id
				end
			end
		end
		return last
	end

	function RollMath.rollMutation(chance: any, mutations: { Mutation }?, nextNumber: () -> number): string?
		if mutations == nil or #mutations == 0 or not Util.isPositiveNumber(chance) then
			return nil
		end
		local c = math.min(chance :: number, 1)
		if nextNumber() >= c then
			return nil
		end
		return RollMath.pickMutation(mutations, nextNumber())
	end

	-- The single roll step used by Rarity.rollInto (and the Monte Carlo spec): pity restriction,
	-- weighted pick, mutation, next pity count. RNG draw order: pick, then rollMutation's draws.
	-- `pity` must already be validated (validPity) or nil. Returns nil for an empty list.
	function RollMath.step(
		list: WeightedList,
		pity: PityRule?,
		pityCount: number,
		mutationChance: any,
		mutations: { Mutation }?,
		nextNumber: () -> number
	): StepResult?
		local forced = false
		local useList = list
		if pity and RollMath.pityForces(pityCount, pity.threshold) then
			local restricted = RollMath.restrictTo(list, pity.minTier)
			if restricted then
				useList = restricted
				forced = true
			end
		end
		local entry = RollMath.pick(useList, nextNumber())
		if entry == nil then
			return nil
		end
		local mutation = RollMath.rollMutation(mutationChance, mutations, nextNumber)
		local nextCount = if pity then RollMath.pityAfter(pityCount, entry.tier, pity.minTier) else 0
		return { entry = entry, forced = forced, mutation = mutation, pityCount = nextCount }
	end

	-- Per-mutation probability on any roll, matching rollMutation/pickMutation exactly
	-- (default weight 1, non-positive/non-finite weights never picked, chance clamped to 0..1).
	-- Returns (effective chance of any mutation, list in config order).
	function RollMath.mutationOdds(
		chance: any,
		mutations: { Mutation }?
	): (number, { { id: string, name: string, probability: number } })
		local out: { { id: string, name: string, probability: number } } = {}
		if mutations == nil or #mutations == 0 or not Util.isPositiveNumber(chance) then
			return 0, out
		end
		local c = math.min(chance :: number, 1)
		local total = 0
		for _, m in mutations do
			local w = if m.weight == nil then 1 else m.weight
			if Util.isPositiveNumber(w) then
				total += w
			end
		end
		if total <= 0 then
			return 0, out
		end
		-- duplicate ids are summed (pickMutation returns the id, so they are indistinguishable)
		local index: { [string]: number } = {}
		for _, m in mutations do
			local w = if m.weight == nil then 1 else m.weight
			if Util.isPositiveNumber(w) then
				local p = c * (w :: number) / total
				local i = index[m.id]
				if i then
					out[i].probability += p
				else
					table.insert(out, { id = m.id, name = m.name or m.id, probability = p })
					index[m.id] = #out
				end
			end
		end
		return c, out
	end

	-- Full disclosure (any shape) of a table with the given weights. `list` must be
	-- built with the same luck (buildWeights(..., luck, ...)) that is reported: `luck` (default 1,
	-- sanitised) and `luckDisclosed` (default false) are copied into the detail as-is, so the
	-- probabilities are exactly the ones a roll with that list uses.
	function RollMath.oddsDetail(
		tableId: string,
		paid: boolean,
		list: WeightedList,
		pity: any,
		mutationChance: any,
		mutations: { Mutation }?,
		luck: number?,
		luckDisclosed: boolean?
	): any
		local items = RollMath.odds(list)
		local chance, mutOdds = RollMath.mutationOdds(mutationChance, mutations)
		local itemIds: { string } = {}
		for id in items do
			table.insert(itemIds, id)
		end
		table.sort(itemIds)
		local outcomes: { any } = {}
		for _, id in itemIds do
			local p = items[id]
			if chance < 1 then
				table.insert(outcomes, { itemId = id, probability = p * (1 - chance) })
			end
			for _, m in mutOdds do
				table.insert(outcomes, { itemId = id, mutation = m.id, probability = p * m.probability })
			end
		end
		local pityDetail: any? = nil
		if RollMath.validPity(pity) then
			local restricted = RollMath.restrictTo(list, pity.minTier)
			if restricted then
				pityDetail =
					{ threshold = pity.threshold, minTier = pity.minTier, items = RollMath.odds(restricted) }
			end
		end
		local mutationsOut: { any } = {}
		for _, m in mutOdds do
			table.insert(mutationsOut, { id = m.id, name = m.name, probability = m.probability })
		end
		return {
			tableId = tableId,
			paid = paid,
			items = items,
			mutationChance = chance,
			mutations = mutationsOut,
			outcomes = outcomes,
			pity = pityDetail,
			luck = RollMath.sanitizeLuck(luck),
			luckDisclosed = luckDisclosed == true,
		}
	end

	-- The same functions bound to another ordered tier list (shared/Tiers.luau).
	function RollMath.withTiers(list: { any }): any
		return build(list)
	end

	return table.freeze(RollMath)
end

return build(Tiers.PRESETS.standard7)
