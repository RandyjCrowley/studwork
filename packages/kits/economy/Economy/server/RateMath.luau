--!strict
--[[
	Pure economy math (zero Roblox dependencies). Used by Core.Economy; tested by RateMath.spec.

	- combine(factors, mode): stacks multiplier factors. "multiply" (default) = product;
	  "add" = 1 + sum(f - 1). An empty list is 1.
	- activeBoosts(out, entries, now): appends every non-expired entry's mult to `out` and returns
	  the earliest future expiresAt among them (nil = none expire). expiresAt <= now = expired.
	- pruneExpired(entries, now): removes expired entries in place, returns how many were removed.
	- isKnownCurrency(id, primary, starting, balances): primary, any key of startingCurrency, or a
	  currency the player already holds.
	- applyGrant / applySpend: validated mutation of a currency table (call inside Data.update).
]]

local RateMath = {}

export type Entry = { mult: number, expiresAt: number? }
export type Stacking = "multiply" | "add"

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
RateMath.isFinite = isFinite

function RateMath.isPositiveAmount(v: any): boolean
	return isFinite(v) and v > 0
end

function RateMath.combine(factors: { number }, mode: Stacking?): number
	if mode == "add" then
		local total = 1
		for _, f in factors do
			total += f - 1
		end
		return math.max(total, 0)
	end
	local total = 1
	for _, f in factors do
		total *= f
	end
	return total
end

function RateMath.isActive(entry: Entry, now: number): boolean
	return entry.expiresAt == nil or (entry.expiresAt :: number) > now
end

function RateMath.activeBoosts(out: { number }, entries: { [string]: Entry }?, now: number): number?
	local nextExpiry: number? = nil
	if entries == nil then
		return nil
	end
	for _, entry in entries do
		if isFinite(entry.mult) and entry.mult > 0 and RateMath.isActive(entry, now) then
			table.insert(out, entry.mult)
			local e = entry.expiresAt
			if e ~= nil and (nextExpiry == nil or e < (nextExpiry :: number)) then
				nextExpiry = e
			end
		end
	end
	return nextExpiry
end

function RateMath.pruneExpired(entries: { [string]: Entry }, now: number): number
	local removed = 0
	for id, entry in entries do
		if not RateMath.isActive(entry, now) then
			entries[id] = nil
			removed += 1
		end
	end
	return removed
end

-- incomeMultiplier upgrade factor: 1 + level * perLevel.
function RateMath.upgradeFactor(level: number, perLevel: number): number
	return 1 + level * perLevel
end

-- Sum of item income. `uids` iterates either displayed (slot -> uid) or inventory (uid -> inst).
function RateMath.sumItems(
	displayed: { [string]: string },
	inventory: { [string]: any },
	source: string,
	incomeOf: (any) -> number
): number
	local total = 0
	if source == "owned" then
		for _, instance in inventory do
			local v = incomeOf(instance)
			if isFinite(v) and v > 0 then
				total += v
			end
		end
	else
		for _, uid in displayed do
			local instance = inventory[uid]
			if instance ~= nil then
				local v = incomeOf(instance)
				if isFinite(v) and v > 0 then
					total += v
				end
			end
		end
	end
	return total
end

function RateMath.isKnownCurrency(
	id: any,
	primary: string,
	starting: { [string]: number }?,
	balances: { [string]: number }?
): boolean
	if type(id) ~= "string" then
		return false
	end
	if id == primary then
		return true
	end
	if starting ~= nil and starting[id] ~= nil then
		return true
	end
	return balances ~= nil and balances[id] ~= nil
end

-- Returns (ok, newBalance). Mutates `balances` only when ok.
function RateMath.applyGrant(balances: { [string]: number }, id: string, amount: number): (boolean, number)
	if not RateMath.isPositiveAmount(amount) then
		return false, balances[id] or 0
	end
	local nb = (balances[id] or 0) + amount
	if not isFinite(nb) then
		return false, balances[id] or 0
	end
	balances[id] = nb
	return true, nb
end

function RateMath.applySpend(balances: { [string]: number }, id: string, amount: number): (boolean, number)
	local current = balances[id] or 0
	if not RateMath.isPositiveAmount(amount) or current < amount then
		return false, current
	end
	local nb = current - amount
	balances[id] = nb
	return true, nb
end

-- Splits an analytics reason "kind:sku" into (transactionType, sku?).
function RateMath.splitReason(reason: string): (string, string?)
	local kind, sku = string.match(reason, "^([^:]+):(.+)$")
	if kind then
		return kind, sku
	end
	return reason, nil
end

return RateMath
