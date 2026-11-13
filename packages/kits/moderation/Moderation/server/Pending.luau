--!strict
--[[
	Pending bans and unbans (design §4 as amended by B2, B3, B8, M9, M19 and Addendum C; docs
	"Pending bans and unbans").

	  Pending.new(o) -> pending
	    o = { shared (ctx.data.shared), map (ctx.data.sortedMap("pending")), cfg (config.Moderation),
	          now () -> number, job (JobId or "studio"), log,
	          call (entry) -> (ok, err)       BanAsync / UnbanAsync for the entry (yields),
	          done (entry, status, note?)     "ok" | "failed" once an entry is finished (audit, signals) }
	  pending.put(userId, entry) -> (saved, indexed)  a new pending "ban" or "unban" for that user: replaces
	                                         whatever was pending for them with a higher seq (B3)
	  pending.clear(userId)                  a direct ban/unban succeeded: drops anything pending for them
	  pending.lookup(userId) -> (known, entry?)  for a join: this server's own entry, else one index `get`
	                                         (known = false when the index can't be read)
	  pending.tick()                         due retries (spawned), the index scan every pending.pollSeconds
	  pending.shutdown(deadline)             tries once more to save entries only held in memory
	  pending.mine() -> { [userId]: entry }  (specs)

	Store: `bans/p/<userId>` = { kind, seq, seconds?, displayKey?, displayText?, privateReason?, by, byKind,
	at, attempts, owner, leaseUntil, offense?, source? }; the sorted map "pending" holds the discovery index
	{ kind, seq, owner, leaseUntil } under key tostring(userId), expiry pending.indexExpiryDays, renewed
	on every attempt. Only the lease holder retries; another server takes over after leaseUntil.
]]

local Util = require(script.Parent.Util)

local Pending = {}

local SCAN_COUNT = 200 -- one sorted-map range page (the Roblox maximum)

function Pending.new(o: any): any
	local shared = o.shared
	local map = o.map
	local cfg = o.cfg
	local now: () -> number = o.now
	local job: string = o.job
	local log = o.log

	local self: any = {}
	-- userId -> { entry, nextAt, saved, inFlight, takeover }
	local slots: { [number]: any } = {}
	local nextScanAt = 0
	local scanning = false

	local function expiry(): number
		return math.floor(cfg.pending.indexExpiryDays * 86400)
	end

	local function backoff(attempts: number): number
		local r = cfg.retry
		return math.min(r.max, r.base * r.factor ^ math.max(0, attempts - 1))
	end

	local function key(userId: number): string
		return `bans/p/{userId}`
	end

	local function writeIndex(userId: number, entry: any): boolean
		local value =
			{ kind = entry.kind, seq = entry.seq, owner = entry.owner, leaseUntil = entry.leaseUntil }
		local ok = map.update(tostring(userId), function(_old: any): any
			return value, entry.at
		end, expiry())
		return ok == true
	end

	local function dropIndex(userId: number, seq: number?)
		local ok, value = map.get(tostring(userId))
		if ok and value ~= nil and (seq == nil or type(value) ~= "table" or (value.seq or 0) <= seq) then
			map.remove(tostring(userId))
		end
	end

	function self.put(userId: number, entry: any): (boolean, boolean)
		local t = now()
		local prior = slots[userId]
		local seq = (if prior then prior.entry.seq or 0 else 0) + 1
		local e = table.clone(entry)
		e.owner = job
		e.leaseUntil = t + cfg.retry.max
		e.attempts = e.attempts or 1
		e.seq = seq
		local saved, new = shared.update(key(userId), function(old: any): any
			local w = table.clone(e)
			if type(old) == "table" and type(old.seq) == "number" and old.seq >= w.seq then
				w.seq = old.seq + 1
			end
			return w
		end)
		if saved and type(new) == "table" then
			e = table.clone(new)
		end
		local indexed = writeIndex(userId, e)
		slots[userId] = {
			entry = e,
			nextAt = t + backoff(e.attempts),
			saved = saved == true,
			inFlight = false,
		}
		return saved == true, indexed
	end

	function self.clear(userId: number)
		local had = slots[userId] ~= nil
		slots[userId] = nil
		local okGet, value = map.get(tostring(userId))
		if had or not okGet or value ~= nil then
			shared.update(key(userId), function(_old: any): any
				return nil
			end)
			if okGet and value ~= nil then
				map.remove(tostring(userId))
			end
		end
	end

	function self.lookup(userId: number): (boolean, any)
		local slot = slots[userId]
		if slot ~= nil then
			return true, slot.entry
		end
		local ok, value = map.get(tostring(userId))
		if not ok then
			return false, nil
		end
		return true, if type(value) == "table" then value else nil
	end

	function self.mine(): { [number]: any }
		local out = {}
		for userId, slot in slots do
			out[userId] = slot.entry
		end
		return out
	end

	local function finish(userId: number, slot: any, entry: any, status: string, note: string?)
		if slots[userId] == slot then
			slots[userId] = nil
		end
		local seq = entry.seq
		shared.update(key(userId), function(old: any): any
			if type(old) == "table" and type(old.seq) == "number" and old.seq > seq then
				return old -- a newer ban/unban replaced it: keep that one
			end
			return nil
		end)
		dropIndex(userId, seq)
		o.done(entry, status, note)
	end

	local function attempt(userId: number)
		local slot = slots[userId]
		if slot == nil or slot.inFlight then
			return
		end
		slot.inFlight = true
		local t = now()
		local current = slot.entry
		local unsaved = not slot.saved
		local ok, new = shared.update(key(userId), function(old: any): any
			if type(old) ~= "table" then
				if unsaved then
					local w = table.clone(current)
					w.owner = job
					w.leaseUntil = t + cfg.retry.max
					return w
				end
				return old
			end
			if old.owner ~= job and (old.leaseUntil or 0) > t then
				return old -- another server holds the lease
			end
			local w = table.clone(old)
			w.owner = job
			w.leaseUntil = t + cfg.retry.max
			w.attempts = (w.attempts or 1) + 1
			return w
		end)
		if slots[userId] ~= slot then
			return -- replaced while the store call yielded
		end
		if ok then
			if type(new) ~= "table" then
				slots[userId] = nil -- finished or undone elsewhere
				dropIndex(userId, current.seq)
				return
			end
			if new.owner ~= job then
				slots[userId] = nil -- the lease holder retries it
				return
			end
			local attempts = (current.attempts or 1) + 1
			current = table.clone(new)
			if unsaved then
				slot.saved = true
				current.attempts = attempts
			end
			slot.entry = current
		else
			if slot.partial then
				-- only the index entry is known; try again later
				slot.inFlight = false
				slot.nextAt = t + backoff(2)
				return
			end
			current = table.clone(current)
			current.attempts = (current.attempts or 1) + 1
			slot.entry = current
		end
		slot.partial = nil
		writeIndex(userId, current)
		local callOk, err = o.call(current)
		if slots[userId] ~= slot then
			return -- a newer ban/unban replaced this one while Roblox answered
		end
		slot.inFlight = false
		local note = if slot.takeover then "Moderation.note.takeover" else nil
		if callOk then
			finish(userId, slot, current, "ok", note)
		elseif not Util.isTransient(err) then
			log.warn(`pending {current.kind} for {userId} failed: {tostring(err)}`)
			finish(userId, slot, current, "failed", note)
		elseif (current.attempts or 1) >= cfg.retry.maxAttempts then
			finish(userId, slot, current, "failed", "Moderation.note.retriesExhausted")
		else
			slot.nextAt = now() + backoff(current.attempts or 1)
		end
	end

	local function scan()
		local ok, rows = map.range("asc", SCAN_COUNT)
		if not ok or type(rows) ~= "table" then
			return
		end
		local t = now()
		for _, row in rows do
			local userId = tonumber(row.key)
			local value = row.value
			if userId == nil or not Util.isCount(userId) or type(value) ~= "table" then
				continue
			end
			local slot = slots[userId]
			if slot ~= nil and (slot.entry.seq or 0) >= (value.seq or 0) then
				continue
			end
			if value.owner == job or (value.leaseUntil or 0) <= t then
				slots[userId] = {
					entry = { kind = value.kind, seq = value.seq, attempts = 1 },
					nextAt = t,
					saved = true,
					inFlight = false,
					partial = true,
					takeover = value.owner ~= job,
				}
			end
		end
	end

	function self.tick()
		local t = now()
		for userId, slot in slots do
			if not slot.inFlight and slot.nextAt <= t then
				task.spawn(attempt, userId)
			end
		end
		if t >= nextScanAt and not scanning then
			nextScanAt = t + cfg.pending.pollSeconds
			scanning = true
			task.spawn(function()
				pcall(scan)
				scanning = false
			end)
		end
	end

	function self.shutdown(deadline: number)
		for userId, slot in slots do
			if os.clock() > deadline then
				return
			end
			if not slot.saved and not slot.partial then
				local e = slot.entry
				local ok = shared.update(key(userId), function(old: any): any
					if type(old) == "table" and (old.seq or 0) >= (e.seq or 0) then
						return old
					end
					return e
				end)
				slot.saved = ok == true
			end
			-- the index keeps the entry (lease runs out) so another server picks it up
			writeIndex(userId, slot.entry)
		end
	end

	return self
end

return Pending
