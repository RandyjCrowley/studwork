--!strict
--[[
	The live store adapters (framework internal): the engine's DataStore / MemoryStore services
	behind the backend interfaces OrderedStore.luau and SortedMapStore.luau call (their headers
	list the methods). The only place the framework's ordered stores and sorted maps meet the engine.

	  PlatformStores.live(opts?) -> { ordered(storeName) -> backend, sortedMap(storeName) -> backend }
	      opts = { dataStoreService?, memoryStoreService?, isStudio?, log? } (defaults: the engine's)
	      ordered: DataStoreService:GetOrderedDataStore(storeName); the backend also offers
	        requestBudget(kind) -> number? (GetRequestBudgetForRequestType for that call's type).
	      sortedMap: MemoryStoreService:GetSortedMap(storeName).
	      Studio without API access: the store falls back to an in-memory one (one warning per
	      kind of store), like ctx.data.shared (module-api.md §19.1, §23.3, §23.4).
	  PlatformStores.inert()    -> the same shape; every call raises "no store backend" (Platform.inert)

	Building blocks (also what the test fakes are made of, so specs run this adapter code):
	  PlatformStores.orderedAdapter(ods, opts?) -> ordered backend over an OrderedDataStore-like
	      object (GetAsync / SetAsync / IncrementAsync / UpdateAsync / RemoveAsync / GetSortedAsync).
	      opts.requestBudget(kind) -> number? is passed through.
	  PlatformStores.orderedShim(ods, opts?) -> an OrderedDataStore-like object over a mock one that
	      has only SetAsync / UpdateAsync / IncrementAsync / RemoveAsync / GetSortedAsync(asc, n)
	      (the legacy adapter's memory store, the sim World's): adds GetAsync (opts.getAsync, else a
	      read through UpdateAsync that writes nothing), and min / max with a stable key order.
	  PlatformStores.memoryOrdered(storeName) -> an in-memory OrderedDataStore-like object (the
	      legacy adapter's memory backend through the shim; the Studio fallback).
	  PlatformStores.sortedMapAdapter(map) -> sorted-map backend over a MemoryStoreSortedMap.
	  PlatformStores.memorySortedMap(opts?) -> an in-memory sorted-map backend (Roblox ordering and
	      exclusive bounds, expiry on opts.clock) plus entries() / memoryBytes() / itemOf(key);
	      opts.beforeWrite(growthBytes) may raise to refuse a growing write. The Studio fallback,
	      and the core of the test fake (test/Fakes/SortedMap.luau).

	Ordered request types (Roblox's Enum.DataStoreRequestType) per call:
	  get -> GetAsync, set / increment / remove -> SetIncrementSortedAsync, update -> UpdateAsync,
	  top -> GetSortedAsync.
]]

local Legacy = require(script.Parent.Legacy)
local SortedMapStore = require(script.Parent.SortedMapStore)

local PlatformStores = {}

PlatformStores.REQUEST_TYPES = table.freeze({
	get = "GetAsync",
	set = "SetIncrementSortedAsync",
	increment = "SetIncrementSortedAsync",
	remove = "SetIncrementSortedAsync",
	update = "UpdateAsync",
	top = "GetSortedAsync",
})

local ORDERED_METHODS = { "get", "set", "increment", "update", "remove", "top" }
local SORTED_METHODS = { "get", "set", "update", "remove", "range" }

-- Studio without API access (unpublished place, or "Enable Studio Access to API Services" off)
local NO_API_PATTERNS = { "access to apis", "publish this place", "studio access", "api services" }

local function isNoApiAccess(err: any): boolean
	local text = string.lower(tostring(err))
	for _, pattern in NO_API_PATTERNS do
		if string.find(text, pattern, 1, true) then
			return true
		end
	end
	return false
end
PlatformStores.isNoApiAccess = isNoApiAccess

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

--------------------------------------------------------------------------------
-- Ordered stores
--------------------------------------------------------------------------------

function PlatformStores.orderedAdapter(ods: any, opts: any?): any
	local o = opts or {}
	local b: any = {}
	function b.get(key: string): number?
		local value = ods:GetAsync(key)
		return value
	end
	function b.set(key: string, value: number)
		ods:SetAsync(key, value)
	end
	function b.increment(key: string, delta: number): number
		return ods:IncrementAsync(key, delta)
	end
	-- fn(old) -> new | nil (nil cancels); returns the stored value afterwards (the old one if cancelled)
	function b.update(key: string, fn: (number?) -> number?): number?
		local seen: number? = nil
		local cancelled = false
		local result = ods:UpdateAsync(key, function(old: number?): number?
			seen = old
			local new = fn(old)
			cancelled = new == nil
			return new
		end)
		if cancelled or result == nil then
			return seen
		end
		return result
	end
	function b.remove(key: string)
		ods:RemoveAsync(key)
	end
	function b.top(count: number, order: string, minValue: number?, maxValue: number?): { any }
		local pages = ods:GetSortedAsync(order == "asc", count, minValue, maxValue)
		local rows = {}
		for _, entry in pages:GetCurrentPage() do
			table.insert(rows, { key = tostring(entry.key), value = entry.value })
		end
		return rows
	end
	b.requestBudget = o.requestBudget
	return b
end

function PlatformStores.orderedShim(ods: any, opts: any?): any
	local o = opts or {}
	local shim: any = {}
	function shim.GetAsync(_self: any, key: string): number?
		if o.getAsync then
			return o.getAsync(key)
		end
		local seen: number? = nil
		ods:UpdateAsync(key, function(old: number?): number?
			seen = old
			return nil -- a read: nothing is written
		end)
		return seen
	end
	function shim.SetAsync(_self: any, key: string, value: number)
		ods:SetAsync(key, value)
	end
	function shim.IncrementAsync(_self: any, key: string, delta: number?): number
		return ods:IncrementAsync(key, delta)
	end
	function shim.UpdateAsync(_self: any, key: string, fn: (number?) -> number?): number?
		return ods:UpdateAsync(key, fn)
	end
	function shim.RemoveAsync(_self: any, key: string)
		ods:RemoveAsync(key)
	end
	function shim.GetSortedAsync(
		_self: any,
		ascending: boolean,
		pageSize: number,
		minValue: number?,
		maxValue: number?
	): any
		local all = ods:GetSortedAsync(ascending, math.huge):GetCurrentPage()
		local rows = {}
		for _, entry in all do
			local v = entry.value
			if (minValue == nil or v >= minValue) and (maxValue == nil or v <= maxValue) then
				table.insert(rows, { key = tostring(entry.key), value = v })
			end
		end
		table.sort(rows, function(a: any, b: any): boolean
			if a.value ~= b.value then
				return if ascending then a.value < b.value else a.value > b.value
			end
			return a.key < b.key
		end)
		local page = {}
		for i = 1, math.min(pageSize, #rows) do
			page[i] = rows[i]
		end
		return {
			GetCurrentPage = function(): { any }
				return page
			end,
		}
	end
	return shim
end

function PlatformStores.memoryOrdered(storeName: string): any
	local service = Legacy.memory().dataStoreService()
	return PlatformStores.orderedShim(service:GetOrderedDataStore(storeName))
end

--------------------------------------------------------------------------------
-- Sorted maps
--------------------------------------------------------------------------------

function PlatformStores.sortedMapAdapter(map: any): any
	local b: any = {}
	function b.get(key: string): (any, (number | string)?)
		local value, sortKey = map:GetAsync(key)
		return value, sortKey
	end
	function b.set(key: string, value: any, expirySeconds: number, sortKey: (number | string)?)
		map:SetAsync(key, value, expirySeconds, sortKey)
	end
	function b.update(key: string, fn: (any, any) -> (any, any), expirySeconds: number): any
		return map:UpdateAsync(key, fn, expirySeconds)
	end
	function b.remove(key: string)
		map:RemoveAsync(key)
	end
	function b.range(direction: string, count: number, lower: any?, upper: any?): { any }
		local enumDirection = if direction == "desc"
			then Enum.SortDirection.Descending
			else Enum.SortDirection.Ascending
		local rows = {}
		for _, item in map:GetRangeAsync(enumDirection, count, lower, upper) do
			table.insert(rows, { key = item.key, value = item.value, sortKey = item.sortKey })
		end
		return rows
	end
	return b
end

-- Roblox's order: items without a sort key first, then numbers, then strings; ties by key
local function sortBefore(a: any, b: any): boolean
	if a.sortKey == nil and b.sortKey ~= nil then
		return true
	elseif a.sortKey ~= nil and b.sortKey == nil then
		return false
	end
	local ta, tb = type(a.sortKey), type(b.sortKey)
	if ta ~= tb then
		return ta == "number"
	end
	if a.sortKey ~= b.sortKey then
		return a.sortKey < b.sortKey
	end
	return a.key < b.key
end
PlatformStores.sortBefore = sortBefore

-- Exclusive bounds { key?, sortKey? }. A bound with only a sort key excludes items whose sort key
-- (of the same type) is at or past it; a bound with a key compares in full order (sort key, key).
local function within(item: any, lower: any?, upper: any?): boolean
	if lower ~= nil then
		if lower.key == nil and lower.sortKey ~= nil then
			if type(item.sortKey) == type(lower.sortKey) and item.sortKey <= lower.sortKey then
				return false
			end
		elseif lower.key ~= nil and not sortBefore({ key = lower.key, sortKey = lower.sortKey }, item) then
			return false
		end
	end
	if upper ~= nil then
		if upper.key == nil and upper.sortKey ~= nil then
			if type(item.sortKey) == type(upper.sortKey) and item.sortKey >= upper.sortKey then
				return false
			end
		elseif upper.key ~= nil and not sortBefore(item, { key = upper.key, sortKey = upper.sortKey }) then
			return false
		end
	end
	return true
end

function PlatformStores.memorySortedMap(opts: any?): any
	local o = opts or {}
	local clock: () -> number = o.clock or os.time
	local beforeWrite: ((number) -> ())? = o.beforeWrite
	local items: { [string]: any } = {}
	local m: any = {}

	local function liveItem(key: string): any
		local item = items[key]
		if item ~= nil and item.expiresAt <= clock() then
			items[key] = nil
			return nil
		end
		return item
	end

	local function live(): { any }
		local now = clock()
		local out = {}
		for key, item in items do
			if item.expiresAt <= now then
				items[key] = nil
			else
				table.insert(out, item)
			end
		end
		return out
	end

	local function size(item: any): number
		return SortedMapStore.itemSize(item.key, item.value, item.sortKey)
	end

	local function put(key: string, value: any, expirySeconds: number, sortKey: (number | string)?)
		local item =
			{ key = key, value = deepCopy(value), sortKey = sortKey, expiresAt = clock() + expirySeconds }
		local old = liveItem(key)
		if beforeWrite then
			beforeWrite(size(item) - (if old ~= nil then size(old) else 0))
		end
		items[key] = item
	end

	function m.itemOf(key: string): any
		local item = liveItem(key)
		return if item then deepCopy(item) else nil
	end

	function m.memoryBytes(): number
		local total = 0
		for _, item in live() do
			total += size(item)
		end
		return total
	end

	function m.get(key: string): (any, (number | string)?)
		local item = liveItem(key)
		if item == nil then
			return nil, nil
		end
		return deepCopy(item.value), item.sortKey
	end

	function m.set(key: string, value: any, expirySeconds: number, sortKey: (number | string)?)
		put(key, value, expirySeconds, sortKey)
	end

	function m.update(key: string, fn: (any, any) -> (any, any), expirySeconds: number): any
		local item = liveItem(key)
		local new, newSortKey =
			fn(if item then deepCopy(item.value) else nil, if item then item.sortKey else nil)
		if new == nil then
			return nil -- cancelled (Roblox semantics: nothing written)
		end
		put(key, new, expirySeconds, newSortKey)
		return deepCopy(new)
	end

	function m.remove(key: string)
		items[key] = nil
	end

	function m.range(direction: string, count: number, lower: any?, upper: any?): { any }
		local rows = {}
		for _, item in live() do
			if within(item, lower, upper) then
				table.insert(rows, item)
			end
		end
		table.sort(rows, function(a: any, b: any): boolean
			if direction == "desc" then
				return sortBefore(b, a)
			end
			return sortBefore(a, b)
		end)
		local out = {}
		for i = 1, math.min(count, #rows) do
			out[i] = { key = rows[i].key, value = deepCopy(rows[i].value), sortKey = rows[i].sortKey }
		end
		return out
	end

	function m.entries(): { any }
		local out = {}
		for _, item in live() do
			table.insert(out, {
				key = item.key,
				value = deepCopy(item.value),
				sortKey = item.sortKey,
				expiresAt = item.expiresAt,
			})
		end
		table.sort(out, function(a: any, b: any): boolean
			return a.key < b.key
		end)
		return out
	end

	return m
end

--------------------------------------------------------------------------------
-- Live
--------------------------------------------------------------------------------

-- One backend whose calls go to `real()` until a Studio no-API-access error switches it to
-- `memory()` for good (with one warning per kind of store).
local function withStudioFallback(
	methods: { string },
	real: () -> any,
	memory: () -> any,
	isStudio: () -> boolean,
	warnOnce: () -> ()
): any
	local active: any = nil
	local fallback: any = nil
	local b: any = {}
	for _, method in methods do
		b[method] = function(...: any): ...any
			if fallback ~= nil then
				return fallback[method](...)
			end
			local result = table.pack(pcall(function(...: any): ...any
				if active == nil then
					active = real()
				end
				return active[method](...)
			end, ...))
			if result[1] then
				return table.unpack(result, 2, result.n)
			end
			if isNoApiAccess(result[2]) and isStudio() then
				fallback = memory()
				warnOnce()
				return fallback[method](...)
			end
			error(result[2], 0)
		end
	end
	b.requestBudget = function(kind: string): number?
		if fallback ~= nil then
			return nil
		end
		if active == nil then
			local ok, made = pcall(real)
			if not ok then
				return nil
			end
			active = made
		end
		return if active.requestBudget then active.requestBudget(kind) else nil
	end
	return b
end

function PlatformStores.live(opts: any?): any
	local o = opts or {}
	local log: (string) -> () = o.log or function(msg: string)
		warn(msg)
	end
	local function service(name: string): any
		if name == "DataStoreService" and o.dataStoreService then
			return o.dataStoreService
		elseif name == "MemoryStoreService" and o.memoryStoreService then
			return o.memoryStoreService
		end
		return game:GetService(name)
	end
	local function studio(): boolean
		if o.isStudio ~= nil then
			return o.isStudio
		end
		return game:GetService("RunService"):IsStudio()
	end
	local warned = { ordered = false, sortedMap = false }
	local function warner(kind: string, what: string): () -> ()
		return function()
			if not warned[kind] then
				warned[kind] = true
				log(
					`[StudWork] Studio has no API access: {what} use in-memory stores for this session (nothing is kept)`
				)
			end
		end
	end

	return {
		ordered = function(storeName: string): any
			return withStudioFallback(ORDERED_METHODS, function(): any
				local ds = service("DataStoreService")
				return PlatformStores.orderedAdapter(ds:GetOrderedDataStore(storeName), {
					requestBudget = function(kind: string): number?
						local typeName = PlatformStores.REQUEST_TYPES[kind]
						if typeName == nil then
							return nil
						end
						return ds:GetRequestBudgetForRequestType((Enum.DataStoreRequestType :: any)[typeName])
					end,
				})
			end, function(): any
				return PlatformStores.orderedAdapter(PlatformStores.memoryOrdered(storeName))
			end, studio, warner("ordered", "ctx.data.ordered stores"))
		end,
		sortedMap = function(storeName: string): any
			return withStudioFallback(SORTED_METHODS, function(): any
				return PlatformStores.sortedMapAdapter(service("MemoryStoreService"):GetSortedMap(storeName))
			end, function(): any
				return PlatformStores.memorySortedMap()
			end, studio, warner("sortedMap", "ctx.data.sortedMap maps and the census"))
		end,
	}
end

function PlatformStores.inert(): any
	local function none(methods: { string }): any
		local b: any = {}
		for _, method in methods do
			b[method] = function()
				error("no store backend: this platform has no ordered stores or sorted maps", 0)
			end
		end
		return b
	end
	return {
		ordered = function(_storeName: string): any
			return none(ORDERED_METHODS)
		end,
		sortedMap = function(_storeName: string): any
			return none(SORTED_METHODS)
		end,
	}
end

return PlatformStores
