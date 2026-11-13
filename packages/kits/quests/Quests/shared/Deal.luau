--!strict
--[[
	Quests: the deterministic deal (pure, no yielding; docs/framework/kits/quests.md, "Periods, the
	deal and rerolls"). Every server, the harness and the sim deal the same set from the same inputs.

	  Deal.fnv1a32(s) -> number                 FNV-1a over the bytes (offset 2166136261, prime
	                                            16777619 as (h << 24) + h * 403, mod 2^32)
	  Deal.xorshift32(x) -> number              x ^= x << 13; x ^= x >> 17; x ^= x << 5 (32-bit)
	  Deal.seed(userId, kind, periodId, poolVersion, slot, rerollIndex) -> number
	      fnv1a32(userId .. "|" .. kind .. "|" .. periodId .. "|" .. poolVersion .. "|" .. slot .. "|" .. rerollIndex)
	  Deal.pick(candidates, weights, seed) -> string?
	      candidates: ids (sorted here by id); weights: { [id] = number > 0 }. x = seed (or 0x9E3779B9
	      if 0), x = xorshift32(x), u = x / 2^32 * total, the first id whose running sum exceeds u
	  Deal.deal(opts) -> { string }
	      opts = { userId, kind, periodId, poolVersion, pool = { id }, weights, count }: slot s =
	      1..min(count, #pool) drawn from the pool minus the ids already dealt, rerollIndex 0
]]

local TWO32 = 4294967296
local OFFSET = 2166136261
local ZERO_SEED = 0x9E3779B9

local Deal = {}

function Deal.fnv1a32(s: string): number
	local h = OFFSET
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		-- h * 16777619 mod 2^32, exact in doubles: 16777619 = 2^24 + 403
		h = (bit32.lshift(h, 24) + h * 403) % TWO32
	end
	return h
end

function Deal.xorshift32(x: number): number
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	return x
end

local function int(n: number): string
	-- integers print without a fraction ("19675", "-3"); anything else as Luau prints it
	if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	return tostring(n)
end

function Deal.seed(
	userId: number,
	kind: string,
	periodId: number,
	poolVersion: number,
	slot: number,
	rerollIndex: number
): number
	return Deal.fnv1a32(
		int(userId)
			.. "|"
			.. kind
			.. "|"
			.. int(periodId)
			.. "|"
			.. int(poolVersion)
			.. "|"
			.. int(slot)
			.. "|"
			.. int(rerollIndex)
	)
end

function Deal.pick(candidates: { string }, weights: { [string]: number }, seed: number): string?
	if #candidates == 0 then
		return nil
	end
	local list = table.clone(candidates)
	table.sort(list)
	local total = 0
	for _, id in list do
		total += weights[id] or 1
	end
	local x = if seed == 0 then ZERO_SEED else seed
	x = Deal.xorshift32(x)
	local u = x / TWO32 * total
	local sum = 0
	for _, id in list do
		sum += weights[id] or 1
		if sum > u then
			return id
		end
	end
	return list[#list]
end

export type DealOpts = {
	userId: number,
	kind: string,
	periodId: number,
	poolVersion: number,
	pool: { string },
	weights: { [string]: number },
	count: number,
}

function Deal.deal(opts: DealOpts): { string }
	local remaining = table.clone(opts.pool)
	table.sort(remaining)
	local out: { string } = {}
	for s = 1, math.min(opts.count, #remaining) do
		local seed = Deal.seed(opts.userId, opts.kind, opts.periodId, opts.poolVersion, s, 0)
		local id = Deal.pick(remaining, opts.weights, seed)
		if id == nil then
			break
		end
		table.insert(out, id)
		table.remove(remaining, table.find(remaining, id) :: number)
	end
	return out
end

return table.freeze(Deal)
