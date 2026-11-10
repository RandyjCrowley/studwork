--!strict
--[[
	Pure copy/freeze/compare helpers (no Roblox globals). Only PLAIN tables (no metatable) are
	copied or frozen: Instances, ModuleRefs' migration folders and objects with metatables are kept
	by identity.
]]

local Freeze = {}

local function isPlain(value: any): boolean
	return type(value) == "table" and getmetatable(value) == nil
end
Freeze.isPlain = isPlain

function Freeze.deepCopy(value: any): any
	if not isPlain(value) then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = Freeze.deepCopy(v)
	end
	return out
end

-- Frozen deep copy (the read-view builder, same as v1.2 Data/ReadOnlyView.freezeCopy).
function Freeze.freezeCopy(value: any): any
	if not isPlain(value) then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = Freeze.freezeCopy(v)
	end
	return table.freeze(out)
end

-- Freezes plain tables in place, recursively. Already-frozen tables are skipped.
function Freeze.deepFreeze(value: any): any
	if isPlain(value) and not table.isfrozen(value) then
		table.freeze(value)
		for _, v in value do
			Freeze.deepFreeze(v)
		end
	end
	return value
end

function Freeze.deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not Freeze.deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function isArray(t: any): boolean
	if not isPlain(t) then
		return false
	end
	local n = #t
	local count = 0
	for _ in t do
		count += 1
	end
	return count == n and n > 0
end

-- Merges `over` onto a copy of `base`: maps deep-merge, arrays and scalars replace.
function Freeze.deepMerge(base: any, over: any): any
	if over == nil then
		return Freeze.deepCopy(base)
	end
	if not isPlain(base) or not isPlain(over) or isArray(over) or isArray(base) then
		return Freeze.deepCopy(over)
	end
	local out = Freeze.deepCopy(base)
	for k, v in over do
		out[k] = Freeze.deepMerge(out[k], v)
	end
	return out
end

return Freeze
