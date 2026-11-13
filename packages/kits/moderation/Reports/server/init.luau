--!strict
--[[
	Reports: the server part (docs/framework/kits/moderation.md "Reports", design §5, §8-§10).

	  api: submit, queue, detail, claim, resolve, registerContext, signals Submitted(reportId,
	       targetUserId, category) / Resolved(reportId, resolution) (never a reporter id)
	  extensions: registerContext (same function, for init)
	  actions (net.blink): submit(targetUserId, category, note?) -> a feedback toast; a refused
	       report looks exactly like an accepted one to the reporter ("Reports.thanks")

	Storage:
	  save section `reports` (the reporter's own): sent = { { target, at } } (durable reporter limits)
	  ctx.data.shared  r/t/<userId>     the merged open report about one target (./Record.luau)
	  sortedMap "queue" key <userId>    a small summary (no reporter ids, no notes); sort key =
	                                    priority (distinct reporters, then at); expiry
	                                    queue.indexExpiryDays, renewed on every write to the report
	Resolved reports keep no key: the resolution is an audit entry (Moderation.record, no reporter
	ids) and the per-target key and its index entry are cleared.

	Staff calls (queue, detail, claim, resolve) need `opts.by` (./Actor.luau). A staff Player is
	checked with Admin.allow (reports.read / reports.resolve) when Admin is enabled; with Admin off
	only Studio or a user id in ServerConfig.Reports.admins. A staff viewer never sees a report whose
	target is themselves or staff of equal or higher rank; reporter ids only with reports.reporters.

	The module is a factory (`new`): one part per runtime, `part.net` swappable in specs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Actor = require(script.Actor)
local Record = require(script.Record)
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Admin = require(Modules:WaitForChild("Admin"):WaitForChild("module"))
local Moderation = require(Modules:WaitForChild("Moderation"):WaitForChild("module"))
local TextFilter = require(Modules:WaitForChild("TextFilter"):WaitForChild("module"))

local DAY = 86400
local RESOLUTIONS = table.freeze({ "actioned", "no_action", "dismissed" })
local RESOLVE_NOTES = table.freeze({
	"Reports.resolveNote.actioned",
	"Reports.resolveNote.noViolation",
	"Reports.resolveNote.duplicate",
	"Reports.resolveNote.insufficient",
})
local STATUSES = table.freeze({ "open", "claimed" })

-- operational sizes (not balance): sorted-map page, recently-left list, the Admin tab
local PAGE = 200 -- Roblox's range maximum
local RECENT_MAX = 50
local PRUNE_SECONDS = 5
local COUNT_CACHE_SECONDS = 60 -- how long a queue count is trusted before maxOpen re-counts
local TAB_ROWS = 20
local TAB_DETAILS = 3 -- full records read per tab page (the viewer's own claims only)
local TAB_CALLS = 2 -- index range reads per tab fetch, whatever queue.maxOpen is (fix 2)
local TAB_WALK_SECONDS = 30 -- how long a staff member's index walk is resumed by their next pages
local QUEUE_DEFAULT = 50

local Server = {}

Server.Actor = Actor
Server.Record = Record
Server.RESOLUTIONS = RESOLUTIONS
Server.RESOLVE_NOTES = RESOLVE_NOTES

local function isCategoryId(v: any): boolean
	return type(v) == "string" and #v >= 1 and #v <= 32 and string.match(v, "^[%w_]+$") ~= nil
end

-- config checks the schema language can't express -> { string }
function Server.check(cfg: any, serverConfig: any?): { string }
	local errors: { string } = {}
	if #cfg.categories == 0 then
		table.insert(errors, "config.Reports.categories: needs at least one category")
	end
	local seen: { [string]: boolean } = {}
	for i, id in cfg.categories do
		if not isCategoryId(id) then
			table.insert(errors, `config.Reports.categories[{i}]: 1..32 letters, digits or _`)
		elseif seen[id] then
			table.insert(errors, `config.Reports.categories: '{id}' is listed twice`)
		end
		seen[id] = true
	end
	if cfg.limits.perReporterPerHour > cfg.limits.perReporterPerDay then
		table.insert(errors, "config.Reports.limits.perReporterPerHour: more than perReporterPerDay")
	end
	if cfg.limits.perReporterPerDay > cfg.limits.sentMax then
		table.insert(
			errors,
			"config.Reports.limits.perReporterPerDay: more than limits.sentMax (the durable list can't hold a day)"
		)
	end
	local sc = serverConfig
	if type(sc) == "table" and sc.admins ~= nil then
		local ok = type(sc.admins) == "table"
		if ok then
			for _, id in sc.admins do
				if type(id) ~= "number" or id < 1 or id ~= math.floor(id) then
					ok = false
				end
			end
		end
		if not ok then
			table.insert(errors, "ServerConfig.Reports.admins: a list of user ids")
		end
	end
	return errors
end

local function serverId(): string
	local ok, id = pcall(function(): any
		return (game :: any).JobId
	end)
	if ok and type(id) == "string" and id ~= "" then
		return id
	end
	return "studio"
end

local function placeVersion(): number
	local ok, v = pcall(function(): any
		return (game :: any).PlaceVersion
	end)
	return if ok and type(v) == "number" then v else 0
end

local function looksLikeKey(s: string): boolean
	return #s <= 100 and string.match(s, "^[%a][%w_]*%.[%w_.]+$") ~= nil
end

function Server.new(): any
	local ctx: any = nil
	local part: any = {}
	local created: { [string]: any } = {}
	local contexts: { (number, any) -> any } = {}
	local online: { [number]: any } = {}
	local recent: { { userId: number, name: string, at: number } } = {}
	local stats: { [string]: number } = {}
	local map: any = nil
	-- per staff user id: their Reports tab walk (fix 2), resumed by their next pages
	local tabWalks: { [number]: any } = {}
	-- the maxOpen count cache (M15)
	local cachedCount, createdSince, scannedAt = 0, 0, nil :: number?

	local adminOn, moderationOn, filterOn = false, false, false

	-- api.signals is copied by the framework before init: a proxy (kept by identity) that serves
	-- the signals init creates with ctx.signals.new.
	local signals = setmetatable({}, {
		__index = function(_, key: any): any
			return created[key]
		end,
	})

	local function count(what: string)
		stats[what] = (stats[what] or 0) + 1
	end

	local function isOn(): boolean
		local flag = ctx.config.flag
		if flag == nil then
			return true
		end
		local ok, on = pcall(ctx.flags.isOn, flag)
		return ok and on == true
	end

	local function expiry(): number
		return math.floor(ctx.config.queue.indexExpiryDays * DAY)
	end

	local function key(target: number): string
		return `r/t/{math.floor(target)}`
	end

	---------------------------------------------------------------------------------------------
	-- permissions and the viewer rules
	---------------------------------------------------------------------------------------------

	local function fallbackList(): { number }
		local sc = ctx.serverConfig
		if type(sc) == "table" and type(sc.admins) == "table" then
			return sc.admins
		end
		return {}
	end

	local function fallbackAdmin(player: any): boolean
		return ctx.isStudio == true or table.find(fallbackList(), player.UserId) ~= nil
	end

	-- (ok, reason?): a staff Player through Admin.allow (counts Admin's per-staff limits)
	local function permit(by: any, kind: string, permission: string): (boolean, string?)
		if Actor.isTrusted(kind) then
			return true, nil
		end
		if kind ~= "staff" then
			return false, "no_permission"
		end
		if adminOn then
			local ok, allowed, why = pcall(ctx.deps[Admin].allow, by, permission)
			if not ok then
				return false, "no_permission"
			end
			if allowed == true then
				return true, nil
			end
			return false, why or "no_permission"
		end
		if fallbackAdmin(by) then
			return true, nil
		end
		return false, "no_permission"
	end

	local function seesReporters(by: any, kind: string): boolean
		if Actor.isTrusted(kind) then
			return true
		end
		if kind ~= "staff" then
			return false
		end
		if adminOn then
			local ok, can = pcall(ctx.deps[Admin].can, by, "reports.reporters")
			return ok and can == true
		end
		return fallbackAdmin(by)
	end

	-- a user's CURRENT rank when Admin knows it without spending a group lookup (Admin.rankOfChecked);
	-- nil = unknown. Never a rank remembered from an earlier report (fix 2: the user may have been
	-- promoted since), so the viewer rule hides and the resolve override is refused (fails closed, H1).
	local function knownRank(target: number): number?
		local A = ctx.deps[Admin]
		local checked = A.rankOfChecked
		if type(checked) ~= "function" then
			-- an Admin without rankOfChecked (an older or a fake one): its own answers
			local player = online[target]
			if player ~= nil then
				local ok, r = pcall(A.rankOf, player)
				return if ok and type(r) == "number" then r else nil
			end
			local ok, known, r = pcall(A.rankOfUserId, target)
			return if ok and known == true and type(r) == "number" then r else nil
		end
		local ok, r = pcall(checked, online[target] or target)
		return if ok and type(r) == "number" then r else nil
	end

	-- function(targetUserId) -> visible to this viewer (B6). Never spends a group lookup: Admin's
	-- in-server and cached ranks only; unknown = hidden.
	local function viewerFilter(by: any, kind: string): (number) -> boolean
		if kind ~= "staff" then
			return function(_target: number): boolean
				return true
			end
		end
		local me = by.UserId
		if adminOn then
			local A = ctx.deps[Admin]
			local okMine, mine = pcall(A.rankOf, by)
			local myRank = if okMine and type(mine) == "number" then mine else 0
			local ranks: { [number]: number } = {}
			return function(target: number): boolean
				if target == me then
					return false
				end
				local rank = ranks[target]
				if rank == nil then
					rank = knownRank(target) or math.huge
					ranks[target] = rank
				end
				local r = rank :: number
				return r <= 0 or r < myRank
			end
		end
		local staff = fallbackList()
		return function(target: number): boolean
			return target ~= me and table.find(staff, target) == nil
		end
	end

	---------------------------------------------------------------------------------------------
	-- the queue index (sorted map) and the per-target keys (shared store)
	---------------------------------------------------------------------------------------------

	local function writeIndex(rec: any)
		local summary = Record.summary(rec)
		local sortKey = Record.sortKey(rec)
		local ok, why = map.update(
			tostring(math.floor(rec.target)),
			function(_old: any, _oldSort: any): (any, any)
				return summary, sortKey
			end,
			expiry()
		)
		if not ok then
			count("index_failed")
			ctx.log.warn(`queue index write failed: {tostring(why)}`)
		end
	end

	local function removeIndex(target: number)
		local ok = map.remove(tostring(math.floor(target)))
		if ok then
			cachedCount = math.max(0, cachedCount - 1)
		end
		table.clear(tabWalks) -- this server's tab pages start over
	end

	local function isStale(rec: any): boolean
		return type(rec) == "table" and (type(rec.lastAt) ~= "number" or ctx.now() - rec.lastAt >= expiry())
	end

	-- one per-target record (an update that returns what it read; an absent key stays absent). A
	-- record older than queue.indexExpiryDays is closed (Addendum G): the read deletes it, reporter
	-- ids and all, and answers nil.
	local function readRecord(target: number): (boolean, any)
		local ok, rec = ctx.data.shared.update(key(target), function(old: any): any
			if isStale(old) then
				return nil
			end
			return old
		end)
		return ok, if isStale(rec) then nil else rec
	end

	-- (Addendum G) the store has no open record for `target`: drop its index entry when that entry
	-- still names `reportId` (or any id when reportId is nil), so a ghost left by a submit/resolve
	-- race doesn't stay in the queue
	--
	-- (fix 2) A sorted map has no conditional remove (an update returning nil cancels), so the drop
	-- is made safe by re-checking the record AFTER the remove: a submit writes its record before its
	-- index entry, so if a submit's entry was removed by mistake, its record is already there and the
	-- entry is written back. The remove only happens while the record is still closed.
	local function dropGhost(target: number, reportId: string?)
		local name = tostring(math.floor(target))
		local ok, value = map.get(name)
		if not ok or type(value) ~= "table" or (reportId ~= nil and value.id ~= reportId) then
			return
		end
		local okBefore, before = readRecord(target)
		if
			not okBefore
			or (type(before) == "table" and (before.status == "open" or before.status == "claimed"))
		then
			return -- unknown, or open again: leave the entry
		end
		removeIndex(target)
		local okAfter, after = readRecord(target)
		if okAfter and type(after) == "table" and (after.status == "open" or after.status == "claimed") then
			writeIndex(after)
			count("ghost_restored")
			return
		end
		count("ghost_removed")
	end

	-- every index entry, lowest priority first (bounded by maxOpen + one page)
	local function scanIndex(): (boolean, { any })
		local out: { any } = {}
		local lower: any = nil
		local bound = ctx.config.queue.maxOpen + PAGE
		while #out < bound do
			local ok, page = map.range("asc", PAGE, lower)
			if not ok or type(page) ~= "table" then
				return false, out
			end
			for _, item in page do
				table.insert(out, item)
			end
			if #page < PAGE then
				break
			end
			local last = page[#page]
			lower = { key = last.key, sortKey = last.sortKey }
		end
		return true, out
	end

	local function evict(item: any)
		local id = if type(item.value) == "table" then item.value.id else nil
		ctx.data.shared.update(`r/t/{item.key}`, function(old: any): any
			if type(old) == "table" and old.id == id then
				return nil
			end
			return old
		end)
		map.remove(item.key)
		count("evicted")
		ctx.log.info(`queue full: evicted report {tostring(id)}`)
	end

	-- M15: at maxOpen the lowest-priority report (fewest distinct reporters, oldest) goes
	local function enforceMax()
		local max = ctx.config.queue.maxOpen
		local now = ctx.now()
		local stale = scannedAt == nil or now - (scannedAt :: number) >= COUNT_CACHE_SECONDS
		if not stale and cachedCount + createdSince <= max then
			return
		end
		local ok, items = scanIndex()
		if not ok then
			return
		end
		scannedAt = now
		createdSince = 0
		local total = #items
		local i = 1
		while total > max and i <= #items do
			evict(items[i])
			total -= 1
			i += 1
		end
		cachedCount = total
	end

	---------------------------------------------------------------------------------------------
	-- context, notes, audit
	---------------------------------------------------------------------------------------------

	local function isKey(s: string): boolean
		if not looksLikeKey(s) then
			return false
		end
		local ok, english = pcall(ctx.text.english, s)
		return ok and type(english) == "string" and english ~= s
	end

	local function buildContext(target: number, player: any?): any
		if #contexts == 0 then
			return nil
		end
		local merged: { [string]: any } = {}
		for _, fn in contexts do
			local ok, values = pcall(fn, target, player)
			if ok and type(values) == "table" then
				for k, v in values do
					if merged[k] == nil then
						merged[k] = v
					end
				end
			end
		end
		return Record.context(merged, ctx.config.contextMaxBytes, isKey)
	end

	-- the filtered ("public") note, or nil: dropped when notes are off, TextFilter is off, or the
	-- filter refuses or fails (B7)
	local function filterNote(reporter: any, note: string?): string?
		if note == nil or note == "" or not ctx.config.note.enabled then
			return nil
		end
		if not filterOn then
			count("note_dropped")
			return nil
		end
		local okCall, ok, result = pcall(ctx.deps[TextFilter].filter, reporter, note, "public")
		if not okCall or ok ~= true or type(result) ~= "table" then
			count("note_dropped")
			return nil
		end
		local public = result.public
		if type(public) ~= "string" or public == "" then
			count("note_dropped")
			return nil
		end
		return public
	end

	local function audit(action: string, target: number, by: any, reasonKey: string?, note: string?)
		if moderationOn then
			local ok, recorded = pcall(ctx.deps[Moderation].record, {
				action = action,
				target = target,
				reasonKey = reasonKey,
				note = note,
				status = "ok",
			}, { by = by })
			if ok and recorded == true then
				return
			end
		end
		ctx.log.info(
			`{action} target={target} by={Actor.userId(by)} reason={reasonKey or "-"} note={note or "-"}`
		)
	end

	local function recentEntry(userId: number): any
		for _, entry in recent do
			if entry.userId == userId then
				return entry
			end
		end
		return nil
	end

	local function publishRecent()
		local list = {}
		for i = #recent, 1, -1 do
			local entry = recent[i]
			table.insert(list, { userId = entry.userId, name = entry.name })
		end
		ctx.replicate.setAll("recent", list)
	end

	local function dropRecent(userId: number): boolean
		for i, entry in recent do
			if entry.userId == userId then
				table.remove(recent, i)
				return true
			end
		end
		return false
	end

	---------------------------------------------------------------------------------------------
	-- the API
	---------------------------------------------------------------------------------------------

	local api: any = {}

	-- yields (the note is filtered, the store written); (ok, reason?): the reporter is told
	-- "thanks" whatever the outcome
	function api.submit(
		reporter: any,
		targetUserId: number,
		category: string,
		note: string?
	): (boolean, string?)
		if not isOn() then
			return false, "disabled"
		end
		local cfg = ctx.config
		if not Actor.isPlayer(reporter) then
			return false, "invalid"
		end
		if
			type(targetUserId) ~= "number"
			or targetUserId ~= targetUserId
			or targetUserId < 1
			or targetUserId > 2 ^ 53
			or targetUserId ~= math.floor(targetUserId)
			or targetUserId == reporter.UserId
		then
			count("invalid")
			return false, "invalid"
		end
		local index = if type(category) == "string" then table.find(cfg.categories, category) else nil
		if index == nil then
			count("invalid")
			return false, "invalid"
		end
		local cat: string = cfg.categories[index]
		if note ~= nil and (type(note) ~= "string" or (utf8.len(note) or math.huge) > cfg.note.maxLength) then
			count("invalid")
			return false, "invalid"
		end
		local targetPlayer = online[targetUserId]
		local targetName: string
		if targetPlayer ~= nil then
			targetName = targetPlayer.Name
		else
			local entry = recentEntry(targetUserId)
			if entry == nil or ctx.now() - entry.at > cfg.recentSeconds then
				count("not_reportable")
				return false, "not_reportable"
			end
			targetName = entry.name
		end
		if not ctx.data.isLoaded(reporter) then
			return false, "not_loaded"
		end
		local now = ctx.now()
		-- the reporter's own limits (durable: the save section), reserved before anything yields
		local section = ctx.data.get(reporter)
		local why = Record.sentCheck(section and section.sent, targetUserId, now, cfg.limits)
		if why ~= nil then
			count(why)
			return false, why
		end
		local saved = ctx.data.update(reporter, function(s: any)
			s.sent = Record.sentAppend(s.sent, targetUserId, now, cfg.limits.sentMax)
		end)
		if not saved then
			return false, "failed"
		end

		local clean = filterNote(reporter, note)
		local input: Record.Input = {
			reporter = reporter.UserId,
			target = targetUserId,
			targetName = targetName,
			category = cat,
			note = clean,
			now = now,
			server = serverId(),
			placeVersion = placeVersion(),
			context = buildContext(targetUserId, targetPlayer),
		}
		local opts = {
			perTargetPerDay = cfg.limits.perTargetPerDay,
			staleSeconds = cfg.queue.indexExpiryDays * DAY,
		}
		local auto = cfg.autoAction
		local outcome = "failed"
		local fired = false
		local ok, stored = ctx.data.shared.update(key(targetUserId), function(old: any): any
			local new, result = Record.merge(old, input, opts)
			outcome = result
			fired = false
			if result ~= "target_day" and auto.enabled then
				local n = Record.distinctSince(new, now - auto.windowSeconds)
				if
					n >= auto.distinctReporters
					and (new.autoAt == nil or now - new.autoAt >= auto.windowSeconds)
				then
					new.autoAt = now
					fired = true
				end
			end
			return new
		end)
		if not ok or type(stored) ~= "table" then
			count("failed")
			return false, "failed"
		end
		if outcome == "target_day" then
			count("target_day")
			return false, "target_day"
		end
		count(outcome)
		-- (Addendum G) index only a record this update returned open; a resolve that lands between this
		-- update and the index write is caught on read (dropGhost)
		if stored.status == "open" or stored.status == "claimed" then
			writeIndex(stored)
		end
		if outcome == "created" then
			createdSince += 1
			enforceMax()
		end
		if created.Submitted ~= nil then
			created.Submitted:Fire(stored.id, targetUserId, cat)
		end
		if fired and moderationOn then
			local okReport, err =
				pcall(ctx.deps[Moderation].report, targetPlayer or targetUserId, auto.source, auto.severity)
			if not okReport then
				ctx.log.warn(`autoAction: Moderation.report failed: {tostring(err)}`)
			end
			count("auto_action")
		end
		return true, nil
	end

	-- a walk down the index, highest priority first. walk() reads whole pages (so a walk can be
	-- resumed), at most `calls` range reads, and stops when `limit` visible summaries are collected,
	-- the index ends, or queue.maxOpen + one page of entries were read (Addendum G). A failed read
	-- ends the walk with `failed` set. Summaries are rebuilt with Record.summary: game code gets
	-- the documented fields only (fix 2), whatever an older build stored in the index.
	local function newWalk(): any
		return { out = {}, upper = nil, read = 0, done = false, failed = false, at = ctx.now() }
	end

	local function walk(w: any, visible: (number) -> boolean, status: string?, limit: number, calls: number)
		local bound = ctx.config.queue.maxOpen + PAGE
		local n = 0
		while not w.done and #w.out < limit and n < calls do
			if w.read >= bound then
				w.done = true
				break
			end
			n += 1
			local ok, page = map.range("desc", PAGE, nil, w.upper)
			if not ok or type(page) ~= "table" then
				w.done, w.failed = true, true
				break
			end
			w.read += #page
			for _, item in page do
				local s = item.value
				if
					type(s) == "table"
					and type(s.target) == "number"
					and (status == nil or s.status == status)
					and visible(s.target)
				then
					table.insert(w.out, Record.summary(s))
				end
			end
			if #page < PAGE then
				w.done = true
			else
				local last = page[#page]
				w.upper = { key = last.key, sortKey = last.sortKey }
			end
		end
	end

	-- the index summaries this viewer may see, highest priority first, through the whole index
	local function listQueue(by: any, kind: string, status: string?, limit: number): { any }
		local w = newWalk()
		walk(w, viewerFilter(by, kind), status, limit, math.huge)
		local out = w.out
		while #out > limit do
			table.remove(out)
		end
		return out
	end

	-- index summaries (sorted map range); needs reports.read
	function api.queue(opts: any): (boolean, any)
		local by, kind = Actor.of(opts, "Reports.queue")
		if opts.status ~= nil and table.find(STATUSES, opts.status) == nil then
			return false, "invalid"
		end
		local limit = QUEUE_DEFAULT
		if opts.limit ~= nil then
			if type(opts.limit) ~= "number" or opts.limit ~= opts.limit then
				return false, "invalid"
			end
			limit = math.clamp(math.floor(opts.limit), 1, math.max(PAGE, ctx.config.queue.maxOpen))
		end
		local ok, why = permit(by, kind, "reports.read")
		if not ok then
			return false, why
		end
		return true, listQueue(by, kind, opts.status, limit)
	end

	-- the full record of one report (one store read); needs reports.read
	function api.detail(reportId: string, opts: any): (boolean, any)
		local by, kind = Actor.of(opts, "Reports.detail")
		local target = Record.parseId(reportId)
		if target == nil then
			return false, "invalid"
		end
		local ok, why = permit(by, kind, "reports.read")
		if not ok then
			return false, why
		end
		if not viewerFilter(by, kind)(target) then
			return false, "not_found"
		end
		local okRead, rec = readRecord(target)
		if not okRead then
			return false, "failed"
		end
		if type(rec) ~= "table" then
			dropGhost(target, reportId)
			return false, "not_found"
		end
		if rec.id ~= reportId then
			return false, "not_found"
		end
		return true, Record.forViewer(rec, seesReporters(by, kind))
	end

	function api.claim(reportId: string, opts: any): (boolean, string?)
		local by, kind = Actor.of(opts, "Reports.claim")
		local target = Record.parseId(reportId)
		if target == nil then
			return false, "invalid"
		end
		local ok, why = permit(by, kind, "reports.resolve")
		if not ok then
			return false, why
		end
		if not viewerFilter(by, kind)(target) then
			return false, "not_found"
		end
		local me = Actor.userId(by)
		local result = "not_found"
		local missing = false
		local okWrite, stored = ctx.data.shared.update(key(target), function(old: any): any
			result = "not_found"
			missing = false
			if isStale(old) then
				missing = true
				return nil -- closed (Addendum G): reporter ids dropped
			end
			if type(old) ~= "table" then
				missing = true
				return old
			end
			if old.id ~= reportId then
				return old
			end
			if old.claimedBy ~= nil and old.claimedBy ~= me and kind == "staff" then
				result = "claimed"
				return old
			end
			local new = table.clone(old)
			new.status = "claimed"
			new.claimedBy = me
			result = "ok"
			return new
		end)
		if not okWrite then
			return false, "failed"
		end
		if missing then
			dropGhost(target, reportId)
		end
		if result ~= "ok" then
			return false, result
		end
		writeIndex(stored)
		table.clear(tabWalks) -- this server's tab pages show the claim
		audit("report_claimed", target, by, nil, nil)
		return true, nil
	end

	-- needs reports.resolve; opts.note is a preset key (Reports.resolveNote.*)
	function api.resolve(reportId: string, resolution: string, opts: any): (boolean, string?)
		local by, kind = Actor.of(opts, "Reports.resolve")
		if table.find(RESOLUTIONS, resolution) == nil then
			return false, "invalid"
		end
		local note = opts.note
		if note ~= nil and table.find(RESOLVE_NOTES, note) == nil then
			return false, "invalid"
		end
		local target = Record.parseId(reportId)
		if target == nil then
			return false, "invalid"
		end
		local ok, why = permit(by, kind, "reports.resolve")
		if not ok then
			return false, why
		end
		if not viewerFilter(by, kind)(target) then
			return false, "not_found"
		end
		-- (Addendum G) a report claimed by another staff member is resolved only by that claimer or a
		-- higher rank (trusted actors always)
		local me = Actor.userId(by)
		local mayOverride: number? = nil
		local function attempt(): (boolean, string, number?)
			local result, missing, claimer = "not_found", false, nil
			local okWrite = ctx.data.shared.update(key(target), function(old: any): any
				result, missing, claimer = "not_found", false, nil
				if isStale(old) then
					missing = true
					return nil
				end
				if type(old) ~= "table" then
					missing = true
					return old
				end
				if old.id ~= reportId then
					return old
				end
				if
					kind == "staff"
					and old.claimedBy ~= nil
					and old.claimedBy ~= me
					and old.claimedBy ~= mayOverride
				then
					result, claimer = "claimed", old.claimedBy
					return old
				end
				result = "ok"
				return nil
			end)
			if not okWrite then
				return false, "failed", nil
			end
			if missing then
				dropGhost(target, reportId)
			end
			return result == "ok", result, claimer
		end
		local done, result, claimer = attempt()
		if not done and result == "claimed" and adminOn and type(claimer) == "number" then
			local okMine, mine = pcall(ctx.deps[Admin].rankOf, by)
			local theirs = knownRank(claimer)
			if okMine and type(mine) == "number" and theirs ~= nil and mine > theirs then
				mayOverride = claimer
				done, result = attempt()
			end
		end
		if not done then
			return false, result
		end
		removeIndex(target)
		audit("report_resolved", target, by, "Reports.resolution." .. resolution, note)
		if created.Resolved ~= nil then
			created.Resolved:Fire(reportId, resolution)
		end
		return true, nil
	end

	-- values: number | boolean | a declared strings key (anything else is dropped)
	function api.registerContext(fn: (number, any) -> any)
		if type(fn) ~= "function" then
			error("Reports.registerContext(fn): fn must be a function(targetUserId, target?)", 2)
		end
		table.insert(contexts, fn)
	end

	api.signals = signals

	part.api = api
	part.extensions = { registerContext = api.registerContext }

	-- how many context functions are registered (specs, the builder)
	part.contextCount = function(): number
		return #contexts
	end

	-- server-side outcome counters (a refused report is only ever counted here)
	part.stats = function(): { [string]: number }
		return table.clone(stats)
	end

	local function onSubmit(player: any, targetUserId: number, category: string, note: string?)
		if not isOn() then
			ctx.net.feedback(player, "toast", ctx.text.format(player, "Reports.disabled"))
			return
		end
		local ok, err = pcall(api.submit, player, targetUserId, category, note)
		if not ok then
			count("error")
			ctx.log.warn(`submit failed: {tostring(err)}`)
		end
		ctx.net.feedback(player, "toast", ctx.text.format(player, "Reports.thanks"))
	end

	part.actions = {
		submit = { limit = { rate = 0.1, burst = 2 }, handler = onSubmit },
	}

	---------------------------------------------------------------------------------------------
	-- the Admin tab
	---------------------------------------------------------------------------------------------

	local function resolutionFrom(preset: any): string?
		if type(preset) ~= "string" then
			return nil
		end
		for _, r in RESOLUTIONS do
			if preset == r or preset == "Reports.resolution." .. r then
				return r
			end
		end
		return nil
	end

	local function fetchTab(staff: any, page: number): any
		local see = seesReporters(staff, "staff")
		local columns = { "id", "at", "target", "category", "count", "status", "notes" }
		if see then
			table.insert(columns, "reporters")
		end
		local okRead, canRead = pcall(ctx.deps[Admin].can, staff, "reports.read")
		if not okRead or canRead ~= true then
			return { rows = {}, columns = columns }
		end
		-- (Addendum G) every page of the queue, up to queue.maxOpen reports. (fix 2) A fetch reads at
		-- most TAB_CALLS index pages whatever maxOpen is: page 1 starts a new walk, later pages resume
		-- this staff member's walk while it is fresh, so paging forward costs one step per page.
		local pages = math.max(1, math.ceil(ctx.config.queue.maxOpen / TAB_ROWS))
		local p = if type(page) == "number" and page == page
			then math.clamp(math.floor(page), 1, pages)
			else 1
		local w = tabWalks[staff.UserId]
		if p == 1 or w == nil or ctx.now() - w.at >= TAB_WALK_SECONDS then
			w = newWalk()
			tabWalks[staff.UserId] = w
		end
		walk(w, viewerFilter(staff, "staff"), nil, p * TAB_ROWS, TAB_CALLS)
		if w.failed then
			tabWalks[staff.UserId] = nil
		end
		local all = w.out
		local rows = {}
		local details = 0
		for i = (p - 1) * TAB_ROWS + 1, math.min(#all, p * TAB_ROWS) do
			local s = all[i]
			local row: { [string]: any } = {
				id = s.id,
				at = s.at,
				target = `{s.targetName} ({s.target})`,
				category = "Reports.category." .. tostring(s.category),
				count = s.count,
				status = "Reports.status." .. tostring(s.status),
				notes = "",
			}
			if see then
				row.reporters = tostring(s.distinct or 0)
			end
			-- full detail only for the viewer's own claimed reports (one read each, bounded)
			if s.claimedBy == staff.UserId and details < TAB_DETAILS then
				details += 1
				local okRec, rec = readRecord(s.target)
				if okRec and type(rec) == "table" and rec.id == s.id then
					local view = Record.forViewer(rec, see)
					row.notes = table.concat(view.notes, " | ")
					if see then
						local ids = {}
						for _, id in view.reporters do
							table.insert(ids, tostring(id))
						end
						row.reporters = table.concat(ids, ",")
					end
				end
			end
			table.insert(rows, row)
		end
		return { rows = rows, columns = columns }
	end

	local function registerTab()
		ctx.depsExt[Admin].registerTab({
			id = "reports",
			permission = "reports.read",
			labelKey = "Reports.tab.queue",
			fetch = fetchTab,
			rowActions = {
				{
					id = "claim",
					permission = "reports.resolve",
					labelKey = "Reports.action.claim",
					run = function(staff: any, rowId: string, _args: any): (boolean, string?)
						return api.claim(rowId, { by = staff })
					end,
				},
				{
					id = "resolve",
					permission = "reports.resolve",
					labelKey = "Reports.action.resolve",
					-- the resolution is args.preset; an optional note key rides in args.note
					presets = {
						"Reports.resolution.actioned",
						"Reports.resolution.no_action",
						"Reports.resolution.dismissed",
					},
					notes = RESOLVE_NOTES,
					run = function(staff: any, rowId: string, args: any): (boolean, string?)
						local a = if type(args) == "table" then args else {}
						local resolution = resolutionFrom(a.preset)
						if resolution == nil then
							return false, "invalid"
						end
						-- Admin hands the picked note key as args.note (its row-action wire);
						-- args.text is accepted too (a direct call)
						local picked = if type(a.note) == "string" then a.note else a.text
						local note = if type(picked) == "string"
								and table.find(RESOLVE_NOTES, picked) ~= nil
							then picked
							else nil
						return api.resolve(rowId, resolution, { by = staff, note = note })
					end,
				},
			},
		})
	end

	---------------------------------------------------------------------------------------------
	-- console (server-only: a nil player is the Studio command bar)
	---------------------------------------------------------------------------------------------

	local function registerConsole()
		local function actor(player: any): any
			return if player ~= nil then player else "console"
		end
		ctx.console.register("queue", function(player: any, status: any): string
			local ok, list = api.queue({ by = actor(player), status = status, limit = PAGE })
			if not ok then
				return `refused: {tostring(list)}`
			end
			local lines = { `{#list} report(s)` }
			for _, s in list do
				table.insert(
					lines,
					`{s.id} {s.targetName} ({s.target}) {s.category} x{s.count} distinct={s.distinct} {s.status}`
				)
			end
			return table.concat(lines, "\n")
		end, "reports queue [open|claimed]")
		ctx.console.register("detail", function(player: any, reportId: any): string
			local ok, rec = api.detail(tostring(reportId), { by = actor(player) })
			if not ok then
				return `refused: {tostring(rec)}`
			end
			return `{rec.id} target={rec.target} {rec.category} count={rec.count} status={rec.status} notes={#rec.notes}`
		end, "reports detail <reportId>")
		ctx.console.register("claim", function(player: any, reportId: any): string
			local ok, why = api.claim(tostring(reportId), { by = actor(player) })
			return if ok then "claimed" else `refused: {tostring(why)}`
		end, "reports claim <reportId>")
		ctx.console.register(
			"resolve",
			function(player: any, reportId: any, resolution: any, note: any): string
				local ok, why =
					api.resolve(tostring(reportId), tostring(resolution), { by = actor(player), note = note })
				return if ok then "resolved" else `refused: {tostring(why)}`
			end,
			"reports resolve <reportId> <actioned|no_action|dismissed> [noteKey]"
		)
		ctx.console.register("stats", function(_player: any): string
			local names = {}
			for name in stats do
				table.insert(names, name)
			end
			table.sort(names)
			local parts = {}
			for _, name in names do
				table.insert(parts, `{name}={stats[name]}`)
			end
			return if #parts == 0 then "no reports" else table.concat(parts, " ")
		end, "reports stats")
	end

	function part.init(context: any)
		ctx = context
		local cfg = ctx.config
		if cfg.flag ~= nil then
			local ok, err = pcall(ctx.flags.isOn, cfg.flag)
			if not ok then
				error(`[Reports] config.flag: {tostring(err)}`, 0)
			end
		end
		local errors = Server.check(cfg, ctx.serverConfig)
		if #errors > 0 then
			error("[Reports] " .. table.concat(errors, "; "), 0)
		end
		created.Submitted = ctx.signals.new("Submitted")
		created.Resolved = ctx.signals.new("Resolved")
		adminOn = ctx.isEnabled(Admin)
		moderationOn = ctx.isEnabled(Moderation)
		filterOn = ctx.isEnabled(TextFilter)
		map = ctx.data.sortedMap("queue")
		if adminOn then
			registerTab()
		end
		registerConsole()

		ctx.lifecycle.onPlayerLoaded(function(player: any)
			online[player.UserId] = player
			if dropRecent(player.UserId) then
				publishRecent()
			end
		end)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			online[player.UserId] = nil
			tabWalks[player.UserId] = nil
			dropRecent(player.UserId)
			if ctx.config.recentSeconds > 0 then
				table.insert(recent, { userId = player.UserId, name = player.Name, at = ctx.now() })
				while #recent > RECENT_MAX do
					table.remove(recent, 1)
				end
			end
			publishRecent()
		end)
		ctx.lifecycle.onTick(PRUNE_SECONDS, function(_dt: number)
			local cutoff = ctx.now() - ctx.config.recentSeconds
			local changed = false
			for i = #recent, 1, -1 do
				if recent[i].at < cutoff then
					table.remove(recent, i)
					changed = true
				end
			end
			if changed then
				publishRecent()
			end
		end)
	end

	function part.start(_context: any) end

	return part
end

return Server
