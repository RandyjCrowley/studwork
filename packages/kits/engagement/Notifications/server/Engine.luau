--!strict
--[[
	Notifications engine (docs/framework/kits/notifications.md, "Scheduled sends" and "Failure and budget
	behaviour"): sends through ctx.openCloud, the due list and the per-recipient ledger on sharded
	sorted maps, claims, retries and the poll. No player objects: everything is keyed by userId, so it
	works for recipients on no server.

	  Engine.new(ctx, templates, opts) -> engine
	    opts = { jobId, onSent(userId, templateKey), onFailed(userId, templateKey, reason),
	             offsetOf(userId) -> number? (the recipient's reported UTC offset, when known) }

	  engine.send(userId, tpl, params?, key?) -> (ok, reason?)
	  engine.schedule(userId, tpl, at, params?, key?, offset?) -> (ok, reason?)
	  engine.cancel(userId, key) -> boolean
	  engine.cancelWhere(userId, predicate(templateKey) -> boolean) -> number
	  engine.noteOffset(userId, hours)     refreshes the offset in the recipient's ledger entry, if any
	  engine.poll()                        one poll of the next shard (yields)
	  engine.pollInterval() -> seconds     max(pollSeconds, 60 x servers / (shards x pollsPerShardPerMinute))
	  engine.enabled() -> boolean          the kill-switch flag
	  engine.secretProblem() -> string?    nil, "not_allowed" or "no_secret" (logged once)
	  engine.startCursor(n)                the shard the next poll reads

	Store reasons: "memory_budget" (the module's memory share is full) and "store_busy" (anything else).
]]

local Ledger = require(script.Parent.Ledger)
local Quiet = require(script.Parent.Quiet)
local Sender = require(script.Parent.Sender)
local Templates = require(script.Parent.Templates)

local Engine = {}

local HOUR = 3600

local function storeReason(reason: any): string
	if reason == "memory_budget" or reason == "memory_full" then
		return "memory_budget"
	end
	return "store_busy"
end

function Engine.new(ctx: any, templates: { [string]: Templates.Template }, opts: any): any
	local cfg = ctx.config
	local jobId: string = opts.jobId
	local staleSeconds: number = cfg.schedule.staleAfterHours * HOUR
	local leaseSeconds: number = cfg.schedule.leaseSeconds
	local shards: number = cfg.schedule.shards
	local self: any = {}

	local holdSeconds = 0
	for _, tpl in templates do
		holdSeconds = math.max(holdSeconds, tpl.cooldownHours * HOUR)
	end
	local rules: Ledger.Rules = {
		perDay = cfg.limits.perPlayerPerDay,
		minGapSeconds = cfg.limits.minGapHours * HOUR,
		cooldownSeconds = 0,
	}

	local maps: { [string]: any } = {}
	local function mapFor(kind: string, userId: number): any
		local name = `{kind}/{userId % shards}`
		local m = maps[name]
		if m == nil then
			m = ctx.data.sortedMap(name)
			maps[name] = m
		end
		return m
	end
	local function dueKey(userId: number, key: string): string
		return `{userId}/{key}`
	end

	local logged: { [string]: boolean } = {}
	local function logOnce(id: string, message: string)
		if not logged[id] then
			logged[id] = true
			ctx.log.info(message)
		end
	end

	function self.enabled(): boolean
		local flag = cfg.flag
		if flag == nil then
			return true
		end
		local ok, on = pcall(ctx.flags.isOn, flag)
		if not ok then
			logOnce(
				"flag",
				`flag '{tostring(flag)}' is not declared in GameConfig.flags: the module stays off`
			)
			return false
		end
		return on == true
	end

	-- This server's own request rate (the page's limits.perServerPerMinute).
	local window, used = -math.huge, 0
	local function takeBudget(): boolean
		local now = ctx.now()
		if now - window >= 60 then
			window, used = now, 0
		end
		if used >= cfg.limits.perServerPerMinute then
			return false
		end
		used += 1
		return true
	end

	-- The recipient's offset: the due entry's, else theirs if they are on this server, else the one in
	-- their ledger entry (H: offline recipients), else quiet.defaultUtcOffsetHours.
	local function offsetFor(userId: number, entryOffset: any, ledgerOffset: any): number
		local known = if entryOffset ~= nil then entryOffset else opts.offsetOf(userId)
		if known == nil then
			known = ledgerOffset
		end
		return Quiet.offset(known, cfg.quiet.defaultUtcOffsetHours)
	end

	local function inQuiet(now: number, offset: number): boolean
		return Quiet.inQuiet(now, offset, cfg.quiet.startHour, cfg.quiet.endHour)
	end

	local function dueExpiry(at: number, now: number): number
		return math.clamp(math.ceil(at + staleSeconds - now), Ledger.MIN_EXPIRY, Ledger.MAX_EXPIRY)
	end

	--------------------------------------------------------------------------
	-- Ledger: one atomic update per call. The expiry has to be known before the call, so it is read
	-- first; if another server added a later waiting entry in between, the update cancels itself and
	-- we go round again (at most three times). Every write made while the recipient is on this server
	-- stamps their offset (`o`), so other servers can keep to their quiet hours once they leave.
	-- `onlyIfExists`: write nothing when the recipient has no entry.
	--------------------------------------------------------------------------
	local function ledgerUpdate(
		userId: number,
		extraAt: number?,
		fn: (Ledger.Entry, number) -> (Ledger.Entry?, any?),
		onlyIfExists: boolean?
	): (boolean, any)
		local map = mapFor("ledger", userId)
		local key = tostring(userId)
		local known = opts.offsetOf(userId)
		for _ = 1, 3 do
			local gok, got = map.get(key)
			if not gok then
				return false, storeReason(got)
			end
			if onlyIfExists and type(got) ~= "table" then
				return true, nil
			end
			local expiry = Ledger.expiry(Ledger.normalize(got), extraAt, ctx.now(), staleSeconds, holdSeconds)
			local short = false
			local info: any = nil
			local uok, res = map.update(key, function(old: any): any
				short = false
				info = nil
				if onlyIfExists and type(old) ~= "table" then
					return nil
				end
				local e = Ledger.normalize(old)
				local t = ctx.now()
				if Ledger.expiry(e, extraAt, t, staleSeconds, holdSeconds) > expiry then
					short = true
					return nil
				end
				local new, extra = fn(e, t)
				info = extra
				if new ~= nil and known ~= nil then
					new.o = known
				end
				return new
			end, expiry)
			if not uok then
				return false, storeReason(res)
			end
			if not short then
				return true, info
			end
		end
		return false, "store_busy"
	end

	local function release(userId: number, key: string?, dropKey: boolean)
		return ledgerUpdate(userId, nil, function(e: Ledger.Entry)
			return Ledger.release(e, jobId, key, dropKey), nil
		end)
	end

	-- Reserves the recipient for one send, or says when it is allowed: (true) | (false, reason, nextAt?).
	-- "quiet": it is inside the recipient's quiet hours (their offset as offsetFor finds it, the ledger's
	-- included); nextAt is when they end.
	local function reserve(
		userId: number,
		tpl: Templates.Template,
		entryOffset: any
	): (boolean, string?, number?)
		local ok, info = ledgerUpdate(userId, nil, function(e: Ledger.Entry, t: number)
			local offset = offsetFor(userId, entryOffset, e.o)
			if inQuiet(t, offset) then
				return nil,
					{
						reason = "quiet",
						nextAt = Quiet.nextOpen(t, offset, cfg.quiet.startHour, cfg.quiet.endHour),
					}
			end
			local localRules = table.clone(rules)
			localRules.cooldownSeconds = tpl.cooldownHours * HOUR
			local allowed, nextAt, why = Ledger.check(e, tpl.key, localRules, t, jobId)
			if not allowed then
				return nil, { reason = why, nextAt = nextAt }
			end
			return Ledger.reserve(e, jobId, t, leaseSeconds), nil
		end)
		if not ok then
			return false, info, nil
		end
		if info ~= nil then
			return false, info.reason, info.nextAt
		end
		return true, nil, nil
	end

	--------------------------------------------------------------------------
	-- Due list
	--------------------------------------------------------------------------
	local function dueSet(userId: number, key: string, value: any, sortKey: number): (boolean, string?)
		local ok, res = mapFor("due", userId).update(dueKey(userId, key), function(): any
			return value, sortKey
		end, dueExpiry(value.at, ctx.now()))
		if not ok then
			return false, storeReason(res)
		end
		return true, nil
	end

	local function dueRemove(userId: number, key: string)
		mapFor("due", userId).remove(dueKey(userId, key))
	end

	-- Moves a claimed entry to `sortKey`, optionally changing its value. Only the claim holder may.
	local function dueMove(
		userId: number,
		key: string,
		sortKey: number,
		at: number,
		mutate: ((any) -> any)?
	): boolean
		local moved = false
		local ok = mapFor("due", userId).update(dueKey(userId, key), function(old: any, _oldSort: any): any
			moved = false
			if type(old) ~= "table" or old.c ~= jobId then
				return nil
			end
			local new = table.clone(old)
			new.c = nil
			if mutate then
				new = mutate(new)
			end
			moved = true
			return new, sortKey
		end, dueExpiry(at, ctx.now()))
		return ok and moved
	end

	-- A claimed entry is finished, stale or unknown: it leaves both the due list and the ledger.
	local function dropEntry(userId: number, key: string)
		dueRemove(userId, key)
		release(userId, key, true)
	end

	-- Re-keys a claimed entry to `nextAt`, or drops it when that is past its stale time.
	local function rekeyOrDrop(userId: number, key: string, value: any, nextAt: number, reserved: boolean)
		if nextAt > value.at + staleSeconds then
			dropEntry(userId, key)
			return
		end
		if reserved then
			release(userId, key, false)
		end
		dueMove(userId, key, nextAt, value.at, nil)
	end

	local function claim(userId: number, row: any): boolean
		local won = false
		local now = ctx.now()
		local value = row.value
		local ok = mapFor("due", userId).update(row.key, function(old: any, oldSort: any): any
			won = false
			if type(old) ~= "table" or type(oldSort) ~= "number" or oldSort > ctx.now() then
				return nil
			end
			local new = table.clone(old)
			new.c = jobId
			won = true
			return new, ctx.now() + leaseSeconds
		end, dueExpiry(if type(value) == "table" and type(value.at) == "number" then value.at else now, now))
		return ok and won
	end

	--------------------------------------------------------------------------
	-- Sending
	--------------------------------------------------------------------------
	local function request(
		userId: number,
		tpl: Templates.Template,
		params: { [string]: any }
	): (string, string?)
		local body = Templates.body(tpl, params, ctx.env.universeId())
		local ok, status, reason = ctx.openCloud.request({
			secret = cfg.secret,
			method = "POST",
			path = `users/{userId}/notifications`,
			body = body,
		})
		return Sender.classify(ok, status, reason), if type(reason) == "string" then reason else nil
	end

	-- nil when the secret is usable; else "not_allowed" (ServerConfig.openCloud has no entry for this
	-- module) or "no_secret" (no such secret, HTTP off, a local Studio playtest), logged once. Both
	-- answers come back without a request being made.
	function self.secretProblem(): string?
		if ctx.openCloud.available(cfg.secret) then
			return nil
		end
		local _, _, why = ctx.openCloud.request({
			secret = cfg.secret,
			method = "POST",
			path = "users/0/notifications",
		})
		logOnce(
			"secret",
			`Notifications: secret '{cfg.secret}' is unavailable ({tostring(why)}); sends return that until it is set up (see the page's Setup)`
		)
		return if why == "not_allowed" then "not_allowed" else "no_secret"
	end

	-- Why this send can't go out at all (nothing reserved yet): a reason, or nil.
	local function blocked(userId: number, tpl: Templates.Template): string?
		if not self.enabled() then
			return "disabled"
		end
		if tpl.placeholder then
			logOnce(
				"placeholder:" .. tpl.key,
				`template '{tpl.key}' has messageId = "": limits and scheduling run, nothing is sent`
			)
			return "placeholder"
		end
		if ctx.isStudio and not cfg.sendInStudio then
			ctx.log.info(`would send {tpl.key} to {userId}`)
			return "studio"
		end
		return self.secretProblem()
	end

	-- After the request: ledger, due list and hooks. `value` is the claimed due entry (nil for an
	-- immediate send). Returns what `send` returns.
	local function finish(
		userId: number,
		tpl: Templates.Template,
		key: string,
		params: { [string]: any },
		value: any,
		outcome: string,
		why: string?
	): (boolean, string?)
		local now = ctx.now()
		local fromDue = value ~= nil
		local dueAt: number = if fromDue then value.at else now
		if outcome == "sent" then
			local ok = ledgerUpdate(userId, nil, function(e: Ledger.Entry, t: number)
				return Ledger.commit(e, key, tpl.key, t), nil
			end)
			if not ok then
				ctx.log.warn(`ledger write after an accepted send of {tpl.key} did not land`)
			end
			if fromDue then
				dueRemove(userId, key)
			end
			opts.onSent(userId, tpl.key)
			return true, nil
		elseif outcome == "refused" then
			release(userId, key, true)
			if fromDue then
				dueRemove(userId, key)
			end
			opts.onFailed(userId, tpl.key, "refused")
			return false, "refused"
		elseif outcome == "retry" then
			local n = (if fromDue and type(value.n) == "number" then value.n else 0) + 1
			local nextAt = now + Sender.backoff(cfg.retry, n)
			if n >= cfg.retry.attempts or nextAt > dueAt + staleSeconds then
				release(userId, key, true)
				if fromDue then
					dueRemove(userId, key)
				end
				opts.onFailed(userId, tpl.key, "failed")
				return false, "failed"
			end
			local ok, info = ledgerUpdate(userId, dueAt, function(e: Ledger.Entry)
				local r = Ledger.release(e, jobId, key, false)
				if not fromDue and r.q[key] == nil and Ledger.waiting(r) >= cfg.schedule.maxPerPlayer then
					return nil, { refused = true }
				end
				r.q[key] = dueAt
				return r, nil
			end)
			if fromDue then
				dueMove(userId, key, nextAt, dueAt, function(new: any): any
					new.n = n
					return new
				end)
				return true, "queued"
			end
			if not ok or (info ~= nil and info.refused) then
				opts.onFailed(userId, tpl.key, "failed")
				return false, "failed"
			end
			local entry: { [string]: any } = { k = tpl.key, at = dueAt, n = n }
			if next(params) ~= nil then
				entry.p = params
			end
			local offset = opts.offsetOf(userId)
			if offset ~= nil then
				entry.o = offset
			end
			local dok = dueSet(userId, key, entry, nextAt)
			if not dok then
				release(userId, key, true)
				opts.onFailed(userId, tpl.key, "failed")
				return false, "failed"
			end
			return true, "queued"
		end
		-- "budget" (this server's Open Cloud rate) and "unavailable" (a setup problem): nothing was
		-- sent and nothing counts; the reservation is given back and a due entry waits
		release(userId, key, false)
		if fromDue then
			local wait = if outcome == "budget" then cfg.retry.base else cfg.retry.max
			dueMove(userId, key, now + wait, dueAt, nil)
		end
		return false, if outcome == "budget" then "server_budget" else why
	end

	function self.send(
		userId: number,
		tpl: Templates.Template,
		params: { [string]: any },
		key: string?
	): (boolean, string?)
		if tpl.placeholder and self.enabled() then
			-- limits run as usual for a placeholder: read-only, nothing is reserved or counted
			local gok, got = mapFor("ledger", userId).get(tostring(userId))
			if gok then
				local localRules = table.clone(rules)
				localRules.cooldownSeconds = tpl.cooldownHours * HOUR
				local allowed, _, limit =
					Ledger.check(Ledger.normalize(got), tpl.key, localRules, ctx.now(), jobId)
				if not allowed then
					return false, limit
				end
			end
		end
		local why = blocked(userId, tpl)
		if why ~= nil then
			return false, why
		end
		local now = ctx.now()
		local sendKey = key or tpl.key
		local function deferTo(at: number): (boolean, string?)
			local ok, reason = self.schedule(userId, tpl, at, params, sendKey, nil)
			if ok then
				return true, "scheduled"
			end
			return false, reason
		end
		local online = opts.offsetOf(userId)
		if online ~= nil then
			local offset = offsetFor(userId, nil, nil)
			if inQuiet(now, offset) then
				return deferTo(Quiet.nextOpen(now, offset, cfg.quiet.startHour, cfg.quiet.endHour))
			end
		end
		if not takeBudget() then
			return false, "server_budget"
		end
		-- a recipient on no server: reserve checks quiet hours with the offset in their ledger entry
		local ok, reason, nextAt = reserve(userId, tpl, nil)
		if not ok then
			if reason == "quiet" and nextAt ~= nil then
				used -= 1 -- nothing was requested
				return deferTo(nextAt)
			end
			return false, reason
		end
		local outcome, detail = request(userId, tpl, params)
		return finish(userId, tpl, sendKey, params, nil, outcome, detail)
	end

	function self.schedule(
		userId: number,
		tpl: Templates.Template,
		at: number,
		params: { [string]: any },
		key: string?,
		offsetArg: number?
	): (boolean, string?)
		if not self.enabled() then
			return false, "disabled"
		end
		local now = ctx.now()
		if at > now + cfg.schedule.maxAheadHours * HOUR then
			return false, "too_far"
		end
		at = math.max(at, now)
		local scheduleKey = key or tpl.key
		local ledgerOffset: number? = nil
		local ok, info = ledgerUpdate(userId, at, function(e: Ledger.Entry, t: number)
			ledgerOffset = e.o
			local new, why = Ledger.schedule(e, scheduleKey, at, t, cfg.schedule.maxPerPlayer, staleSeconds)
			if new == nil then
				return nil, { reason = why }
			end
			return new, nil
		end)
		if not ok then
			return false, info
		end
		if info ~= nil then
			return false, info.reason
		end
		local entry: { [string]: any } = { k = tpl.key, at = at }
		if next(params) ~= nil then
			entry.p = params
		end
		local offset = if offsetArg ~= nil then offsetArg else opts.offsetOf(userId)
		if offset == nil then
			offset = ledgerOffset
		end
		if offset ~= nil then
			entry.o = offset
		end
		local dok, dreason = dueSet(userId, scheduleKey, entry, at)
		if not dok then
			ledgerUpdate(userId, nil, function(e: Ledger.Entry)
				local back = Ledger.cancel(e, scheduleKey)
				return back, nil
			end)
			return false, dreason
		end
		return true, nil
	end

	function self.cancel(userId: number, key: string): boolean
		local ok, existed = ledgerUpdate(userId, nil, function(e: Ledger.Entry)
			local new, had = Ledger.cancel(e, key)
			return new, had
		end)
		if not ok then
			return false
		end
		dueRemove(userId, key)
		return existed == true
	end

	-- Records a recipient's reported offset in their ledger entry. Only an entry that exists: one isn't
	-- created just for this (memory). One read when there is nothing to change.
	function self.noteOffset(userId: number, hours: number)
		local gok, got = mapFor("ledger", userId).get(tostring(userId))
		if not gok or type(got) ~= "table" or got.o == hours then
			return
		end
		ledgerUpdate(userId, nil, function(e: Ledger.Entry)
			e.o = hours
			return e, nil
		end, true)
	end

	-- Cancels every waiting entry of this recipient whose template satisfies `predicate`.
	function self.cancelWhere(userId: number, predicate: (string) -> boolean): number
		local gok, got = mapFor("ledger", userId).get(tostring(userId))
		if not gok or type(got) ~= "table" or type(got.q) ~= "table" then
			return 0
		end
		local cancelled = 0
		for key in got.q do
			if type(key) ~= "string" then
				continue
			end
			local dok, entry = mapFor("due", userId).get(dueKey(userId, key))
			if dok and type(entry) == "table" and type(entry.k) == "string" and predicate(entry.k) then
				if self.cancel(userId, key) then
					cancelled += 1
				end
			end
		end
		return cancelled
	end

	--------------------------------------------------------------------------
	-- Polling
	--------------------------------------------------------------------------
	local studioSkip = ctx.isStudio and not cfg.sendInStudio

	-- Returns "stop" when this server's budget is spent.
	local function processRow(row: any): string?
		local userIdText, key = string.match(tostring(row.key), "^(%d+)/(.+)$")
		local value = row.value
		if userIdText == nil or key == nil then
			return nil
		end
		local userId = tonumber(userIdText) :: number
		if type(value) ~= "table" or type(value.at) ~= "number" or type(value.k) ~= "string" then
			dropEntry(userId, key)
			return nil
		end
		local now = ctx.now()
		if value.at + staleSeconds < now then
			dropEntry(userId, key)
			return nil
		end
		local tpl = templates[value.k]
		if tpl == nil then
			dropEntry(userId, key)
			return nil
		end
		local completes = tpl.placeholder or studioSkip
		if not completes and self.secretProblem() ~= nil then
			-- no key (or no allow-list entry): leave the window so the entries behind aren't starved
			if claim(userId, row) then
				dueMove(userId, key, now + cfg.retry.max, value.at, nil)
			end
			return nil
		end
		if not completes and used >= cfg.limits.perServerPerMinute and now - window < 60 then
			return "stop"
		end
		if not claim(userId, row) then
			return nil
		end
		-- the offset known here (the entry's, or the recipient on this server); otherwise reserve checks
		-- quiet hours with the one in their ledger entry
		local known = value.o ~= nil or opts.offsetOf(userId) ~= nil
		local offset = offsetFor(userId, value.o, nil)
		if (known or completes) and inQuiet(now, offset) then
			rekeyOrDrop(
				userId,
				key,
				value,
				Quiet.nextOpen(now, offset, cfg.quiet.startHour, cfg.quiet.endHour),
				false
			)
			return nil
		end
		if completes then
			if tpl.placeholder then
				logOnce(
					"placeholder:" .. tpl.key,
					`template '{tpl.key}' has messageId = "": limits and scheduling run, nothing is sent`
				)
			else
				ctx.log.info(`would send {tpl.key} to {userId}`)
			end
			dropEntry(userId, key)
			return nil
		end
		local ok, _, nextAt = reserve(userId, tpl, value.o)
		if not ok then
			-- a limit says when the recipient is next allowed; a store problem leaves the claim to lapse
			-- after leaseSeconds, when any server tries again
			if nextAt ~= nil then
				rekeyOrDrop(userId, key, value, nextAt, false)
			end
			return nil
		end
		takeBudget()
		local params: { [string]: any } = if type(value.p) == "table" then value.p else {}
		local outcome, detail = request(userId, tpl, params)
		finish(userId, tpl, key, params, value, outcome, detail)
		return nil
	end

	local cursor = 0
	local polling = false

	function self.startCursor(n: number)
		cursor = n % shards
	end

	local function pollShard(shard: number)
		local map = mapFor("due", shard)
		local rok, rows = map.range("asc", cfg.schedule.batch, nil, { sortKey = math.floor(ctx.now()) + 1 })
		if not rok then
			return -- throttled or over budget: the due list keeps; this poll is skipped
		end
		for _, row in rows do
			if processRow(row) == "stop" then
				break
			end
		end
	end

	function self.poll()
		if polling or not self.enabled() then
			return
		end
		polling = true
		local shard = cursor
		cursor = (cursor + 1) % shards
		local ok, err = pcall(pollShard :: any, shard)
		polling = false
		if not ok then
			ctx.log.warn(`due poll error: {tostring(err)}`)
		end
	end

	function self.pollInterval(): number
		local interval: number = cfg.schedule.pollSeconds
		local census = ctx.data.census()
		if census ~= nil and type(census.servers) == "number" and census.servers > 0 then
			interval =
				math.max(interval, 60 * census.servers / (shards * cfg.schedule.pollsPerShardPerMinute))
		end
		return interval
	end

	return self
end

return Engine
