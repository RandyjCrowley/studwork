--!strict
--[[
	Pure roll math for Core.Rarity (zero Roblox dependencies; RNG injected as `nextNumber`, a
	function returning a uniform number in [0, 1)). Tested under Lune.

	Luck: sanitizeLuck(luck) -> non-finite or <= 0 becomes 1, values above MAX_LUCK clamp to it.
	      Luck multiplies the weight of every entry whose tier >= luckMinTier (default "Rare").
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

local Core = game:GetService("ReplicatedStorage"):WaitForChild("Core")
local RarityTiers = require(Core:WaitForChild("RarityTiers"))
local Types = require(Core:WaitForChild("Types"))
local Validate = require(Core:WaitForChild("Validate"))

type RarityTier = Types.RarityTier

export type WeightedEntry = { itemId: string, weight: number, tier: RarityTier }
export type WeightedList = { entries: { WeightedEntry }, total: number }

local RollMath = {}

RollMath.MAX_LUCK = 100 -- engineering safety rail: luck above this is clamped
local DEFAULT_LUCK_MIN_TIER: RarityTier = "Rare"
RollMath.DEFAULT_LUCK_MIN_TIER = DEFAULT_LUCK_MIN_TIER

function RollMath.sanitizeLuck(luck: any): number
	if not Validate.isPositiveNumber(luck) then
		return 1
	end
	return math.min(luck :: number, RollMath.MAX_LUCK)
end

function RollMath.buildWeights(
	entries: { Types.RarityTableEntry },
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
		if maybeTier ~= nil and Validate.isPositiveNumber(entry.weight) then
			local tier: RarityTier = maybeTier
			local w = entry.weight
			if RarityTiers.atLeast(tier, minTier) then
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
		if RarityTiers.atLeast(entry.tier, minTier) then
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
		and Validate.isInteger(pity.threshold)
		and pity.threshold >= 1
		and RarityTiers.isTier(pity.minTier)
end

function RollMath.pityForces(count: number, threshold: number): boolean
	return count >= threshold - 1
end

function RollMath.pityAfter(count: number, resultTier: RarityTier, minTier: RarityTier): number
	if RarityTiers.atLeast(resultTier, minTier) then
		return 0
	end
	return count + 1
end

function RollMath.pickMutation(mutations: { Types.Mutation }, u: number): string?
	local total = 0
	for _, m in mutations do
		local w = if m.weight == nil then 1 else m.weight
		if Validate.isPositiveNumber(w) then
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
		if Validate.isPositiveNumber(w) then
			acc += w
			last = m.id
			if target < acc then
				return m.id
			end
		end
	end
	return last
end

function RollMath.rollMutation(chance: any, mutations: { Types.Mutation }?, nextNumber: () -> number): string?
	if mutations == nil or #mutations == 0 or not Validate.isPositiveNumber(chance) then
		return nil
	end
	local c = math.min(chance :: number, 1)
	if nextNumber() >= c then
		return nil
	end
	return RollMath.pickMutation(mutations, nextNumber())
end

return RollMath
