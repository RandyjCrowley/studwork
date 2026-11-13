--!strict
--[[
	The audit log (design §4 as amended by B1 and Addendum C; docs "Audit log", "Shared store keys").

	  Audit.new(o) -> audit
	    o = { shared (ctx.data.shared), map (ctx.data.sortedMap("pending"), the sweep lease), cfg
	          (config.Moderation: audit, retry), now () -> number, job (the JobId or "studio"),
	          log (ctx.log), wait? }
	  audit.add(entry)                  buffer one entry (id/at/server filled here); capped at bufferMax,
	                                    oldest dropped and counted
	  audit.tick()                      flush when due (every audit.flushSeconds, only when non-empty;
	                                    after a failure with the retry backoff); spawns, never yields
	  audit.flush(deadline?) -> boolean writes the buffer (yields); keeps what failed. One flush at a
	                                    time: a second call waits for the running one (until deadline)
	  audit.query(viewer?, q) -> (ok, entries | reason, more?)
	                                    q = { target?, day?, limit, page?, cacheOnly? }. Addendum G H2:
	                                    a day read touches the day directory plus at most
	                                    audit.chunksPerRead chunk keys, newest chunks first; `page` (1..)
	                                    picks the next chunksPerRead, `more` = older chunks exist. A
	                                    target read touches only a/u/<userId>. Store answers are cached
	                                    readCacheSeconds (TTL only: new entries don't clear it); this
	                                    server's own recent entries (flushed or not, the last
	                                    bufferMax) are merged from memory into page 1 / the target
	                                    view. A store read costs the viewer audit.readSecondsPerStaff
	                                    (nil viewer = trusted, never limited); cacheOnly answers
	                                    (false, "not_cached") instead of reading. Entries older than
	                                    retentionDays are never returned.
	  audit.sweep() -> boolean          the retention sweep, run by the server holding the "sweep"
	                                    lease in the pending sorted map (yields). Sweeps every expired
	                                    day after the persisted marker a/s (at most retentionDays + 7
	                                    days back) and moves the marker past each day fully deleted
	  audit.buffered() -> number, audit.dropped() -> number

	Keys (ctx.data.shared, prefixed with "Moderation/" by the framework):
	  a/<day>/<job8>/<seq>   one chunk: at most audit.chunkSize entries from one server
	  a/<day>/d              that day's directory: the "<job8>/<seq>" suffixes, one append per new chunk
	  a/u/<userId>           the last audit.perTargetMax entries about (or, for bans, by) a user,
	                         entries older than retentionDays dropped on every write
	  a/s                    the sweep marker { day }: every day up to it is swept
	A read is an update that returns `old` (never nil, which would delete).
]]

local Util = require(script.Parent.Util)

local Audit = {}

local SWEEP_KEY = "sweep"
local SWEEP_MARKER = "a/s"
local SWEEP_EXTRA_DAYS = 7 -- how far past retentionDays a sweep looks back (Addendum G)
local FLUSH_WAIT = 0.05 -- seconds between checks while another flush runs

local function readKey(shared: any, key: string): (boolean, any)
	return shared.update(key, function(old: any): any
		return old
	end)
end

function Audit.new(o: any): any
	local shared = o.shared
	local cfg = o.cfg
	local now: () -> number = o.now
	local log = o.log
	local job: string = o.job
	local job8 = string.sub(job, 1, 8)

	local self: any = {}
	local queue: { any } = {} -- entries not yet in a chunk
	local index: { [number]: { any } } = {} -- userId -> entries not yet in its a/u key
	local dirs: { [number]: { string } } = {} -- day -> chunk suffixes not yet in its directory
	local chunk: { [number]: { seq: number, count: number } } = {}
	local droppedTotal = 0
	local droppedSinceLog = 0
	local failures = 0
	local nextFlushAt = 0
	local flushing = false -- a flush is running (tick's or another caller's)
	local counter = 0
	local cache: { [string]: { at: number, entries: { any }, more: boolean } } = {}
	local lastRead: { [any]: number } = {}
	local recent: { any } = {} -- this server's last bufferMax entries (flushed or not), oldest first

	local function retention(): number
		return cfg.audit.retentionDays * 86400
	end

	local function pushIndex(userId: number, entry: any)
		local list = index[userId]
		if list == nil then
			list = {}
			index[userId] = list
		end
		table.insert(list, entry)
		while #list > cfg.audit.perTargetMax do
			table.remove(list, 1)
		end
	end

	function self.add(entry: any): any
		counter += 1
		local t = now()
		entry.id = entry.id or `{job8}-{t}-{counter}`
		entry.at = entry.at or t
		entry.server = job
		entry.placeVersion = o.placeVersion or 0
		if type(entry.privateReason) == "string" then
			entry.privateReason = Util.cutChars(entry.privateReason, cfg.audit.privateReasonMax)
		end
		table.insert(queue, entry)
		table.insert(recent, entry)
		while #recent > cfg.audit.bufferMax do
			table.remove(recent, 1)
		end
		while #queue > cfg.audit.bufferMax do
			table.remove(queue, 1)
			droppedTotal += 1
			droppedSinceLog += 1
		end
		if type(entry.target) == "number" then
			pushIndex(entry.target, entry)
		end
		-- M14: a staff member's bans also land in their own index
		if
			entry.byKind == "staff"
			and entry.action == "ban"
			and entry.by ~= entry.target
			and entry.by > 0
		then
			pushIndex(entry.by, entry)
		end
		return entry
	end

	function self.buffered(): number
		return #queue
	end

	function self.dropped(): number
		return droppedTotal
	end

	local function backoff(): number
		local r = cfg.retry
		return math.min(r.max, r.base * r.factor ^ math.max(0, failures - 1))
	end

	local function outOfTime(deadline: number?): boolean
		return deadline ~= nil and os.clock() > deadline
	end

	-- appends `entries` (all of one day) to this server's chunks; returns what is still unwritten
	local function writeDay(day: number, entries: { any }, deadline: number?): { any }
		local state = chunk[day]
		if state == nil then
			state = { seq = 1, count = 0 }
			chunk[day] = state
		end
		local rest = entries
		while #rest > 0 do
			if outOfTime(deadline) then
				return rest
			end
			local suffix = `{job8}/{state.seq}`
			local wasNew = false
			local taken = 0
			local toWrite = rest
			local ok = shared.update(`a/{day}/{suffix}`, function(old: any): any
				local list = if type(old) == "table" then table.clone(old) else {}
				wasNew = old == nil
				taken = math.max(0, math.min(cfg.audit.chunkSize - #list, #toWrite))
				if taken == 0 then
					return old
				end
				for i = 1, taken do
					table.insert(list, toWrite[i])
				end
				return list
			end)
			if not ok then
				return rest
			end
			if wasNew and taken > 0 then
				dirs[day] = dirs[day] or {}
				table.insert(dirs[day], suffix)
			end
			state.count += taken
			if taken == 0 or state.count >= cfg.audit.chunkSize then
				state.seq += 1
				state.count = 0
			end
			local left = {}
			for i = taken + 1, #rest do
				table.insert(left, rest[i])
			end
			rest = left
		end
		return rest
	end

	local function writeDirs(deadline: number?): boolean
		local allOk = true
		local days: { number } = {}
		for day in dirs do
			table.insert(days, day)
		end
		for _, day in days do
			if outOfTime(deadline) then
				return false
			end
			-- swapped out before the update yields (Addendum G): suffixes added meanwhile go to a
			-- new list instead of being dropped with this one
			local add = dirs[day]
			dirs[day] = nil
			local ok = shared.update(`a/{day}/d`, function(old: any): any
				local list = if type(old) == "table" then table.clone(old) else {}
				for _, s in add do
					if table.find(list, s) == nil then
						table.insert(list, s)
					end
				end
				return list
			end)
			if not ok then
				local later: { string } = dirs[day] or {}
				for _, suffix in later do
					table.insert(add, suffix)
				end
				dirs[day] = add
				allOk = false
			end
		end
		return allOk
	end

	local function writeIndex(deadline: number?): boolean
		local allOk = true
		local users: { number } = {}
		for userId in index do
			table.insert(users, userId)
		end
		for _, userId in users do
			if outOfTime(deadline) then
				return false
			end
			local add = index[userId]
			index[userId] = nil -- swapped out (see writeDirs)
			local oldest = now() - retention()
			local max = cfg.audit.perTargetMax
			local ok = shared.update(`a/u/{userId}`, function(old: any): any
				local list = {}
				if type(old) == "table" then
					for _, e in old do
						if type(e) == "table" and type(e.at) == "number" and e.at >= oldest then
							table.insert(list, e)
						end
					end
				end
				for _, e in add do
					table.insert(list, e)
				end
				while #list > max do
					table.remove(list, 1)
				end
				return list
			end)
			if not ok then
				local later: { any } = index[userId] or {}
				for _, e in later do
					table.insert(add, e)
				end
				while #add > max do
					table.remove(add, 1)
				end
				index[userId] = add
				allOk = false
			end
		end
		return allOk
	end

	local function flushNow(deadline: number?): boolean
		if droppedSinceLog > 0 then
			log.warn(`audit buffer full: dropped {droppedSinceLog} oldest entries`)
			droppedSinceLog = 0
		end
		local byDay: { [number]: { any } } = {}
		local days: { number } = {}
		for _, e in queue do
			local d = Util.day(e.at)
			if byDay[d] == nil then
				byDay[d] = {}
				table.insert(days, d)
			end
			table.insert(byDay[d], e)
		end
		table.sort(days)
		queue = {}
		local left: { any } = {}
		for _, d in days do
			for _, e in writeDay(d, byDay[d], deadline) do
				table.insert(left, e)
			end
		end
		-- entries added while this flush yielded stay queued after the unwritten ones
		for _, e in queue do
			table.insert(left, e)
		end
		queue = left
		local dirsOk = writeDirs(deadline)
		local indexOk = writeIndex(deadline)
		return #left == 0 and dirsOk and indexOk
	end

	-- one flush at a time (Addendum G): the shutdown flush waits for a running tick flush
	function self.flush(deadline: number?): boolean
		while flushing do
			if outOfTime(deadline) then
				return false
			end
			task.wait(FLUSH_WAIT)
		end
		flushing = true
		local ok, done = pcall(flushNow, deadline)
		flushing = false
		if not ok then
			error(done, 0)
		end
		return done
	end

	local function hasWork(): boolean
		return #queue > 0 or next(index) ~= nil or next(dirs) ~= nil
	end

	function self.tick()
		local t = now()
		if flushing or t < nextFlushAt or not hasWork() then
			return
		end
		task.spawn(function()
			local ok, done = pcall(self.flush, nil)
			if ok and done then
				failures = 0
				nextFlushAt = now() + cfg.audit.flushSeconds
			else
				failures += 1
				nextFlushAt = now() + backoff()
				if not ok then
					log.warn(`audit flush failed: {tostring(done)}`)
				end
			end
		end)
	end

	-- the chunk suffixes of one day, newest first: this server's chunks not yet in the directory,
	-- then the directory read backwards (one read of a/<day>/d)
	local function daySuffixes(day: number): (boolean, { string })
		local okDir, dir = readKey(shared, `a/{day}/d`)
		if not okDir then
			return false, {}
		end
		local out: { string } = {}
		local unlisted: { string } = dirs[day] or {}
		for i = #unlisted, 1, -1 do
			table.insert(out, unlisted[i])
		end
		if type(dir) == "table" then
			for i = #dir, 1, -1 do
				local suffix = dir[i]
				if type(suffix) == "string" and table.find(out, suffix) == nil then
					table.insert(out, suffix)
				end
			end
		end
		return true, out
	end

	-- one page of a day: the directory plus at most chunksPerRead chunk keys -> (ok, entries, more)
	local function readDay(day: number, page: number): (boolean, { any }, boolean)
		local okDir, suffixes = daySuffixes(day)
		if not okDir then
			return false, {}, false
		end
		local per = cfg.audit.chunksPerRead
		local out = {}
		for i = (page - 1) * per + 1, math.min(#suffixes, page * per) do
			local ok, list = readKey(shared, `a/{day}/{suffixes[i]}`)
			if not ok then
				return false, {}, false
			end
			if type(list) == "table" then
				for _, e in list do
					table.insert(out, e)
				end
			end
		end
		return true, out, #suffixes > page * per
	end

	local function readTarget(userId: number): (boolean, { any })
		local ok, list = readKey(shared, `a/u/{userId}`)
		if not ok then
			return false, {}
		end
		return true, if type(list) == "table" then table.clone(list) else {}
	end

	local function about(e: any, userId: number): boolean
		return e.target == userId or (e.byKind == "staff" and e.action == "ban" and e.by == userId)
	end

	-- (ok, entries | reason, more?, fromStore?)
	function self.query(viewer: any?, q: any): (boolean, any, boolean?, boolean?)
		local t = now()
		local day = q.day or Util.day(t)
		local page = if type(q.page) == "number" and q.page >= 1 then math.floor(q.page) else 1
		local key = `{tostring(q.target)}|{day}|{page}|{q.limit}`
		local hit = cache[key]
		local stored: { any }
		local more = false
		local fromStore = false
		if hit ~= nil and t - hit.at < cfg.audit.readCacheSeconds then
			stored, more = hit.entries, hit.more
		else
			if q.cacheOnly then
				return false, "not_cached", nil, nil
			end
			if viewer ~= nil then
				local last = lastRead[viewer]
				if last ~= nil and t - last < cfg.audit.readSecondsPerStaff then
					return false, "rate_limited", nil, nil
				end
				lastRead[viewer] = t
			end
			local ok, entries
			if q.target ~= nil then
				ok, entries = readTarget(q.target)
			else
				ok, entries, more = readDay(day, page)
			end
			if not ok then
				return false, "failed", nil, nil
			end
			stored = entries
			fromStore = true
			cache[key] = { at = t, entries = stored, more = more }
		end
		-- this server's own entries come from memory (fresher than any cached store answer)
		local merged = table.clone(stored)
		local mine: { [string]: boolean } = {}
		for _, e in recent do
			mine[e.id] = true
		end
		if q.target ~= nil then
			for _, e in recent do
				if about(e, q.target) then
					table.insert(merged, e)
				end
			end
		elseif page == 1 then
			for _, e in recent do
				if Util.day(e.at) == day then
					table.insert(merged, e)
				end
			end
		end
		local oldest = t - retention()
		local seen: { [string]: boolean } = {}
		local unique = {}
		for _, e in merged do
			if
				type(e) == "table"
				and type(e.id) == "string"
				and not seen[e.id]
				and type(e.at) == "number"
				and e.at >= oldest
				-- an older page doesn't repeat what page 1 showed from memory
				and (q.target ~= nil or page == 1 or not mine[e.id])
			then
				seen[e.id] = true
				table.insert(unique, e)
			end
		end
		table.sort(unique, function(a: any, b: any): boolean
			if a.at ~= b.at then
				return a.at > b.at
			end
			return a.id > b.id
		end)
		local out = {}
		-- the per-target view stays the per-target index: its newest perTargetMax entries
		local max = if q.target ~= nil then math.min(q.limit, cfg.audit.perTargetMax) else q.limit
		for i = 1, math.min(max, #unique) do
			table.insert(out, table.freeze(table.clone(unique[i])))
		end
		return true, out, more, fromStore
	end

	-- the "sweep" lease in the pending sorted map: one server sweeps at a time
	local function takeLease(seconds: number): boolean
		local t = now()
		local ok, new = o.map.update(SWEEP_KEY, function(old: any): any
			if type(old) == "table" and old.owner ~= job and (old.leaseUntil or 0) > t then
				return nil -- held by another server: cancel
			end
			return { owner = job, leaseUntil = t + seconds }, t
		end, math.max(1, math.ceil(seconds)))
		return ok == true and type(new) == "table" and new.owner == job
	end

	local function sweepDay(day: number): boolean
		local ok, dir = readKey(shared, `a/{day}/d`)
		if not ok then
			return false
		end
		if type(dir) ~= "table" then
			return true -- nothing logged that day (or already swept)
		end
		local allGone = true
		for _, suffix in dir do
			local okDel = shared.update(`a/{day}/{suffix}`, function(_old: any): any
				return nil
			end)
			if not okDel then
				allGone = false
			end
		end
		if not allGone then
			return false
		end
		return (shared.update(`a/{day}/d`, function(_old: any): any
			return nil
		end))
	end

	function self.sweep(leaseSeconds: number): boolean
		if not takeLease(leaseSeconds) then
			return false
		end
		local today = Util.day(now())
		local last = today - cfg.audit.retentionDays - 1 -- the newest expired day
		local first = last - (cfg.audit.retentionDays + SWEEP_EXTRA_DAYS) + 1
		local okMark, mark = readKey(shared, SWEEP_MARKER)
		if okMark and type(mark) == "table" and type(mark.day) == "number" then
			first = math.max(first, mark.day + 1)
		end
		local swept: number? = nil
		for day = first, last do
			if not sweepDay(day) then
				break -- the marker stops before a day that isn't fully gone: retried next run
			end
			swept = day
		end
		if swept ~= nil then
			local upTo = swept :: number
			shared.update(SWEEP_MARKER, function(old: any): any
				if type(old) == "table" and type(old.day) == "number" and old.day >= upTo then
					return old
				end
				return { day = upTo }
			end)
		end
		return true
	end

	return self
end

return Audit
