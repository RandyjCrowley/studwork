--!strict
--[[
	In-memory MemoryStore sorted map (StudWork.test, module-api.md §23.4 / §23.10): the backend behind
	`ctx.data.sortedMap(name)` in the harness and the sim, with Roblox's limits applied as live. The
	map itself is PlatformStores.memorySortedMap (the Studio fallback's code); this adds the limits,
	the quota, call recording and failure injection.

	  SortedMapFake.new(opts?) -> fake
	    opts = { name = string?, clock = () -> number (seconds; expiry runs on it, the harness clock),
	             structureLimit = number? (request units a minute for the whole map, default 100000),
	             partitionLimit = number? (units a minute on its one partition, default 30000),
	             registry = { memoryUsed() -> number, quotaBytes: number?,
	                          shouldFail: ((op, storeName, key?) -> boolean)? }? }
	               registry: the experience memory quota every map of the registry shares, and an
	               optional failure hook (the sim's world:failNext / failFor with a store match)
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

	Request units: a range costs one per row returned plus one; update two; every other call one.
	Every server sharing the registry shares the map, so the limits are the experience's: over
	`structureLimit` a call raises DataStructureRequestsOverLimit, over `partitionLimit`
	PartitionRequestsOverLimit (a refused call isn't counted). A growing write past the registry's
	`quotaBytes` raises TotalMemoryOverLimit. A registry `shouldFail` hit raises InternalError.
]]

local PlatformStores = (require :: any)(script.Parent.Parent.Parent.server.PlatformStores)

local SortedMapFake = {}

SortedMapFake.STRUCTURE_LIMIT = 100000
SortedMapFake.PARTITION_LIMIT = 30000
SortedMapFake.WINDOW = 60

function SortedMapFake.new(opts: any?): any
	local o = opts or {}
	local clock: () -> number = o.clock or os.time
	local structureLimit: number = o.structureLimit or SortedMapFake.STRUCTURE_LIMIT
	local partitionLimit: number = o.partitionLimit or SortedMapFake.PARTITION_LIMIT
	local registry = o.registry
	local fake: any = { name = o.name, calls = {} }
	local failures, failCode = 0, "RequestThrottled"
	local windowStart, windowUnits = -math.huge, 0

	-- a growing write must fit the experience-wide quota (every map of the registry together)
	local core = PlatformStores.memorySortedMap({
		clock = clock,
		beforeWrite = function(growth: number)
			if registry ~= nil and type(registry.quotaBytes) == "number" and growth > 0 then
				if registry.memoryUsed() + growth > registry.quotaBytes then
					error("TotalMemoryOverLimit", 0)
				end
			end
		end,
	})

	local function windowNow(): number
		local now = clock()
		if now - windowStart >= SortedMapFake.WINDOW then
			windowStart, windowUnits = now, 0
		end
		return windowUnits
	end

	local function charge(op: string, key: string?, units: number)
		table.insert(fake.calls, { op = op, key = key, units = units })
		if failures > 0 then
			failures -= 1
			error(failCode, 0)
		end
		if registry ~= nil and registry.shouldFail ~= nil and registry.shouldFail(op, o.name, key) then
			error("InternalError: injected failure (" .. op .. ")", 0)
		end
		local used = windowNow() + units
		if used > structureLimit then
			error("DataStructureRequestsOverLimit", 0)
		end
		if used > partitionLimit then
			error("PartitionRequestsOverLimit", 0)
		end
		windowUnits = used
	end

	function fake.failNext(n: number, code: string?)
		failures += n
		failCode = code or "RequestThrottled"
	end

	function fake.unitsThisMinute(): number
		return windowNow()
	end

	fake.memoryBytes = core.memoryBytes
	fake.entries = core.entries

	function fake.get(key: string): (any, (number | string)?)
		charge("get", key, 1)
		return core.get(key)
	end

	function fake.set(key: string, value: any, expirySeconds: number, sortKey: (number | string)?)
		charge("set", key, 1)
		core.set(key, value, expirySeconds, sortKey)
	end

	function fake.update(
		key: string,
		fn: (old: any, oldSortKey: (number | string)?) -> (any, (number | string)?),
		expirySeconds: number
	): any
		charge("update", key, 2)
		local new = core.update(key, fn, expirySeconds)
		if new == nil then
			-- cancelled: Roblox's UpdateAsync returns nil; keep the item as it was
			return nil
		end
		return new
	end

	function fake.remove(key: string)
		charge("remove", key, 1)
		core.remove(key)
	end

	function fake.range(direction: string, count: number, lower: any?, upper: any?): { any }
		local rows = core.range(direction, count, lower, upper)
		charge("range", nil, #rows + 1)
		return rows
	end

	return fake
end

return SortedMapFake
