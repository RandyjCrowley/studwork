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

local function deepCopy(value: any): any
	if not isPlain(value) then
		return value
	end
	-- table.clone copies every leaf at C speed (hot in every ctx.tx; benchmark fix); only
	-- nested tables are then replaced by their own copies
	local out = table.clone(value)
	for k, v in value do
		if type(v) == "table" then
			out[k] = deepCopy(v)
		end
	end
	return out
end
Freeze.deepCopy = deepCopy

-- Frozen deep copy (the read-view builder, same as v1.2 Data/ReadOnlyView.freezeCopy).
function Freeze.freezeCopy(value: any): any
	if not isPlain(value) then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = if type(v) == "table" then Freeze.freezeCopy(v) else v
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

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		local w = b[k]
		if v ~= w and (type(v) ~= "table" or type(w) ~= "table" or not deepEqual(v, w)) then
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
Freeze.deepEqual = deepEqual

--[[
	Structural sharing at commit (v1.3.0, benchmark fix). `new` is a
	transaction's working copy (a fresh deep copy the transaction owns), `old` the committed value.
	Returns (value, changed): `old` itself when the two are deep-equal, else `new` with every
	deep-equal subtree replaced by the committed one, so unchanged subtrees keep their identity.
	One walk, no allocation (same cost as deepEqual). Frozen tables inside `new` (a module may
	store a frozen read view in its section) are never written to.
]]
-- returns `old` when deep-equal (so "changed" is simply result ~= old), else `new`. Both are
-- plain tables (checked by the caller); kept lean because it runs on every commit.
local function shareInto(new: any, old: any): any
	local changed = false
	local writable: boolean? = nil
	for k, v in new do
		local o = old[k]
		if v ~= o then
			if not changed or (type(v) == "table" and type(o) == "table") then
				if
					type(v) == "table"
					and type(o) == "table"
					and getmetatable(v) == nil
					and getmetatable(o) == nil
				then
					if shareInto(v, o) ~= o then
						changed = true
					else
						if writable == nil then
							writable = not table.isfrozen(new)
						end
						if writable then
							new[k] = o -- assigning an existing key while iterating is allowed
						end
					end
				else
					changed = true
				end
			end
		end
	end
	if not changed then
		for k in old do
			if new[k] == nil then
				return new
			end
		end
		return old
	end
	return new
end

local function share(new: any, old: any): (any, boolean)
	if new == old then
		return old, false
	end
	if not isPlain(new) or not isPlain(old) then
		return new, true
	end
	local v = shareInto(new, old)
	return v, v ~= old
end
Freeze.share = share

--[[
	Frozen deep copy that reuses the previous one (v1.3.0, benchmark fix).
	`prevSource` is the committed table the frozen `prevView` was built from. Any subtree of `value`
	that is still the very same table as in prevSource is returned as prevView's frozen subtree
	without a walk, so a view rebuilt after a commit only copies the tables the commit replaced
	(Freeze.share keeps every unchanged subtree's identity) and charm-sync's diff skips the reused
	ones by reference.
	Only valid while committed tables are never mutated in place: every framework write to a
	committed section replaces the tables on the path it changes (Data.beforeSave, Store.saveNow).
]]
local function freezeShared(value: any, prevSource: any, prevView: any): any
	if not isPlain(value) then
		return value
	end
	if value == prevSource and prevView ~= nil then
		return prevView
	end
	local ps = if type(prevSource) == "table" and type(prevView) == "table" then prevSource else nil
	local out = table.clone(value)
	for k, v in value do
		if type(v) == "table" then
			out[k] = if ps then freezeShared(v, ps[k], prevView[k]) else freezeShared(v, nil, nil)
		end
	end
	return table.freeze(out)
end
Freeze.freezeShared = freezeShared

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
