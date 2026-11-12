--!strict
--[[
	`ctx.data.sortedMap(name)` (module-api.md §23.4): one MemoryStore sorted map per (module, name),
	store name `SW/<Module>/<name>`, behind the framework's request units and memory shares (§23.5).

	  SortedMapStore.new(opts) -> { forModule(moduleName, assertUsable?) -> (name) -> SortedMapStore }
	    opts = { backend = (storeName) -> backend, budget = StoreBudget?, wait = (s) -> ()?,
	             now = () -> number?, log }
	  SortedMapStore.classify(err) -> "throttled" | "memory_full" | "failed"

	backend (platform.stores.sortedMap(storeName); raises a Roblox error code string on failure):
	  get(key) -> (value?, sortKey?)            set(key, value, expirySeconds, sortKey?)
	  update(key, fn(old, oldSortKey) -> (new, newSortKey)?, expirySeconds) -> new?
	  remove(key)                               range(direction, count, lower?, upper?) -> { { key, value, sortKey } }

	Caller errors (raised): key over 128 characters, sort key not a number or a string of at most
	128 characters, expiry outside 1..3 888 000, `count` outside 1..200, a value over 32 KB or not
	JSON-safe (also from an `update` fn), an error inside an `update` fn. Platform failures never
	raise: (false, "budget" | "memory_budget" | "throttled" | "memory_full" | "failed").

	Per call:
	  - request units are charged to this server's per-minute cap first (a range: one unit up
	    front, then one per row returned); over the cap -> (false, "budget"), Roblox isn't called;
	  - a throttled or failed call is retried twice (after RETRY_WAITS = 1, 2 s; each try charged
	    again), then (false, "throttled" | "failed") and one warning per map per minute; a full
	    memory quota is not retried: (false, "memory_full");
	  - memory: `set` charges the item's full size (key + value + sort key + 32 bytes), `update`
	    the growth over the old value its fn saw (each re-run gives back the previous try's
	    charge), `remove` gives back what this server charged for the key. Over the module's share
	    -> (false, "memory_budget"), Roblox isn't called (an `update` cancels its write). A write
	    that fails gives its charge back.
]]

local SortedMapStore = {}

SortedMapStore.MAX_KEY = 128
SortedMapStore.MAX_VALUE_BYTES = 32 * 1024
SortedMapStore.MAX_EXPIRY = 3888000
SortedMapStore.MAX_COUNT = 200
SortedMapStore.ITEM_OVERHEAD = 32
SortedMapStore.RETRY_WAITS = table.freeze({ 1, 2 })
SortedMapStore.WARN_SECONDS = 60
-- request units per call (a range: RANGE_UNITS up front plus one per row)
SortedMapStore.UNITS = table.freeze({ get = 1, set = 1, update = 2, remove = 1, range = 1 })

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

-- nil when fine, else the caller error text
local function sortKeyProblem(sortKey: any): string?
	if sortKey == nil then
		return nil
	end
	local t = type(sortKey)
	if t == "number" then
		if sortKey ~= sortKey or sortKey == math.huge or sortKey == -math.huge then
			return "sortKey must be a finite number"
		end
		return nil
	elseif t ~= "string" or #sortKey > SortedMapStore.MAX_KEY then
		return `sortKey must be a number or a string of at most {SortedMapStore.MAX_KEY} characters`
	end
	return nil
end

local function valueProblem(value: any): string?
	local ok, size = pcall(SortedMapStore.estimateSize, value)
	if not ok then
		return tostring(size)
	end
	if size > SortedMapStore.MAX_VALUE_BYTES then
		return `value is larger than {SortedMapStore.MAX_VALUE_BYTES} bytes`
	end
	return nil
end

function SortedMapStore.new(opts: any): any
	local backendFor: (string) -> any = opts.backend
	local budget = opts.budget
	local log: (string) -> () = opts.log or function(_m: string) end
	local wait: (number) -> () = opts.wait or function(_s: number) end
	local now: () -> number = opts.now or (if budget ~= nil and budget.now then budget.now else os.time)
	local lastWarn: { [string]: number } = {}
	local chargesByStore: { [string]: { [string]: { any }? } } = {}
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
			-- what this server charged per key: { { bytes, expiresAt } }, kept per map (not per
			-- ctx.data.sortedMap call), so a remove through any handle gives back the charge
			local charges: { [string]: { any }? } = chargesByStore[storeName] or {}
			chargesByStore[storeName] = charges

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
				local problem = sortKeyProblem(sortKey)
				if problem then
					error(`{moduleName}: sortedMap.{what}: {problem}`, 3)
				end
			end

			local function warnOnce(what: string, reason: string, err: any)
				local t = now()
				local last = lastWarn[storeName]
				if last == nil or t - last >= SortedMapStore.WARN_SECONDS then
					lastWarn[storeName] = t
					log(`[StudWork] {storeName}: {what} gave up ({reason}): {tostring(err)}`)
				end
			end

			-- one call: units, then the backend in pcall, retried on a throttle or failure
			local function run(what: string, units: number, fn: () -> any): (boolean, any)
				local reason, lastErr = "failed", nil
				for attempt = 1, #SortedMapStore.RETRY_WAITS + 1 do
					if budget ~= nil and not budget.chargeUnits(moduleName, units) then
						return false, "budget"
					end
					local ok, result = pcall(fn)
					if ok then
						return true, result
					end
					reason, lastErr = SortedMapStore.classify(result), result
					if reason == "memory_full" then
						warnOnce(what, reason, result)
						return false, reason
					end
					local pause = SortedMapStore.RETRY_WAITS[attempt]
					if pause ~= nil then
						wait(pause)
					end
				end
				warnOnce(what, reason, lastErr)
				return false, reason
			end

			local function liveCharges(key: string): { any }
				local list = charges[key]
				if list == nil then
					return {}
				end
				local t = now()
				local out = {}
				for _, c in list do
					if c.expiresAt > t then
						table.insert(out, c)
					end
				end
				charges[key] = if #out > 0 then out else nil
				return out
			end
			local function track(key: string, bytes: number, expiresAt: number)
				local list = liveCharges(key)
				table.insert(list, { bytes = bytes, expiresAt = expiresAt })
				charges[key] = list
			end
			local function giveBack(key: string, upTo: number?)
				if budget == nil then
					charges[key] = nil
					return
				end
				local left = upTo or math.huge
				local list = liveCharges(key)
				while #list > 0 and left > 0 do
					local c = list[#list]
					local bytes = math.min(c.bytes, left)
					budget.releaseMemory(moduleName, bytes, c.expiresAt)
					left -= bytes
					c.bytes -= bytes
					if c.bytes <= 0 then
						table.remove(list)
					end
				end
				charges[key] = if #list > 0 then list else nil
			end

			local api = {}
			function api.get(key: string): (boolean, any, (number | string)?)
				checkKey("get", key)
				local ok, result = run("get", SortedMapStore.UNITS.get, function()
					return table.pack(store().get(key))
				end)
				if not ok then
					return false, result, nil
				end
				return true, result[1], result[2]
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
				local problem = valueProblem(value)
				if problem then
					error(`{moduleName}: sortedMap.set: {problem}`, 2)
				end
				local size = SortedMapStore.itemSize(key, value, sortKey)
				local expiresAt = now() + expirySeconds
				if budget ~= nil and not budget.chargeMemory(moduleName, size, expiresAt) then
					return false, "memory_budget"
				end
				local ok, result = run("set", SortedMapStore.UNITS.set, function()
					store().set(key, value, expirySeconds, sortKey)
					return nil
				end)
				if ok then
					track(key, size, expiresAt)
					return true, nil
				end
				if budget ~= nil then
					budget.releaseMemory(moduleName, size, expiresAt)
				end
				return false, result
			end

			function api.update(
				key: string,
				fn: (old: any, oldSortKey: (number | string)?) -> (any, (number | string)?),
				expirySeconds: number
			): (boolean, any)
				checkKey("update", key)
				checkExpiry("update", expirySeconds)
				assert(type(fn) == "function", `{moduleName}: sortedMap.update: fn must be a function`)
				local expiresAt = now() + expirySeconds
				local charged = 0
				local shrink = 0
				local refused = false
				local callerError: string? = nil
				local function release()
					if charged > 0 and budget ~= nil then
						budget.releaseMemory(moduleName, charged, expiresAt)
					end
					charged = 0
				end
				local function wrapped(old: any, oldSortKey: any): (any, any)
					release() -- a re-run gives back the previous try's charge
					refused, shrink = false, 0
					local okFn, new, newSortKey = pcall(fn, old, oldSortKey)
					if not okFn then
						callerError = `fn raised: {tostring(new)}`
						return nil, nil
					end
					if new == nil then
						return nil, nil -- cancelled
					end
					local problem = sortKeyProblem(newSortKey) or valueProblem(new)
					if problem then
						callerError = problem
						return nil, nil
					end
					local newSize = SortedMapStore.itemSize(key, new, newSortKey)
					local oldSize = if old ~= nil then SortedMapStore.itemSize(key, old, oldSortKey) else 0
					local growth = newSize - oldSize
					if growth > 0 and budget ~= nil then
						if not budget.chargeMemory(moduleName, growth, expiresAt) then
							refused = true
							return nil, nil
						end
						charged = growth
					elseif growth < 0 then
						shrink = -growth
					end
					return new, newSortKey
				end
				local ok, result = run("update", SortedMapStore.UNITS.update, function()
					return store().update(key, wrapped, expirySeconds)
				end)
				if callerError ~= nil then
					release()
					error(`{moduleName}: sortedMap.update: {callerError}`, 2)
				end
				if refused then
					return false, "memory_budget"
				end
				if not ok then
					release()
					return false, result
				end
				if charged > 0 then
					track(key, charged, expiresAt)
				elseif shrink > 0 then
					giveBack(key, shrink)
				end
				return true, result
			end

			function api.remove(key: string): (boolean, string?)
				checkKey("remove", key)
				local ok, result = run("remove", SortedMapStore.UNITS.remove, function()
					store().remove(key)
					return nil
				end)
				if ok then
					giveBack(key)
					return true, nil
				end
				return false, result
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
				local okCall, rows = run("range", SortedMapStore.UNITS.range, function()
					return store().range(direction, count, lower, upper)
				end)
				if okCall and budget ~= nil then
					budget.recordUnits(moduleName, #rows) -- a range costs one unit per row returned plus one
				end
				return okCall, rows
			end
			return table.freeze(api)
		end
	end

	return self
end

return SortedMapStore
