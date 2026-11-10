--!strict
--[[
	Pure load-time repair of saved data. OWNED BY AGENT A (core/a-data). No Roblox globals.

	reconcile(target, defaults)  deep-fill missing keys from defaults (defaults are deep-copied, so
	                             nested default tables are never shared); a key whose saved value
	                             has a different Lua type than its default is replaced by the
	                             default. Keys absent from defaults are kept.
	playerData(data)             type-checks the known PlayerData maps: drops non-finite numbers,
	                             non-string keys and malformed entries (currency NaN/inf, broken
	                             inventory items, bad multipliers ...). Returns the number of fixes.
	prunePurchases(map, cap)     keeps the newest `cap` receipt ids (by timestamp, ties by id).
]]

local Sanitize = {}

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
Sanitize.isFinite = isFinite

function Sanitize.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[k] = Sanitize.deepCopy(v)
	end
	return (out :: any) :: T
end

function Sanitize.reconcile(target: { [any]: any }, defaults: { [any]: any })
	for key, default in defaults do
		local current = target[key]
		if current == nil or type(current) ~= type(default) then
			target[key] = Sanitize.deepCopy(default)
		elseif type(default) == "table" and next(default) ~= nil then
			Sanitize.reconcile(current, default)
		end
	end
end

-- { [string]: finite number } maps; optional floor for integer counters and min.
local function numberMap(map: any, minValue: number?, integer: boolean?): number
	local fixes = 0
	for k, v in map do
		if type(k) ~= "string" or not isFinite(v) or (minValue ~= nil and v < minValue) then
			map[k] = nil
			fixes += 1
		elseif integer and v % 1 ~= 0 then
			map[k] = math.floor(v)
			fixes += 1
		end
	end
	return fixes
end

local function scalar(data: any, key: string, fallback: number, minValue: number?): number
	local v = data[key]
	if not isFinite(v) or (minValue ~= nil and v < minValue) then
		data[key] = fallback
		return 1
	end
	return 0
end

local function isPrimitive(v: any): boolean
	local t = type(v)
	return t == "string" or t == "boolean" or (t == "number" and isFinite(v))
end

local function validItem(uid: any, item: any): boolean
	if type(uid) ~= "string" or type(item) ~= "table" then
		return false
	end
	if item.uid ~= uid or type(item.itemId) ~= "string" or not isFinite(item.acquiredAt) then
		return false
	end
	if item.mutation ~= nil and type(item.mutation) ~= "string" then
		return false
	end
	if item.source ~= nil and type(item.source) ~= "string" then
		return false
	end
	if item.meta ~= nil then
		if type(item.meta) ~= "table" then
			return false
		end
		for k, v in item.meta do
			if type(k) ~= "string" or not isPrimitive(v) then
				return false
			end
		end
	end
	return true
end

-- Assumes reconcile already ran, so every top-level key has the right Lua type.
function Sanitize.playerData(data: { [string]: any }): number
	local fixes = 0
	fixes += numberMap(data.currency, nil, false)
	fixes += numberMap(data.upgrades, 0, true)
	fixes += numberMap(data.pity, 0, true)
	fixes += numberMap(data.stats, nil, false)
	fixes += numberMap(data.funnel, 0, false)
	fixes += numberMap(data.purchases, 0, false)
	fixes += scalar(data, "rebirths", 0, 0)
	fixes += scalar(data, "lastSeen", 0, 0)
	fixes += scalar(data, "firstJoin", 0, 0)
	if type(data.streak) == "table" then
		fixes += scalar(data.streak, "day", 0, 0)
		fixes += scalar(data.streak, "lastDay", 0, 0)
	end
	for uid, item in data.inventory do
		if not validItem(uid, item) then
			data.inventory[uid] = nil
			fixes += 1
		end
	end
	for slot, uid in data.displayed do
		if type(slot) ~= "string" or type(uid) ~= "string" then
			data.displayed[slot] = nil
			fixes += 1
		end
	end
	for id, entry in data.multipliers do
		local ok = type(id) == "string"
			and type(entry) == "table"
			and isFinite(entry.mult)
			and entry.mult > 0
			and (entry.expiresAt == nil or isFinite(entry.expiresAt))
		if not ok then
			data.multipliers[id] = nil
			fixes += 1
		end
	end
	return fixes
end

function Sanitize.prunePurchases(purchases: { [string]: number }, cap: number): number
	local ids: { string } = {}
	for id in purchases do
		table.insert(ids, id)
	end
	local excess = #ids - cap
	if excess <= 0 then
		return 0
	end
	table.sort(ids, function(a, b)
		local ta, tb = purchases[a], purchases[b]
		if ta ~= tb then
			return ta < tb
		end
		return a < b
	end)
	for i = 1, excess do
		purchases[ids[i]] = nil
	end
	return excess
end

return Sanitize
