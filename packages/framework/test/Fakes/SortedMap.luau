--!strict
--[[
	In-memory MemoryStore sorted map (StudWork.test, module-api.md §23.4 / §23.10): the backend behind
	`ctx.data.sortedMap(name)` in the harness and the sim, with Roblox's limits applied as live.

	  SortedMapFake.new(opts?) -> fake
	    opts = { name = string?, clock = () -> number (seconds; expiry runs on it, the harness clock),
	             structureLimit = number? (request units a minute for the whole map, default 100000),
	             partitionLimit = number? (units a minute on its one partition, default 30000),
	             registry = { memoryUsed() -> number, quotaBytes: number? }? (the experience memory quota) }
	  backend (raises a Roblox error code string on failure):
	    get(key) -> (value?, sortKey?)            set(key, value, expirySeconds, sortKey?)
	    update(key, fn(old, oldSortKey) -> (new, newSortKey)?, expirySeconds) -> new?   (nil cancels)
	    remove(key)                               range(direction, count, lower?, upper?) -> { { key, value, sortKey } }
	  test surface:
	    entries() -> { { key, value, sortKey, expiresAt } }   live items, in key order
	    memoryBytes() -> number                    estimated bytes of the live items
	    calls                                      { { op, key?, units } } every backend call
	    unitsThisMinute() -> number
	    failNext(n, code?)                         the next n calls raise `code` (default "RequestThrottled")

	Over the units limits a call raises PartitionRequestsOverLimit / DataStructureRequestsOverLimit;
	over the registry's quota a growing write raises TotalMemoryOverLimit. A range costs one unit per
	row returned plus one; every other call one unit (update: two).

	FOUNDATION: working. The stores builder (B1) extends the per-structure accounting across maps and
	the sim's sharing between servers.
]]

local SortedMapStore = (require :: any)(script.Parent.Parent.Parent.server.SortedMapStore)

local SortedMapFake = {}

SortedMapFake.STRUCTURE_LIMIT = 100000
SortedMapFake.PARTITION_LIMIT = 30000

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

-- numbers sort before strings; within a type by value; ties by key
local function sortBefore(a: any, b: any): boolean
	local ta, tb = type(a.sortKey), type(b.sortKey)
	if a.sortKey == nil and b.sortKey ~= nil then
		return true
	elseif a.sortKey ~= nil and b.sortKey == nil then
		return false
	end
	if ta ~= tb then
		return ta == "number"
	end
	if a.sortKey ~= b.sortKey then
		return a.sortKey < b.sortKey
	end
	return a.key < b.key
end

function SortedMapFake.new(opts: any?): any
	local o = opts or {}
	local clock: () -> number = o.clock or os.time
	local structureLimit: number = o.structureLimit or SortedMapFake.STRUCTURE_LIMIT
	local partitionLimit: number = o.partitionLimit or SortedMapFake.PARTITION_LIMIT
	local registry = o.registry
	local items: { [string]: any } = {}
	local fake: any = { name = o.name, calls = {} }
	local failures, failCode = 0, "RequestThrottled"
	local windowStart, windowUnits = 0, 0

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

	function fake.memoryBytes(): number
		local total = 0
		for _, item in live() do
			total += size(item)
		end
		return total
	end

	local function charge(op: string, key: string?, units: number)
		table.insert(fake.calls, { op = op, key = key, units = units })
		if failures > 0 then
			failures -= 1
			error(failCode, 0)
		end
		local now = clock()
		if now - windowStart >= 60 then
			windowStart, windowUnits = now, 0
		end
		windowUnits += units
		if windowUnits > structureLimit then
			error("DataStructureRequestsOverLimit", 0)
		end
		if windowUnits > partitionLimit then
			error("PartitionRequestsOverLimit", 0)
		end
	end

	function fake.failNext(n: number, code: string?)
		failures += n
		failCode = code or "RequestThrottled"
	end

	function fake.unitsThisMinute(): number
		if clock() - windowStart >= 60 then
			return 0
		end
		return windowUnits
	end

	-- a growing write must fit the experience-wide quota (every map of the registry together)
	local function checkMemory(extra: number)
		if registry ~= nil and type(registry.quotaBytes) == "number" and extra > 0 then
			if registry.memoryUsed() + extra > registry.quotaBytes then
				error("TotalMemoryOverLimit", 0)
			end
		end
	end

	local function put(key: string, value: any, expirySeconds: number, sortKey: (number | string)?)
		local item =
			{ key = key, value = deepCopy(value), sortKey = sortKey, expiresAt = clock() + expirySeconds }
		local old = items[key]
		local growth = size(item) - (if old ~= nil and old.expiresAt > clock() then size(old) else 0)
		checkMemory(growth)
		items[key] = item
	end

	function fake.get(key: string): (any, (number | string)?)
		charge("get", key, 1)
		local item = items[key]
		if item == nil or item.expiresAt <= clock() then
			items[key] = nil
			return nil, nil
		end
		return deepCopy(item.value), item.sortKey
	end

	function fake.set(key: string, value: any, expirySeconds: number, sortKey: (number | string)?)
		charge("set", key, 1)
		put(key, value, expirySeconds, sortKey)
	end

	function fake.update(
		key: string,
		fn: (old: any, oldSortKey: (number | string)?) -> (any, (number | string)?),
		expirySeconds: number
	): any
		charge("update", key, 2)
		local item = items[key]
		if item ~= nil and item.expiresAt <= clock() then
			items[key] = nil
			item = nil
		end
		local new, newSortKey =
			fn(if item then deepCopy(item.value) else nil, if item then item.sortKey else nil)
		if new == nil then
			return if item then deepCopy(item.value) else nil -- cancelled
		end
		put(key, new, expirySeconds, newSortKey)
		return deepCopy(new)
	end

	function fake.remove(key: string)
		charge("remove", key, 1)
		items[key] = nil
	end

	-- exclusive bounds, like Roblox's: { key = ..., sortKey = ... }
	local function within(item: any, lower: any?, upper: any?): boolean
		if lower ~= nil and lower.sortKey ~= nil then
			if type(item.sortKey) == type(lower.sortKey) and item.sortKey <= lower.sortKey then
				return false
			end
		end
		if upper ~= nil and upper.sortKey ~= nil then
			if type(item.sortKey) == type(upper.sortKey) and item.sortKey >= upper.sortKey then
				return false
			end
		end
		if lower ~= nil and lower.key ~= nil and lower.sortKey == nil and item.key <= lower.key then
			return false
		end
		if upper ~= nil and upper.key ~= nil and upper.sortKey == nil and item.key >= upper.key then
			return false
		end
		return true
	end

	function fake.range(direction: string, count: number, lower: any?, upper: any?): { any }
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
		charge("range", nil, #out + 1)
		return out
	end

	function fake.entries(): { any }
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

	return fake
end

return SortedMapFake
