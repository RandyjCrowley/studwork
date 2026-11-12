--!strict
--[[
	Store budgets (module-api.md §23.5): request units and memory accounting for the ordered
	stores and the sorted maps, from GameConfig.storeBudgets. One per server runtime.

	  StoreBudget.resolve(config) -> the full config with every default filled in
	  StoreBudget.new(opts) -> budget
	    opts = { config = storeBudgets?, players = () -> number (players in this server; default 0),
	             now = () -> number, log = (string) -> () }
	    budget.allowOrdered(moduleName, kind, remaining?) -> boolean
	        ordered stores (kind: get/set/increment/update/remove/top); false = "budget". Refused
	        while this server's budget for the request type is at or below orderedReserve x the
	        per-minute limit for the current player count (ORDERED_LIMITS; an update is one read and
	        one write). The budget left is the platform's (`remaining`, when the backend reports it)
	        and this server's own count of its ordered calls in the last minute, whichever is lower.
	    budget.chargeUnits(moduleName, units) -> boolean
	        sorted-map request units: this server's modules together are capped at
	        memoryUnits.base + memoryUnits.perPlayer x players per minute. The framework's own use
	        (moduleName FRAMEWORK, the census) is counted but never refused.
	    budget.recordUnits(moduleName, units)              units already spent (a range's rows)
	    budget.chargeMemory(moduleName, bytes, expiresAt?) -> boolean
	        a growing sorted-map write; false = "memory_budget" when the module's total would pass
	        share x quota or every module's together (1 - reserve) x quota
	    budget.releaseMemory(moduleName, bytes, expiresAt?)  a remove gives back what was charged
	    budget.quota() -> bytes        64 KB + 1.2 KB x peakPlayers (the census; else this server's players)
	    budget.moduleBytes(moduleName) / totalBytes() -> the experience-wide estimate
	    budget.unitsUsed() -> number   this server's modules' units in the last minute

	  Census hooks (Census.luau; usage is bucketed by the hour its items expire, "h<hour>"):
	    budget.attachCensus(census)                the reading quota() uses for peakPlayers
	    budget.takeUsage() -> { [module] = { [hourKey] = delta } }   this server's unreported
	                                               charges (cleared); restoreUsage(module, deltas)
	                                               puts them back after a failed report
	    budget.setKnown(module, totals, version)   the experience totals the report returned
	    budget.mergeKnown(module, totals, version) totals read back (kept when the version is newer)
	    budget.known() -> { [module] = { v = version, h = { [hourKey] = bytes } } }   live hours only
	    budget.hourKey(t) -> string                budget.liveHour(hourKey) -> boolean
]]

local StoreBudget = {}

StoreBudget.DEFAULTS = table.freeze({
	orderedReserve = 0.25,
	memoryUnits = table.freeze({ base = 20, perPlayer = 20 }),
	memory = table.freeze({ reserve = 0.2, defaultShare = 0.25, shares = table.freeze({}) }),
	censusSeconds = 60,
})

-- Roblox's per-server OrderedDataStore limits per minute: base + perPlayer x players
StoreBudget.ORDERED_LIMITS = table.freeze({
	list = table.freeze({ base = 5, perPlayer = 2 }),
	read = table.freeze({ base = 60, perPlayer = 40 }),
	write = table.freeze({ base = 30, perPlayer = 5 }),
	remove = table.freeze({ base = 30, perPlayer = 5 }),
})
StoreBudget.ORDERED_KINDS = table.freeze({
	get = table.freeze({ "read" }),
	set = table.freeze({ "write" }),
	increment = table.freeze({ "write" }),
	update = table.freeze({ "read", "write" }),
	remove = table.freeze({ "remove" }),
	top = table.freeze({ "list" }),
})
-- Roblox's MemoryStore memory quota: base + perUser x users (bytes)
StoreBudget.MEMORY_QUOTA = table.freeze({ base = 64 * 1024, perUser = 1.2 * 1024 })
StoreBudget.WINDOW = 60
StoreBudget.FRAMEWORK = "_"
-- a write that gives no expiry is counted as living this long (the quota's own 8 days)
StoreBudget.DEFAULT_LIFETIME = 8 * 86400

function StoreBudget.resolve(config: any): any
	local c = if type(config) == "table" then config else {}
	local units = if type(c.memoryUnits) == "table" then c.memoryUnits else {}
	local mem = if type(c.memory) == "table" then c.memory else {}
	return table.freeze({
		orderedReserve = if type(c.orderedReserve) == "number"
			then c.orderedReserve
			else StoreBudget.DEFAULTS.orderedReserve,
		memoryUnits = table.freeze({
			base = if type(units.base) == "number" then units.base else StoreBudget.DEFAULTS.memoryUnits.base,
			perPlayer = if type(units.perPlayer) == "number"
				then units.perPlayer
				else StoreBudget.DEFAULTS.memoryUnits.perPlayer,
		}),
		memory = table.freeze({
			reserve = if type(mem.reserve) == "number"
				then mem.reserve
				else StoreBudget.DEFAULTS.memory.reserve,
			defaultShare = if type(mem.defaultShare) == "number"
				then mem.defaultShare
				else StoreBudget.DEFAULTS.memory.defaultShare,
			shares = if type(mem.shares) == "table"
				then table.freeze(table.clone(mem.shares))
				else StoreBudget.DEFAULTS.memory.shares,
		}),
		censusSeconds = if type(c.censusSeconds) == "number"
			then c.censusSeconds
			else StoreBudget.DEFAULTS.censusSeconds,
	})
end

function StoreBudget.hourKey(t: number): string
	return "h" .. tostring(math.floor(t / 3600))
end

local function hourOf(key: string): number
	return tonumber(string.sub(key, 2)) or -math.huge
end

-- a rolling one-minute count: { { at, n } }
local function windowSum(list: { any }, t: number): number
	local total = 0
	local i = 1
	while i <= #list do
		if list[i].at <= t - StoreBudget.WINDOW then
			table.remove(list, i)
		else
			total += list[i].n
			i += 1
		end
	end
	return total
end

function StoreBudget.new(opts: any): any
	local o = opts or {}
	local config = StoreBudget.resolve(o.config)
	local now: () -> number = o.now or os.time
	local players: () -> number = o.players or function(): number
		return 0
	end
	local b: any = { config = config, now = now }
	local census: any = nil

	local orderedUsed: { [string]: { any } } = { list = {}, read = {}, write = {}, remove = {} }
	local unitsUsed: { any } = {}
	local frameworkUnits: { any } = {}
	local pending: { [string]: { [string]: number } } = {}
	local known: { [string]: { [string]: number } } = {}
	local knownVersion: { [string]: number } = {}

	function b.liveHour(key: string): boolean
		return hourOf(key) >= math.floor(now() / 3600)
	end

	local function playerCount(): number
		local ok, n = pcall(players)
		return if ok and type(n) == "number" then n else 0
	end

	function b.orderedLimit(category: string): number
		local limit = StoreBudget.ORDERED_LIMITS[category]
		return limit.base + limit.perPlayer * playerCount()
	end

	function b.allowOrdered(moduleName: string, kind: string, remaining: number?): boolean
		local categories = StoreBudget.ORDERED_KINDS[kind]
		if categories == nil then
			error(`StoreBudget.allowOrdered: unknown request kind '{tostring(kind)}' ({moduleName})`, 2)
		end
		local t = now()
		local reserve = config.orderedReserve
		local smallest = math.huge
		for _, category in categories do
			local limit = b.orderedLimit(category)
			smallest = math.min(smallest, limit)
			if limit - windowSum(orderedUsed[category], t) <= reserve * limit then
				return false
			end
		end
		if remaining ~= nil and remaining <= reserve * smallest then
			return false
		end
		for _, category in categories do
			table.insert(orderedUsed[category], { at = t, n = 1 })
		end
		return true
	end

	function b.unitsCap(): number
		return config.memoryUnits.base + config.memoryUnits.perPlayer * playerCount()
	end

	function b.unitsUsed(): number
		return windowSum(unitsUsed, now())
	end

	function b.frameworkUnitsUsed(): number
		return windowSum(frameworkUnits, now())
	end

	function b.recordUnits(moduleName: string, units: number)
		if units <= 0 then
			return
		end
		table.insert(
			if moduleName == StoreBudget.FRAMEWORK then frameworkUnits else unitsUsed,
			{ at = now(), n = units }
		)
	end

	function b.chargeUnits(moduleName: string, units: number): boolean
		if moduleName ~= StoreBudget.FRAMEWORK and b.unitsUsed() + units > b.unitsCap() then
			return false
		end
		b.recordUnits(moduleName, units)
		return true
	end

	-- memory --------------------------------------------------------------------

	function b.attachCensus(c: any)
		census = c
	end

	function b.quota(): number
		local reading = if census ~= nil then census.get() else nil
		local peak = if reading ~= nil and type(reading.peakPlayers) == "number"
			then reading.peakPlayers
			else playerCount()
		return StoreBudget.MEMORY_QUOTA.base + StoreBudget.MEMORY_QUOTA.perUser * peak
	end

	local function sumLive(map: { [string]: number }?): number
		local total = 0
		local m: { [string]: number } = map or {}
		for key, bytes in m do
			if b.liveHour(key) then
				total += bytes
			end
		end
		return total
	end

	function b.moduleBytes(moduleName: string): number
		return math.max(0, sumLive(known[moduleName]) + sumLive(pending[moduleName]))
	end

	function b.totalBytes(): number
		local names: { [string]: boolean } = {}
		for name in known do
			names[name] = true
		end
		for name in pending do
			names[name] = true
		end
		local total = 0
		for name in names do
			total += b.moduleBytes(name)
		end
		return total
	end

	function b.shareOf(moduleName: string): number
		return config.memory.shares[moduleName] or config.memory.defaultShare
	end

	local function addPending(moduleName: string, key: string, bytes: number)
		local map = pending[moduleName] or {}
		pending[moduleName] = map
		map[key] = (map[key] or 0) + bytes
		if map[key] == 0 then
			map[key] = nil
		end
	end

	function b.chargeMemory(moduleName: string, bytes: number, expiresAt: number?): boolean
		if bytes <= 0 then
			return true
		end
		local quota = b.quota()
		if b.moduleBytes(moduleName) + bytes > b.shareOf(moduleName) * quota then
			return false
		end
		if b.totalBytes() + bytes > (1 - config.memory.reserve) * quota then
			return false
		end
		addPending(
			moduleName,
			StoreBudget.hourKey(expiresAt or (now() + StoreBudget.DEFAULT_LIFETIME)),
			bytes
		)
		return true
	end

	function b.releaseMemory(moduleName: string, bytes: number, expiresAt: number?)
		if bytes <= 0 then
			return
		end
		addPending(
			moduleName,
			StoreBudget.hourKey(expiresAt or (now() + StoreBudget.DEFAULT_LIFETIME)),
			-bytes
		)
	end

	local function pruned(map: { [string]: number }?): { [string]: number }
		local out = {}
		local m: { [string]: number } = map or {}
		for key, bytes in m do
			if b.liveHour(key) and bytes ~= 0 then
				out[key] = bytes
			end
		end
		return out
	end

	-- the deltas move into `known` at once, so the estimate doesn't dip while the report is in flight
	function b.takeUsage(): { [string]: { [string]: number } }
		local out = {}
		for name, map in pending do
			local live = pruned(map)
			if next(live) ~= nil then
				out[name] = live
				local k = known[name] or {}
				known[name] = k
				for key, bytes in live do
					k[key] = (k[key] or 0) + bytes
				end
			end
		end
		pending = {}
		return out
	end

	function b.restoreUsage(moduleName: string, deltas: { [string]: number })
		local k = known[moduleName]
		for key, bytes in deltas do
			if k ~= nil and k[key] ~= nil then
				k[key] -= bytes
			end
			addPending(moduleName, key, bytes)
		end
	end

	-- the totals of the module's usage item at `version` (it counts up on every report)
	function b.setKnown(moduleName: string, totals: { [string]: number }, version: number)
		known[moduleName] = pruned(totals)
		knownVersion[moduleName] = version
	end

	-- totals read back (another server's report, carried in a census bucket): kept when newer
	function b.mergeKnown(moduleName: string, totals: { [string]: number }, version: number)
		if version > (knownVersion[moduleName] or -math.huge) then
			b.setKnown(moduleName, totals, version)
		end
	end

	function b.known(): { [string]: { v: number, h: { [string]: number } } }
		local out = {}
		for name, map in known do
			local live = pruned(map)
			if next(live) ~= nil and knownVersion[name] ~= nil then
				out[name] = { v = knownVersion[name], h = live }
			end
		end
		return out
	end

	return b
end

return StoreBudget
