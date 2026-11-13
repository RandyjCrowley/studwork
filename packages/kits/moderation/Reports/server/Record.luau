--!strict
--[[
	Record: the pure parts of Reports (no ctx, no yields), shared by the server part and its specs.

	  Record.day(now) -> number                         the day index (UTC days since the epoch)
	  Record.newId(target, at) / Record.parseId(id) -> number?   "<target>-<at>": the per-target
	                                                    key r/t/<target> holds at most one open report
	  Record.sentCheck(sent, target, now, limits) -> string?   the reporter's own limits from the
	                                                    durable `sent` list: "reporter_hour" |
	                                                    "reporter_day" | "pair" | nil (allowed)
	  Record.sentAppend(sent, target, now, max) -> { {target, at} }   a new list: entries older than a
	                                                    day dropped, newest `max` kept
	  Record.merge(old, input, opts) -> (new, outcome)  the per-target record after one report;
	                                                    outcome "created" | "merged" | "target_day"
	  Record.distinctSince(rec, since) -> number        distinct reporters whose latest report is at or
	                                                    after `since`
	  Record.sortKey(rec) -> number                     priority: distinct reporters (more first), then at
	  Record.summary(rec) -> table                      the queue index value (no reporter ids, no notes)
	  Record.forViewer(rec, seeReporters) -> Report     the staff view of one record (reporters only with
	                                                    reports.reporters; notes unattributed)
	  Record.context(raw, maxBytes, isKey) -> table?    registered context values: numbers, booleans and
	                                                    declared strings keys only, capped at maxBytes

	A record (the value of r/t/<userId>) = { id, at, lastAt, target, targetName, category, reporters,
	reporterAt, count, distinct, notes, server, placeVersion, context?, status, claimedBy?, day,
	dayCount, autoAt? }. `reporters` and `reporterAt` are parallel lists (latest report per reporter).
]]

local Record = {}

local DAY = 86400
local HOUR = 3600

-- storage caps (the record must stay small: it is read and rewritten whole on every report)
Record.REPORTERS_MAX = 100
Record.NOTES_MAX = 20
-- sort key = distinct reporters * PRIORITY_SCALE + at (unix seconds stay far below the scale)
Record.PRIORITY_SCALE = 1e10

function Record.day(now: number): number
	return math.floor(now / DAY)
end

function Record.newId(target: number, at: number): string
	return `{math.floor(target)}-{math.floor(at)}`
end

function Record.parseId(id: any): number?
	if type(id) ~= "string" or #id > 40 then
		return nil
	end
	local target = string.match(id, "^(%d+)%-%d+$")
	if target == nil then
		return nil
	end
	local n = tonumber(target)
	if n == nil or n < 1 then
		return nil
	end
	return n
end

export type Limits = {
	perReporterPerHour: number,
	perReporterPerDay: number,
	perPairPerDay: number,
	perTargetPerDay: number,
	sentMax: number,
}

function Record.sentCheck(sent: { any }?, target: number, now: number, limits: Limits): string?
	local hour, day, pair = 0, 0, 0
	for _, entry in (sent or {}) :: { any } do
		if type(entry) == "table" and type(entry.at) == "number" then
			local age = now - entry.at
			if age < DAY then
				day += 1
				if age < HOUR then
					hour += 1
				end
				if entry.target == target then
					pair += 1
				end
			end
		end
	end
	if hour >= limits.perReporterPerHour then
		return "reporter_hour"
	end
	if day >= limits.perReporterPerDay then
		return "reporter_day"
	end
	if pair >= limits.perPairPerDay then
		return "pair"
	end
	return nil
end

function Record.sentAppend(sent: { any }?, target: number, now: number, max: number): { any }
	local out = {}
	for _, entry in (sent or {}) :: { any } do
		if type(entry) == "table" and type(entry.at) == "number" and now - entry.at < DAY then
			table.insert(out, { target = entry.target, at = entry.at })
		end
	end
	table.insert(out, { target = target, at = now })
	while #out > max do
		table.remove(out, 1)
	end
	return out
end

export type Input = {
	reporter: number,
	target: number,
	targetName: string,
	category: string,
	note: string?,
	now: number,
	server: string,
	placeVersion: number,
	context: { [string]: any }?,
}

export type MergeOpts = {
	perTargetPerDay: number,
	staleSeconds: number, -- an open record older than this (its index entry expired) starts over
}

local function copyList(list: any): { any }
	local out = {}
	if type(list) == "table" then
		for _, v in list do
			table.insert(out, v)
		end
	end
	return out
end

local function fresh(input: Input): any
	return {
		id = Record.newId(input.target, input.now),
		at = input.now,
		lastAt = input.now,
		target = input.target,
		targetName = input.targetName,
		category = input.category,
		reporters = { input.reporter },
		reporterAt = { input.now },
		count = 1,
		distinct = 1,
		notes = if input.note ~= nil then { input.note } else {},
		server = input.server,
		placeVersion = input.placeVersion,
		context = input.context,
		status = "open",
		day = Record.day(input.now),
		dayCount = 1,
	}
end

-- `old` is the stored record (frozen or not; never mutated). Returns a new table.
function Record.merge(old: any, input: Input, opts: MergeOpts): (any, string)
	if
		type(old) ~= "table"
		or old.status == "resolved"
		or type(old.lastAt) ~= "number"
		or input.now - old.lastAt >= opts.staleSeconds
	then
		return fresh(input), "created"
	end
	local today = Record.day(input.now)
	local dayCount = if old.day == today then (old.dayCount or 0) else 0
	if dayCount >= opts.perTargetPerDay then
		return old, "target_day"
	end
	local new = table.clone(old)
	new.reporters = {}
	new.reporterAt = {}
	-- (Addendum G) reporter ids older than staleSeconds are dropped on every write
	local oldReporters, oldAt = copyList(old.reporters), copyList(old.reporterAt)
	for i, id in oldReporters do
		local at = oldAt[i]
		if type(at) == "number" and input.now - at < opts.staleSeconds then
			table.insert(new.reporters, id)
			table.insert(new.reporterAt, at)
		end
	end
	new.notes = copyList(old.notes)
	-- (fix 2) a rank stored by an older build is never a known rank: dropped on the next write
	new.targetRank = nil
	local index = table.find(new.reporters, input.reporter)
	if index ~= nil then
		new.reporterAt[index] = input.now
	else
		table.insert(new.reporters, input.reporter)
		table.insert(new.reporterAt, input.now)
		while #new.reporters > Record.REPORTERS_MAX do
			table.remove(new.reporters, 1)
			table.remove(new.reporterAt, 1)
		end
		new.distinct = (old.distinct or #copyList(old.reporters)) + 1
	end
	if input.note ~= nil and #new.notes < Record.NOTES_MAX then
		table.insert(new.notes, input.note)
	end
	new.count = (old.count or 0) + 1
	new.lastAt = input.now
	new.day = today
	new.dayCount = dayCount + 1
	if input.targetName ~= "" then
		new.targetName = input.targetName
	end
	return new, "merged"
end

function Record.distinctSince(rec: any, since: number): number
	local n = 0
	if type(rec) == "table" and type(rec.reporterAt) == "table" then
		for _, at in rec.reporterAt do
			if type(at) == "number" and at >= since then
				n += 1
			end
		end
	end
	return n
end

function Record.sortKey(rec: any): number
	return (rec.distinct or 1) * Record.PRIORITY_SCALE + (rec.at or 0)
end

function Record.summary(rec: any): any
	return {
		id = rec.id,
		at = rec.at,
		lastAt = rec.lastAt,
		target = rec.target,
		targetName = rec.targetName,
		category = rec.category,
		count = rec.count,
		distinct = rec.distinct,
		status = rec.status,
		claimedBy = rec.claimedBy,
	}
end

function Record.forViewer(rec: any, seeReporters: boolean): any
	local context = nil
	if type(rec.context) == "table" then
		context = table.clone(rec.context)
	end
	return {
		id = rec.id,
		at = rec.at,
		target = rec.target,
		targetName = rec.targetName,
		category = rec.category,
		reporters = if seeReporters then copyList(rec.reporters) else {},
		count = rec.count,
		distinct = rec.distinct,
		notes = copyList(rec.notes),
		server = rec.server,
		placeVersion = rec.placeVersion,
		context = context,
		status = rec.status,
		claimedBy = rec.claimedBy,
	}
end

local function cellSize(key: string, value: any): number
	return #key + #tostring(value) + 4
end

function Record.context(raw: any, maxBytes: number, isKey: (string) -> boolean): { [string]: any }?
	if type(raw) ~= "table" then
		return nil
	end
	local keys = {}
	for k in raw do
		if type(k) == "string" and #k >= 1 and #k <= 64 then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	local out: { [string]: any } = {}
	local used, any = 2, false
	for _, k in keys do
		local v = raw[k]
		local ok = (type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge)
			or type(v) == "boolean"
			or (type(v) == "string" and isKey(v))
		if ok then
			local size = cellSize(k, v)
			if used + size <= maxBytes then
				out[k] = v
				used += size
				any = true
			end
		end
	end
	return if any then out else nil
end

return Record
