--!strict
--[[
	`ctx.data.sortedMap(name)` (module-api.md §23.4): one MemoryStore sorted map per (module, name),
	store name `SW/<Module>/<name>`, behind the framework's request units and memory shares.

	  SortedMapStore.new(opts) -> { forModule(moduleName, assertUsable?) -> (name) -> SortedMapStore }
	    opts = { backend = (storeName) -> backend, budget = StoreBudget, log }
	  SortedMapStore.classify(err) -> "throttled" | "memory_full" | "failed"

	backend (platform.stores.sortedMap(storeName); raises a Roblox error code string on failure):
	  get(key) -> (value?, sortKey?)            set(key, value, expirySeconds, sortKey?)
	  update(key, fn(old, oldSortKey) -> (new, newSortKey)?, expirySeconds) -> new?
	  remove(key)                               range(direction, count, lower?, upper?) -> { { key, value, sortKey } }

	Caller errors (raised): key over 128 characters, sort key not a number or a string of at most
	128 characters, expiry outside 1..3 888 000, `count` outside 1..200, a value over 32 KB. Platform
	failures never raise: (false, "budget" | "memory_budget" | "throttled" | "memory_full" | "failed").

	STUB (foundation): argument checks, error classification, budget hooks and the pcall wrapper
	are real; retries with backoff and the per-structure / per-partition accounting are the stores
	builder's (B1).
]]

local SortedMapStore = {}

SortedMapStore.MAX_KEY = 128
SortedMapStore.MAX_VALUE_BYTES = 32 * 1024
SortedMapStore.MAX_EXPIRY = 3888000
SortedMapStore.MAX_COUNT = 200
SortedMapStore.ITEM_OVERHEAD = 32

local THROTTLED: { [string]: boolean } = {
	RequestThrottled = true,
	PartitionRequestsOverLimit = true,
	DataStructureRequestsOverLimit = true,
	TotalRequestsOverLimit = true,
}
local MEMORY_FULL: { [string]: boolean } = {
	TotalMemoryOverLimit = true,
	DataStructureMemoryOverLimit = true,
	DataStructureItemsOverLimit = true,
}

local function codeOf(err: any): string
	local text = tostring(err)
	for code in THROTTLED do
		if string.find(text, code, 1, true) then
			return code
		end
	end
	for code in MEMORY_FULL do
		if string.find(text, code, 1, true) then
			return code
		end
	end
	return text
end

function SortedMapStore.classify(err: any): string
	local code = codeOf(err)
	if THROTTLED[code] then
		return "throttled"
	elseif MEMORY_FULL[code] then
		return "memory_full"
	end
	return "failed"
end

-- A cheap size estimate of a JSON-safe value (no encoder needed): enough to enforce the 32 KB limit.
function SortedMapStore.estimateSize(value: any, depth: number?): number
	local d = depth or 0
	if d > 32 then
		error("value is nested too deeply to be JSON-safe", 0)
	end
	local t = type(value)
	if t == "string" then
		return #value + 2
	elseif t == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error("value contains a non-finite number", 0)
		end
		return #tostring(value)
	elseif t == "boolean" then
		return if value then 4 else 5
	elseif t == "nil" then
		return 4
	elseif t == "table" then
		local n = 2
		for k, v in value do
			n += #tostring(k) + 4 + SortedMapStore.estimateSize(v, d + 1)
		end
		return n
	end
	error(`value of type {t} is not JSON-safe`, 0)
end

function SortedMapStore.itemSize(key: string, value: any, sortKey: (number | string)?): number
	return #key + SortedMapStore.estimateSize(value) + #tostring(sortKey or "") + SortedMapStore.ITEM_OVERHEAD
end

function SortedMapStore.new(opts: any): any
	local backendFor: (string) -> any = opts.backend
	local budget = opts.budget
	local log: (string) -> () = opts.log or function(_m: string) end
	local self: any = {}

	function self.forModule(moduleName: string, assertUsable: (() -> ())?): (string) -> any
		return function(name: string): any
			if assertUsable then
				assertUsable()
			end
			if type(name) ~= "string" or name == "" then
				error(`{moduleName}: ctx.data.sortedMap(name): name must be a non-empty string`, 2)
			end
			local storeName = `SW/{moduleName}/{name}`
			local backend: any = nil
			local function store(): any
				if backend == nil then
					backend = backendFor(storeName)
				end
				return backend
			end
			local function checkKey(what: string, key: any)
				if type(key) ~= "string" or key == "" or #key > SortedMapStore.MAX_KEY then
					error(
						`{moduleName}: sortedMap.{what}: key must be a string of 1..{SortedMapStore.MAX_KEY} characters`,
						3
					)
				end
			end
			local function checkExpiry(what: string, expiry: any)
				if
					type(expiry) ~= "number"
					or expiry ~= expiry
					or expiry < 1
					or expiry > SortedMapStore.MAX_EXPIRY
				then
					error(
						`{moduleName}: sortedMap.{what}: expirySeconds must be a number in 1..{SortedMapStore.MAX_EXPIRY}`,
						3
					)
				end
			end
			local function checkSortKey(what: string, sortKey: any)
				if sortKey == nil then
					return
				end
				local t = type(sortKey)
				if t == "number" then
					if sortKey ~= sortKey then
						error(`{moduleName}: sortedMap.{what}: sortKey is NaN`, 3)
					end
				elseif t ~= "string" or #sortKey > SortedMapStore.MAX_KEY then
					error(
						`{moduleName}: sortedMap.{what}: sortKey must be a number or a string of at most {SortedMapStore.MAX_KEY} characters`,
						3
					)
				end
			end
			local function run(what: string, units: number, fn: () -> any): (boolean, any)
				if budget ~= nil and not budget.chargeUnits(moduleName, units) then
					return false, "budget"
				end
				local ok, result = pcall(fn)
				if not ok then
					local reason = SortedMapStore.classify(result)
					log(`[StudWork] {storeName}: {what} failed ({reason}): {tostring(result)}`)
					return false, reason
				end
				return true, result
			end

			local api = {}
			function api.get(key: string): (boolean, any, (number | string)?)
				checkKey("get", key)
				local ok, value, sortKey = false, nil, nil
				local okCall, result = run("get", 1, function()
					return table.pack(store().get(key))
				end)
				if not okCall then
					return false, result, nil
				end
				ok, value, sortKey = true, result[1], result[2]
				return ok, value, sortKey
			end
			function api.set(
				key: string,
				value: any,
				expirySeconds: number,
				sortKey: (number | string)?
			): (boolean, string?)
				checkKey("set", key)
				checkExpiry("set", expirySeconds)
				checkSortKey("set", sortKey)
				local okSize, valueSize = pcall(SortedMapStore.estimateSize, value)
				if not okSize then
					error(`{moduleName}: sortedMap.set: {tostring(valueSize)}`, 2)
				end
				if valueSize > SortedMapStore.MAX_VALUE_BYTES then
					error(
						`{moduleName}: sortedMap.set: value is larger than {SortedMapStore.MAX_VALUE_BYTES} bytes`,
						2
					)
				end
				local size = SortedMapStore.itemSize(key, value, sortKey)
				if budget ~= nil and not budget.chargeMemory(moduleName, size) then
					return false, "memory_budget"
				end
				local ok, result = run("set", 1, function()
					store().set(key, value, expirySeconds, sortKey)
					return nil
				end)
				return ok, if ok then nil else result
			end
			function api.update(
				key: string,
				fn: (old: any, oldSortKey: (number | string)?) -> (any, (number | string)?),
				expirySeconds: number
			): (boolean, any)
				checkKey("update", key)
				checkExpiry("update", expirySeconds)
				assert(type(fn) == "function", `{moduleName}: sortedMap.update: fn must be a function`)
				return run("update", 2, function()
					return store().update(key, fn, expirySeconds)
				end)
			end
			function api.remove(key: string): (boolean, string?)
				checkKey("remove", key)
				local ok, result = run("remove", 1, function()
					store().remove(key)
					return nil
				end)
				return ok, if ok then nil else result
			end
			function api.range(direction: string, count: number, lower: any?, upper: any?): (boolean, any)
				if direction ~= "asc" and direction ~= "desc" then
					error(`{moduleName}: sortedMap.range: direction must be "asc" or "desc"`, 2)
				end
				if
					type(count) ~= "number"
					or count % 1 ~= 0
					or count < 1
					or count > SortedMapStore.MAX_COUNT
				then
					error(
						`{moduleName}: sortedMap.range: count must be an integer in 1..{SortedMapStore.MAX_COUNT}`,
						2
					)
				end
				local okCall, rows = run("range", 1, function()
					return store().range(direction, count, lower, upper)
				end)
				if okCall and budget ~= nil then
					budget.chargeUnits(moduleName, #rows) -- a range costs one unit per row returned plus one
				end
				return okCall, rows
			end
			return table.freeze(api)
		end
	end

	return self
end

return SortedMapStore
