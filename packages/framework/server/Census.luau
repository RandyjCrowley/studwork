--!strict
--[[
	The census (module-api.md §23.5): how many servers and players the experience has, from a
	framework-owned sorted map (`SW/_/census`), so modules scale their cadences with the server
	count, plus the usage items that carry each module's memory charges.

	  Census.new(opts) -> census
	    opts = { fixed = { servers, players, peakPlayers? }?   a fixed reading (harness `census = {...}`)
	             now = () -> number, log,
	             map = backend | () -> backend?   the census map's raw sorted-map backend
	                                             (platform.stores.sortedMap(Census.MAP)); none = no census
	             budget = StoreBudget?    memory usage to report / totals to learn; units are charged
	                                      to StoreBudget.FRAMEWORK; its censusSeconds is the interval
	             interval = number?       (without a budget; default 60)
	             players = () -> number   players in this server
	             spawn = (fn) -> () }   (platform.spawn: a cycle yields)
	    census.start()          begin reporting and reading: one cycle now (spawned)
	    census.tick(dt)         the runtime's tick: spawns the next cycle once `interval` seconds
	                            have passed since the last one started (never two at once)
	    census.cycle()          one report-and-read (yields)
	    census.get() -> CensusInfo?     the last reading; nil until the first read; doesn't yield
	    census.api = ctx.data.census (the same function)

	One cycle (every `censusSeconds`, each server):
	  1. the first cycle reads every usage item (one range over `u/`), so a new server knows what
	     the experience already holds;
	  2. this server's new memory charges per module (a remove's give-back is a negative charge)
	     are added to the module's usage item `u/<Module>` (an atomic update; value
	     { v = version, h = { ["h<hour>"] = bytes } }, bucketed by the hour the charged items expire,
	     hours already past dropped, the item living at least 8 days), and the totals it returns
	     become the module's known usage;
	  3. `{ servers = 1, players = n }` is added to the current time bucket `b/<interval>/<bucket>`
	     (an atomic update, expiry 10 min), together with what this server knows (each module's
	     usage: the newest version wins; the daily peaks: the maximum), so the knowledge outlives
	     any one server;
	  4. the last complete bucket is read: servers, players (= CCU), the usage and peaks it
	     carries. The day's peak is kept 9 days; peakPlayers is the highest of the last 8.
	Bucket shards: with more than SHARD_SERVERS servers (the last reading), every server updating
	one bucket item would contend on one key, so the bucket is split into
	K = ceil(servers / SHARD_SERVERS) shards (at most MAX_SHARDS). Shard 0 is `b/<i>/<bucket>` in
	`SW/_/census`; shard k > 0 is `b/<i>/<bucket>/<k>` in the map `SW/_/census/<k>` (a function `map`
	is called with that name, so each shard can be its own partition; a fixed backend holds them all).
	Each server writes one shard (a random draw kept for its life, so a server stays put as K grows)
	and adds its K to the shard's `k` (the maximum). It reads shard 0 of the last bucket first, then
	every shard up to the largest of: its K this cycle, its K last cycle, and shard 0's `k`; and adds
	them up. Shard 0's `k` is how a server that starts after the split (no reading, so its own K is 1)
	finds every shard on its first cycle.
	Steady cost: one update (2 units) + one get per bucket shard (1 unit each) per server per
	interval, plus one update per module that charged memory. A failed call is logged once a minute;
	the last reading stays. The usage items `u/<Module>` are not sharded (their update returns the
	module's experience-wide total): a live check in docs/manual-qa.md.
]]

local StoreBudget = require(script.Parent.StoreBudget)

local Census = {}

Census.MAP = "SW/_/census"
Census.BUCKET_EXPIRY = 600
Census.PEAK_KEEP_DAYS = 9
Census.PEAK_WINDOW_DAYS = 8
Census.WARN_SECONDS = 60
Census.MAX_EXPIRY = 3888000
Census.USAGE_PREFIX = "u/"
Census.SHARD_SERVERS = 500
Census.MAX_SHARDS = 16

-- bucket shards for a server count (1 up to SHARD_SERVERS servers)
function Census.shardsFor(servers: number?): number
	if type(servers) ~= "number" or servers ~= servers or servers <= Census.SHARD_SERVERS then
		return 1
	end
	return math.clamp(math.ceil(servers / Census.SHARD_SERVERS), 1, Census.MAX_SHARDS)
end

local function dayKey(day: number): string
	return "d" .. tostring(day)
end

local function dayOf(key: string): number
	return tonumber(string.sub(key, 2)) or -math.huge
end

local function maxMerge(into: { [string]: number }, from: any)
	if type(from) ~= "table" then
		return
	end
	for k, v in from do
		if type(k) == "string" and type(v) == "number" and v > (into[k] or -math.huge) then
			into[k] = v
		end
	end
end

function Census.new(opts: any): any
	local o = opts or {}
	local fixed = o.fixed
	local now: () -> number = o.now or os.time
	local log: (string) -> () = o.log or function(_m: string) end
	local budget = o.budget
	local interval: number = if budget ~= nil then budget.config.censusSeconds else (o.interval or 60)
	local players: () -> number = o.players or function(): number
		return 0
	end
	local spawn: (any) -> () = o.spawn or function(fn: any)
		fn()
	end
	local mapSource = o.map
	local map: any = nil
	local shardMaps: { [number]: any } = {}
	local draw: number = if type(o.shardDraw) == "number" then o.shardDraw else math.random()
	local lastShards = 1
	local c: any = {}
	local reading: any = nil
	local peaks: { [string]: number } = {}
	local started = false
	local running = false
	local lastStart = -math.huge
	local seeded = false
	local lastWarn = -math.huge

	local function backend(): any
		if map == nil then
			map = if type(mapSource) == "function" then mapSource() else mapSource
		end
		return map
	end

	-- bucket shard k's map and key (shard 0: the census map and the plain key)
	local function shardOf(k: number, bucket: number): (any, string)
		local key = `b/{interval}/{bucket}`
		if k == 0 then
			return backend(), key
		end
		local m = shardMaps[k]
		if m == nil then
			m = if type(mapSource) == "function"
				then (mapSource(`{Census.MAP}/{k}`) or backend())
				else mapSource
			shardMaps[k] = m
		end
		return m, `{key}/{k}`
	end

	local function warn(what: string, err: any)
		local t = now()
		if t - lastWarn >= Census.WARN_SECONDS then
			lastWarn = t
			log(`[StudWork] census: {what} failed: {tostring(err)}`)
		end
	end

	-- one raw call, charged to the framework; (ok, result)
	local function call(what: string, units: number, fn: () -> any): (boolean, any)
		if budget ~= nil then
			budget.chargeUnits(StoreBudget.FRAMEWORK, units)
		end
		local ok, result = pcall(fn)
		if not ok then
			warn(what, result)
		end
		return ok, result
	end

	local function prunePeaks(today: number)
		for key in table.clone(peaks) do
			if dayOf(key) <= today - Census.PEAK_KEEP_DAYS then
				peaks[key] = nil
			end
		end
	end

	local function peakOf(today: number, current: number): number
		local best = current
		for key, n in peaks do
			if dayOf(key) > today - Census.PEAK_WINDOW_DAYS and n > best then
				best = n
			end
		end
		return best
	end

	local function liveHours(value: any): { [string]: number }
		local out = {}
		if type(value) == "table" then
			for key, bytes in value do
				if
					type(key) == "string"
					and type(bytes) == "number"
					and bytes > 0
					and (budget == nil or budget.liveHour(key))
				then
					out[key] = bytes
				end
			end
		end
		return out
	end

	-- a usage value { v = version (counts up on every report), h = { ["h<hour>"] = bytes } }
	local function usageOf(value: any): (number, { [string]: number })
		if type(value) ~= "table" then
			return 0, {}
		end
		return (if type(value.v) == "number" then value.v else 0), liveHours(value.h)
	end

	local function seedUsage()
		local ok, rows = call("usage read", 1, function()
			return backend().range("asc", 200, { key = Census.USAGE_PREFIX }, { key = "u0" })
		end)
		if not ok then
			return
		end
		if budget ~= nil then
			budget.chargeUnits(StoreBudget.FRAMEWORK, #rows)
		end
		seeded = true
		for _, row in rows do
			local moduleName = string.sub(row.key, #Census.USAGE_PREFIX + 1)
			if budget ~= nil and moduleName ~= "" then
				local version, hours = usageOf(row.value)
				budget.mergeKnown(moduleName, hours, version)
			end
		end
	end

	local function reportUsage(t: number)
		if budget == nil then
			return
		end
		local known = budget.known()
		for moduleName, deltas in budget.takeUsage() do
			-- the item lives at least the quota's 8 days, and until the last hour any charge in it
			-- this server knows of expires (at most 45 days)
			local last = math.floor((t + StoreBudget.DEFAULT_LIFETIME) / 3600)
			for _, hours in { deltas, if known[moduleName] then known[moduleName].h else {} } do
				for key in hours do
					last = math.max(last, tonumber(string.sub(key, 2)) or last)
				end
			end
			local expiry = math.clamp((last + 1) * 3600 - t, 1, Census.MAX_EXPIRY)
			local ok, totals = call("usage report", 2, function()
				return backend().update(Census.USAGE_PREFIX .. moduleName, function(old: any): any
					local version, merged = usageOf(old)
					for key, bytes in deltas do
						merged[key] = math.max(0, (merged[key] or 0) + bytes)
						if merged[key] == 0 then
							merged[key] = nil
						end
					end
					return { v = version + 1, h = merged }
				end, expiry)
			end)
			if ok and type(totals) == "table" then
				local version, hours = usageOf(totals)
				budget.setKnown(moduleName, hours, version)
			else
				budget.restoreUsage(moduleName, deltas)
			end
		end
	end

	function c.cycle()
		local t = now()
		local bucket = math.floor(t / interval)
		local today = math.floor(t / 86400)
		if not seeded then
			seedUsage()
		end
		reportUsage(t)
		local here = math.max(0, players())
		local knownUsage = if budget ~= nil then budget.known() else {}
		prunePeaks(today)
		local myPeaks = table.clone(peaks)
		local shards = Census.shardsFor(if reading then reading.servers else nil)
		local readShards = math.max(shards, lastShards)
		lastShards = shards
		local writeMap, writeKey = shardOf(math.min(math.floor(draw * shards), shards - 1), bucket)
		call("report", 2, function()
			return writeMap.update(writeKey, function(old: any): any
				local value = if type(old) == "table" then old else {}
				local u = if type(value.u) == "table" then value.u else {}
				for moduleName, usage in knownUsage do
					-- the newest version of each module's usage wins
					if usage.v > (usageOf(u[moduleName])) then
						u[moduleName] = usage
					end
				end
				local pk = if type(value.pk) == "table" then value.pk else {}
				maxMerge(pk, myPeaks)
				return {
					s = (tonumber(value.s) or 0) + 1,
					p = (tonumber(value.p) or 0) + here,
					u = u,
					pk = pk,
					-- the shard count its writers use (the largest): shard 0's tells readers how many
					-- shards to read, so a server with no reading yet still finds them all
					k = math.max(tonumber(value.k) or 1, shards),
				}
			end, Census.BUCKET_EXPIRY)
		end)
		-- the last bucket, every shard added up (servers and players summed, usage newest, peaks max)
		local last: any = nil
		local k = 0
		while k < readShards do
			local readMap, readKey = shardOf(k, bucket - 1)
			local ok, part = call("read", 1, function()
				return readMap.get(readKey)
			end)
			if not ok then
				return -- a partial sum would undercount: the last reading stays
			end
			if k == 0 and type(part) == "table" and type(part.k) == "number" and part.k == part.k then
				readShards = math.max(readShards, math.clamp(math.floor(part.k), 1, Census.MAX_SHARDS))
			end
			k += 1
			if type(part) == "table" then
				last = last or { s = 0, p = 0, u = {}, pk = {} }
				last.s += tonumber(part.s) or 0
				last.p += tonumber(part.p) or 0
				if type(part.u) == "table" then
					for moduleName, usage in part.u do
						if type(moduleName) == "string" and usageOf(usage) >= usageOf(last.u[moduleName]) then
							last.u[moduleName] = usage
						end
					end
				end
				maxMerge(last.pk, part.pk)
			end
		end
		if last == nil then
			return
		end
		local servers = tonumber(last.s) or 0
		local ccu = tonumber(last.p) or 0
		maxMerge(peaks, last.pk)
		local readDay = math.floor((bucket - 1) * interval / 86400)
		peaks[dayKey(readDay)] = math.max(peaks[dayKey(readDay)] or 0, ccu)
		prunePeaks(today)
		if budget ~= nil and type(last.u) == "table" then
			for moduleName, usage in last.u do
				if type(moduleName) == "string" then
					local version, hours = usageOf(usage)
					budget.mergeKnown(moduleName, hours, version)
				end
			end
		end
		reading = table.freeze({
			servers = servers,
			players = ccu,
			peakPlayers = peakOf(today, ccu),
			at = t,
		})
	end

	function c.start()
		if started or type(fixed) == "table" or mapSource == nil then
			return
		end
		started = true
		c.tick(0)
	end

	local function runCycle()
		local ok, err = pcall(c.cycle)
		running = false
		if not ok then
			warn("cycle", err)
		end
	end

	function c.tick(_dt: number)
		if not started or running or now() - lastStart < interval then
			return
		end
		running = true
		lastStart = now()
		spawn(runCycle)
	end

	function c.get(): any
		if type(fixed) == "table" then
			return table.freeze({
				servers = fixed.servers,
				players = fixed.players,
				peakPlayers = fixed.peakPlayers or fixed.players,
				at = now(),
			})
		end
		return reading
	end

	c.api = c.get
	if budget ~= nil then
		budget.attachCensus(c)
	end
	return c
end

return Census
