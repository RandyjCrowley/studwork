--!strict
--[[
	Moderation: the server part (docs/framework/kits/moderation.md, design §4, §8-§10).

	  api: ban, unban, history, kick, serverBan, mute, unmute, isMuted, warn, punish, report, audit,
	       record, signals Actioned(entry) / Muted(player, untilTs?) / Banned(userId, seconds)
	  no client actions (net.blink has only the server -> client Notice(key, argsJson))

	Who may act (./Actor.luau, design §2 and B5): opts.by is required. "server" and "console" are
	trusted; "system" may take only config.auto.permissions actions (a refusal is audited at most once
	per (target, source) per audit.refusedEverySeconds); a staff Player goes through Admin.allow (Admin
	enabled; ranks through Admin.rankOf / rankOfUserId, "outranked" / "unknown_rank") or, with Admin off,
	ctx.isStudio or ServerConfig.Moderation.admins. Free text from staff passes TextFilter "public"
	(B7); text from trusted code is the developer's own and is used as given.

	Files: Actor (who acts), Check (config), Util (pure helpers), Audit (the chunked audit log),
	Pending (pending bans/unbans with leases), Chat (TextChatService / voice mute), Panel (the Admin
	actions, Audit tab and sink), Console (the `moderation ...` commands).

	The module is a factory (`new`) so each server part keeps its own state (two runtimes in one
	process: specs, the multi-server sim). Server.new(opts?) takes spec seams: opts.jobId (the server
	id used in leases and audit chunks), opts.net (a fake Blink net).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Actor = require(script.Actor)
local Audit = require(script.Audit)
local Chat = require(script.Chat)
local Check = require(script.Check)
local Console = require(script.Console)
local Panel = require(script.Panel)
local Pending = require(script.Pending)
local Util = require(script.Util)
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Admin = require(Modules:WaitForChild("Admin"):WaitForChild("module"))
local TextFilter = require(Modules:WaitForChild("TextFilter"):WaitForChild("module"))

local Server = {}

-- exposed for specs
Server.Actor = Actor
Server.Check = Check
Server.Util = Util

local HOUR = 3600
local DAY = 86400
local DISPLAY_MAX = 400 -- Roblox: BanAsync DisplayReason characters
local PRIVATE_MAX = 1000 -- Roblox: BanAsync PrivateReason characters
local NOTICE_KEY_MAX = 64 -- net.blink Notice key
local NOTICE_ARGS_MAX = 400 -- net.blink Notice argsJson
local SEEN_MAX = 50 -- processed message ids kept in the save (design §4)
local SWEEP_EVERY = 6 * HOUR -- Addendum C: the retention sweep cadence
local KEY_MAX = 64

Server.RECORD_ACTIONS = table.freeze({
	"report_resolved",
	"report_claimed",
	"grant",
	"announce",
	"teleport",
	"spectate",
	"shutdown",
	"custom",
})
local STATUSES = { ok = true, pending = true, failed = true, refused = true }
local APPLIED = { done = true, sent = true, banned = true, pending = true }

-- counted: Admin already counted this staff request through Admin.allow (its Fetch of the Audit
-- tab, design §11): permit checks the permission only, so one click counts once
type Act = {
	kind: string,
	by: any,
	userId: number,
	player: any?,
	remote: boolean?,
	counted: boolean?,
	-- (Addendum G) a delivered punish: the sender's role caps, enforced where the step runs
	caps: { maxBanSeconds: number?, maxMuteSeconds: number? }?,
}

function Server.new(opts: any?): any
	local o = opts or {}
	local ctx: any = nil
	local part: any = {}
	local created: { [string]: any } = {}
	local signals = setmetatable({}, {
		__index = function(_, key: any): any
			return created[key]
		end,
	})

	local job = "studio"
	local audit: any = nil
	local pending: any = nil
	local chat: any = nil
	local online: { [number]: any } = {}
	local muteUntil: { [any]: number } = {}
	local serverBans: { [number]: number } = {}
	local windows: { [string]: any } = {}
	local refusedAt: { [string]: number } = {}
	local sendLog: { [number]: { number } } = {}
	local historyCache: { [number]: { at: number, entries: any } } = {}
	local rechecks: { [any]: number } = {}
	local idCounter = 0
	local nextSweepAt = 0
	local warnedBanning = false

	local api: any = {}

	--------------------------------------------------------------------------
	-- small helpers
	--------------------------------------------------------------------------

	local function cfg(): any
		return ctx.config
	end

	local function sc(): any
		return if type(ctx.serverConfig) == "table" then ctx.serverConfig else {}
	end

	local function isOn(): boolean
		local flag = cfg().flag
		if flag == nil then
			return true
		end
		local ok, on = pcall(ctx.flags.isOn, flag)
		return ok and on == true
	end

	local function adminOn(): boolean
		return ctx.isEnabled(Admin)
	end

	local function newId(): string
		idCounter += 1
		return `{string.sub(job, 1, 8)}-{ctx.now()}-{idCounter}`
	end

	local function playersService(): any
		local ok, players = pcall(ctx.services.get, "Players")
		return if ok then players else nil
	end

	local function findOnline(userId: number): any?
		local p = online[userId]
		if p ~= nil then
			return p
		end
		local players = playersService()
		if players == nil then
			return nil
		end
		local ok, found = pcall(function(): any
			return players:GetPlayerByUserId(userId)
		end)
		return if ok and Actor.isPlayer(found) then found else nil
	end

	-- (userId?, player here?)
	local function targetOf(target: any): (number?, any?)
		if Actor.isPlayer(target) then
			local uid = target.UserId
			if online[uid] == target or ctx.data.isLoaded(target) then
				return uid, target
			end
			return uid, findOnline(uid)
		end
		if Util.isCount(target) then
			return target, findOnline(target)
		end
		return nil, nil
	end

	local function loaded(player: any?): boolean
		return player ~= nil and ctx.data.isLoaded(player)
	end

	local function actorOf(opts2: any, where: string): Act
		local by, kind = Actor.of(opts2, where)
		return {
			kind = kind,
			by = by,
			userId = Actor.userId(by),
			player = if kind == "staff" then by else nil,
		}
	end

	local function english(key: string, args: any?): string
		local ok, s = pcall(ctx.text.english, key, args)
		return if ok and type(s) == "string" then s else key
	end

	local function textFor(player: any?, key: string, args: any?): string
		if player == nil then
			return english(key, args)
		end
		local ok, s = pcall(ctx.text.format, player, key, args)
		return if ok and type(s) == "string" then s else english(key, args)
	end

	local function isKey(v: any): boolean
		return type(v) == "string" and #v >= 1 and #v <= KEY_MAX
	end

	local function notice(player: any, key: string, args: any?)
		local net = part.net
		if net == nil or net.Notice == nil or #key > NOTICE_KEY_MAX then
			return
		end
		pcall(ctx.net.fire, player, net.Notice, key, Util.json(args or {}, NOTICE_ARGS_MAX))
	end

	local function kickHere(player: any, message: string)
		local text = Util.cutBytes(message, cfg().kick.maxLength)
		pcall(function()
			player:Kick(text)
		end)
	end

	--------------------------------------------------------------------------
	-- audit
	--------------------------------------------------------------------------

	local function write(act: Act, fields: any): any
		local entry: any = {
			by = act.userId,
			byKind = act.kind,
			action = fields.action,
			target = fields.target,
			reasonKey = fields.reasonKey,
			privateReason = fields.privateReason,
			seconds = fields.seconds,
			offense = fields.offense,
			source = fields.source,
			details = fields.details,
			status = fields.status or "ok",
			note = fields.note,
			-- (Admin's grant through the audit sink) the amount and currency granted
			amount = fields.amount,
			currency = fields.currency,
		}
		audit.add(entry)
		local frozen = table.freeze(table.clone(entry))
		if created.Actioned ~= nil then
			created.Actioned:Fire(frozen)
		end
		return frozen
	end

	-- a refused "system" or staff action: audited at most once per (target, source) / (staff, action)
	-- per audit.refusedEverySeconds
	local function refuse(
		act: Act,
		action: string,
		uid: number?,
		reason: string,
		extra: any?
	): (boolean, string)
		if act.kind == "system" or (act.kind == "staff" and (not act.remote or act.caps ~= nil)) then
			local source = if extra then extra.source else nil
			-- system: once per (target, source); staff (Addendum E): once per (staff, action)
			local k = if act.kind == "system"
				then `{tostring(uid)}|{tostring(source)}`
				else `staff|{act.userId}|{action}`
			local t = ctx.now()
			local last = refusedAt[k]
			if last == nil or t - last >= cfg().audit.refusedEverySeconds then
				refusedAt[k] = t
				write(act, {
					action = action,
					target = uid,
					status = "refused",
					source = source,
					offense = if extra then extra.offense else nil,
					details = if extra then extra.details else nil,
				})
			end
		end
		return false, reason
	end

	--------------------------------------------------------------------------
	-- permission, rank, role limits, free text
	--------------------------------------------------------------------------

	local function fallbackStaff(player: any): boolean
		if ctx.isStudio then
			return true
		end
		local admins = sc().admins
		return type(admins) == "table" and table.find(admins, player.UserId) ~= nil
	end

	local function permit(act: Act, action: string, perm: string): (boolean, string?)
		if act.kind == "server" or act.kind == "console" then
			return true, nil
		end
		if act.kind == "system" then
			if table.find(cfg().auto.permissions, action) ~= nil then
				return true, nil
			end
			return false, "no_permission"
		end
		if act.remote then
			return true, nil -- checked by the sending server (a punish delivered later)
		end
		if adminOn() and act.counted then
			local ok, yes = pcall(ctx.deps[Admin].can, act.player, perm)
			return ok and yes == true, if ok and yes == true then nil else "no_permission"
		end
		if adminOn() then
			-- (Addendum G) the action rides along: only a ban counts toward Admin's bansPerHour
			local ok, allowed, reason = pcall(ctx.deps[Admin].allow, act.player, perm, action)
			if ok and allowed == true then
				return true, nil
			end
			return false, if ok and type(reason) == "string" then reason else "no_permission"
		end
		if fallbackStaff(act.player) then
			return true, nil
		end
		return false, "no_permission"
	end

	local function can(act: Act, perm: string): boolean
		if act.kind ~= "staff" then
			return true
		end
		if adminOn() then
			local ok, yes = pcall(ctx.deps[Admin].can, act.player, perm)
			return ok and yes == true
		end
		return fallbackStaff(act.player)
	end

	-- staff may not act on themselves or on staff of an equal or higher rank (yields for absent targets)
	local function rankCheck(act: Act, uid: number, here: any?): (boolean, string?)
		if act.kind ~= "staff" or act.remote then
			return true, nil
		end
		if uid == act.userId then
			return false, "outranked"
		end
		-- Addendum E: in Studio everyone is staff with studioRole, so the rank rule is skipped for a
		-- target whose role comes only from studioRole (Admin.studioRoleOnly); a target with a
		-- ServerConfig users entry still uses the rank rule. Admin off: ServerConfig.Moderation.admins
		-- targets stay outranked (below).
		if ctx.isStudio and adminOn() then
			local fn = ctx.deps[Admin].studioRoleOnly
			if type(fn) ~= "function" then
				return true, nil
			end
			local okOnly, only = pcall(fn, uid)
			if okOnly and only == true then
				return true, nil
			end
		end
		if adminOn() then
			local A = ctx.deps[Admin]
			local okMine, mine = pcall(A.rankOf, act.player)
			mine = if okMine and type(mine) == "number" then mine else 0
			local theirs: number
			if here ~= nil then
				-- (Addendum G H1) a target whose role isn't resolved yet (lookup in flight, failed or
				-- over budget) is unknown, never "not staff": refuse
				local checked = if type(A.rankOfChecked) == "function" then A.rankOfChecked else A.rankOf
				local ok, r = pcall(checked, here)
				if not ok or type(r) ~= "number" then
					return false, "unknown_rank"
				end
				theirs = r
			else
				local okCall, ok, r = pcall(A.rankOfUserId, uid)
				if not okCall or ok ~= true or type(r) ~= "number" then
					return false, "unknown_rank"
				end
				theirs = r
			end
			if theirs > 0 and theirs >= mine then
				return false, "outranked"
			end
			return true, nil
		end
		local admins = sc().admins
		if type(admins) == "table" and table.find(admins, uid) ~= nil then
			return false, "outranked"
		end
		return true, nil
	end

	-- a role's maxBanSeconds / maxMuteSeconds, when Admin offers them (Admin.limitsOf(staff))
	local function roleLimit(act: Act, field: string): number?
		if act.kind ~= "staff" then
			return nil
		end
		if act.remote then
			-- (Addendum G) a punish delivered from another server carries the sender's caps
			local caps = act.caps
			local v = if caps ~= nil then (caps :: any)[field] else nil
			return if type(v) == "number" then v else nil
		end
		if not adminOn() then
			return nil
		end
		local fn = ctx.deps[Admin].limitsOf
		if type(fn) ~= "function" then
			return nil
		end
		local ok, limits = pcall(fn, act.player)
		if ok and type(limits) == "table" and type(limits[field]) == "number" then
			return limits[field]
		end
		return nil
	end

	-- (ok, filtered text | reason). Staff text passes TextFilter "public"; trusted code's text is its own.
	local function filterText(act: Act, text: string, missing: string): (boolean, string)
		if act.kind ~= "staff" then
			return true, text
		end
		if not ctx.isEnabled(TextFilter) then
			return false, missing
		end
		local okCall, ok, result = pcall(ctx.deps[TextFilter].filter, act.player, text, "public")
		if okCall and ok == true and type(result) == "table" and type(result.public) == "string" then
			return true, result.public
		end
		return false, "invalid"
	end

	--------------------------------------------------------------------------
	-- cross-server messages (ctx.data.messages)
	--------------------------------------------------------------------------

	local function spawnSend(act: Act, uid: number, payload: any, auditFields: any?)
		task.spawn(function()
			local ok, sent = pcall(ctx.data.messages.send, uid, payload)
			if ok and sent == true then
				pcall(ctx.data.messages.nudge, uid)
			elseif auditFields ~= nil then
				local f = table.clone(auditFields)
				f.status = "failed"
				f.note = "Moderation.note.sendFailed"
				write(act, f)
			end
		end)
	end

	-- (ok, "sent" | "rate_limited"); at most crossServer.perTargetPerHour per target from this server
	local function sendTo(act: Act, uid: number, payload: any, auditFields: any): (boolean, string)
		local t = ctx.now()
		local log: { number } = sendLog[uid] or {}
		local kept = {}
		for _, at in log do
			if t - at < HOUR then
				table.insert(kept, at)
			end
		end
		if #kept >= cfg().crossServer.perTargetPerHour then
			sendLog[uid] = kept
			return false, "rate_limited"
		end
		table.insert(kept, t)
		sendLog[uid] = kept
		payload.id = newId()
		payload.at = t
		payload.by = act.userId
		payload.byKind = act.kind
		local f = table.clone(auditFields)
		f.note = "Moderation.note.sent"
		write(act, f)
		spawnSend(act, uid, payload, auditFields)
		return true, "sent"
	end

	--------------------------------------------------------------------------
	-- mute state on a player here
	--------------------------------------------------------------------------

	local function afterMute(player: any, untilTs: number, key: string?, tell: boolean)
		muteUntil[player] = untilTs
		chat.mute(player.UserId, player)
		ctx.replicate.set(player, "muted", untilTs)
		if tell and key ~= nil then
			notice(player, key, { minutes = math.max(1, math.ceil((untilTs - ctx.now()) / 60)) })
		end
		if created.Muted ~= nil then
			created.Muted:Fire(player, untilTs)
		end
	end

	local function afterUnmute(player: any, tell: boolean)
		muteUntil[player] = nil
		chat.unmute(player.UserId, player)
		ctx.replicate.set(player, "muted", nil)
		if tell then
			notice(player, "Moderation.mute.ended")
		end
		if created.Muted ~= nil then
			created.Muted:Fire(player, nil)
		end
	end

	local function addStrike(s: any, offense: string, at: number, step: string)
		table.insert(s.strikes, { offense = offense, at = at, step = step })
		while #s.strikes > cfg().strikes.max do
			table.remove(s.strikes, 1)
		end
	end

	local function strikesFor(strikes: any, offense: string): number
		local since = ctx.now() - cfg().strikes.decayDays * DAY
		local n = 0
		for _, s in strikes or {} do
			if s.offense == offense and s.at >= since then
				n += 1
			end
		end
		return n
	end

	local function nextStep(strikes: any, offense: string): any
		local ladder = cfg().ladders[cfg().offenses[offense].ladder]
		local idx = math.min(strikesFor(strikes, offense) + 1, #ladder)
		return ladder[idx]
	end

	local function recordStrike(uid: number, here: any?, offense: string, action: string)
		local at = ctx.now()
		if loaded(here) then
			local ok = ctx.data.update(here, function(s: any)
				addStrike(s, offense, at, action)
			end)
			if ok then
				return
			end
		end
		-- not here (or just left): the strike reaches the save with the next load
		spawnSend({ kind = "server", by = "server", userId = 0 }, uid, {
			id = newId(),
			kind = "strike",
			offense = offense,
			step = action,
			strikeAt = at,
			at = at,
		}, nil)
	end

	--------------------------------------------------------------------------
	-- the actions (validated arguments in, permission/rank/limits checked here)
	--------------------------------------------------------------------------

	local function banMessage(player: any?, b: any): string
		local text = if b.displayText ~= nil then b.displayText else textFor(player, b.displayKey)
		local appeal = textFor(player, "Moderation.ban.appeal")
		return text .. " " .. appeal
	end

	local function callPlayers(entry: any): (boolean, any)
		local players = playersService()
		if players == nil then
			return false, "Players unavailable"
		end
		return pcall(function()
			if entry.kind == "unban" then
				players:UnbanAsync({ UserIds = { entry.userId }, ApplyToUniverse = true })
			else
				players:BanAsync({
					UserIds = { entry.userId },
					ApplyToUniverse = true,
					Duration = entry.seconds,
					DisplayReason = Util.cutChars(banMessage(nil, entry), DISPLAY_MAX),
					PrivateReason = Util.cutChars(entry.privateReason or "", PRIVATE_MAX),
					ExcludeAltAccounts = cfg().ban.excludeAltAccounts,
					ApplyDeviceBlock = cfg().ban.applyDeviceBlock,
				})
			end
		end)
	end

	local function banImpl(act: Act, uid: number, here: any?, b: any, extra: any?): (boolean, string)
		local x = extra or {}
		local permanent = b.seconds == -1
		local ok, reason = permit(act, "ban", if permanent then "ban.permanent" else "ban")
		if not ok then
			return refuse(
				act,
				"ban",
				uid,
				reason :: string,
				{ source = x.source, offense = b.offense, details = x.details }
			)
		end
		ok, reason = rankCheck(act, uid, here)
		if not ok then
			return refuse(act, "ban", uid, reason :: string)
		end
		if not permanent then
			local limit = roleLimit(act, "maxBanSeconds")
			if limit ~= nil and b.seconds > limit then
				return refuse(act, "ban", uid, "too_long_for_role")
			end
		end
		local auditPrivate: string? = nil
		if b.displayText ~= nil then
			local okText, clean = filterText(act, b.displayText, "invalid")
			if not okText then
				return false, clean
			end
			b.displayText = clean
		end
		if b.privateReason ~= nil then
			local okText, clean = filterText(act, b.privateReason, "no_filter")
			if not okText then
				return false, clean
			end
			auditPrivate = clean
		end
		local entry = {
			kind = "ban",
			userId = uid,
			seconds = b.seconds,
			displayKey = b.displayKey,
			displayText = b.displayText,
			privateReason = b.privateReason,
			by = act.userId,
			byKind = act.kind,
			at = ctx.now(),
			attempts = 1,
			offense = b.offense,
			source = x.source,
			auditPrivate = auditPrivate,
		}
		local fields = {
			action = "ban",
			target = uid,
			reasonKey = b.displayKey,
			privateReason = auditPrivate,
			seconds = b.seconds,
			offense = b.offense,
			source = x.source,
			details = x.details,
		}
		local called, err = callPlayers(entry)
		if called then
			pcall(pending.clear, uid)
			write(act, fields)
			if created.Banned ~= nil then
				created.Banned:Fire(uid, b.seconds)
			end
			return true, "banned"
		end
		if not Util.isTransient(err) then
			ctx.log.warn(`BanAsync for {uid} failed: {tostring(err)}`)
			fields.status = "failed"
			write(act, fields)
			return false, "failed"
		end
		if here ~= nil then
			kickHere(here, banMessage(here, entry))
		end
		local okPut, saved, indexed = pcall(pending.put, uid, entry)
		fields.status = "pending"
		if not okPut or (not saved and not indexed) then
			fields.note = "Moderation.note.pendingUnsaved"
			ctx.log.warn(`pending ban for {uid} is held in this server's memory only`)
		end
		write(act, fields)
		return true, "pending"
	end

	local function unbanImpl(act: Act, uid: number, privateReason: string?): (boolean, string)
		local ok, reason = permit(act, "unban", "ban")
		if not ok then
			return refuse(act, "unban", uid, reason :: string)
		end
		ok, reason = rankCheck(act, uid, findOnline(uid))
		if not ok then
			return refuse(act, "unban", uid, reason :: string)
		end
		local auditPrivate: string? = nil
		if privateReason ~= nil then
			local okText, clean = filterText(act, privateReason, "no_filter")
			if not okText then
				return false, clean
			end
			auditPrivate = clean
		end
		local entry = {
			kind = "unban",
			userId = uid,
			by = act.userId,
			byKind = act.kind,
			at = ctx.now(),
			attempts = 1,
		}
		local fields = { action = "unban", target = uid, privateReason = auditPrivate }
		serverBans[uid] = nil
		local called, err = callPlayers(entry)
		if called then
			pcall(pending.clear, uid)
			write(act, fields)
			return true, "unbanned"
		end
		if not Util.isTransient(err) then
			ctx.log.warn(`UnbanAsync for {uid} failed: {tostring(err)}`)
			fields.status = "failed"
			write(act, fields)
			return false, "failed"
		end
		local okPut, saved, indexed = pcall(pending.put, uid, entry)
		fields.status = "pending"
		if not okPut or (not saved and not indexed) then
			fields.note = "Moderation.note.pendingUnsaved"
		end
		write(act, fields)
		return true, "pending"
	end

	local function kickImpl(
		act: Act,
		uid: number,
		here: any?,
		key: string?,
		text: string?,
		extra: any?
	): (boolean, string)
		local x = extra or {}
		local ok, reason = permit(act, "kick", "kick")
		if not ok then
			return refuse(act, "kick", uid, reason :: string, x)
		end
		ok, reason = rankCheck(act, uid, here)
		if not ok then
			return refuse(act, "kick", uid, reason :: string)
		end
		local message = text
		if message ~= nil then
			local okText, clean = filterText(act, message, "invalid")
			if not okText then
				return false, clean
			end
			message = Util.cutBytes(clean, cfg().kick.maxLength)
		end
		local fields = {
			action = "kick",
			target = uid,
			reasonKey = key,
			offense = x.offense,
			source = x.source,
			details = x.details,
		}
		if here ~= nil then
			kickHere(here, message or textFor(here, key :: string))
			write(act, fields)
			return true, "done"
		end
		return sendTo(act, uid, { kind = "kick", key = key, text = message }, fields)
	end

	local function muteImpl(
		act: Act,
		uid: number,
		here: any?,
		seconds: number,
		key: string,
		extra: any?
	): (boolean, string)
		local x = extra or {}
		local ok, reason = permit(act, "mute", "mute")
		if not ok then
			return refuse(act, "mute", uid, reason :: string, x)
		end
		ok, reason = rankCheck(act, uid, here)
		if not ok then
			return refuse(act, "mute", uid, reason :: string)
		end
		local limit = roleLimit(act, "maxMuteSeconds")
		if limit ~= nil and seconds > limit then
			return refuse(act, "mute", uid, "too_long_for_role")
		end
		local untilTs = ctx.now() + seconds
		local fields = {
			action = "mute",
			target = uid,
			reasonKey = key,
			seconds = seconds,
			offense = x.offense,
			source = x.source,
			details = x.details,
		}
		if loaded(here) then
			local done = ctx.data.update(here, function(s: any)
				s.mute = { untilTs = untilTs, reasonKey = key }
			end)
			if done then
				afterMute(here, untilTs, key, true)
				write(act, fields)
				return true, "done"
			end
		end
		return sendTo(act, uid, { kind = "mute", untilTs = untilTs, key = key }, fields)
	end

	local function unmuteImpl(act: Act, uid: number, here: any?): (boolean, string)
		local ok, reason = permit(act, "unmute", "mute")
		if not ok then
			return refuse(act, "unmute", uid, reason :: string)
		end
		ok, reason = rankCheck(act, uid, here)
		if not ok then
			return refuse(act, "unmute", uid, reason :: string)
		end
		local fields = { action = "unmute", target = uid }
		if loaded(here) then
			local done = ctx.data.update(here, function(s: any)
				s.mute = { untilTs = 0, reasonKey = "" }
			end)
			if done then
				afterUnmute(here, true)
				write(act, fields)
				return true, "done"
			end
		end
		return sendTo(act, uid, { kind = "unmute" }, fields)
	end

	local function warnImpl(act: Act, uid: number, here: any?, key: string, extra: any?): (boolean, string)
		local x = extra or {}
		local ok, reason = permit(act, "warn", "warn")
		if not ok then
			return refuse(act, "warn", uid, reason :: string, x)
		end
		ok, reason = rankCheck(act, uid, here)
		if not ok then
			return refuse(act, "warn", uid, reason :: string)
		end
		local fields = {
			action = "warn",
			target = uid,
			reasonKey = key,
			offense = x.offense,
			source = x.source,
			details = x.details,
		}
		if loaded(here) then
			local done = ctx.data.update(here, function(s: any)
				s.warnings += 1
			end)
			if done then
				notice(here, key)
				write(act, fields)
				return true, "done"
			end
		end
		return sendTo(act, uid, { kind = "warn", key = key }, fields)
	end

	-- the message key of one ladder step: the step's own `key` (Addendum G), then for a warn the
	-- offence's `warnKey`, then the action's first preset (a ban: the offence's displayKey)
	local function stepKey(step: any, offense: string): string
		local c = cfg()
		local action = step.action
		local def = c.offenses[offense]
		if type(step.key) == "string" then
			return step.key
		end
		if action == "warn" then
			if def ~= nil and type(def.warnKey) == "string" then
				return def.warnKey
			end
			return c.warn.presetKeys[1] or "Moderation.warn.rules"
		elseif action == "mute" then
			return c.mute.presetKeys[1] or "Moderation.mute.generic"
		elseif action == "kick" then
			return c.kick.presetKeys[1] or "Moderation.kick.generic"
		end
		return (if def ~= nil then def.displayKey else nil) or c.ban.defaultDisplayKey
	end

	-- one ladder step against a target (here or not); (ok, status)
	local function runStep(
		act: Act,
		uid: number,
		here: any?,
		step: any,
		offense: string,
		x: any
	): (boolean, string)
		local action = step.action
		local key = stepKey(step, offense)
		if action == "warn" then
			return warnImpl(act, uid, here, key, x)
		elseif action == "mute" then
			return muteImpl(act, uid, here, step.seconds or cfg().mute.defaultSeconds, key, x)
		elseif action == "kick" then
			return kickImpl(act, uid, here, key, nil, x)
		end
		return banImpl(
			act,
			uid,
			here,
			{ seconds = step.seconds or -1, displayKey = key, offense = offense },
			x
		)
	end

	local function stepPermission(step: any): string
		if step.action == "ban" then
			return if (step.seconds or -1) == -1 then "ban.permanent" else "ban"
		end
		return step.action
	end

	-- (ok, step | reason, status?)
	local function punishImpl(
		act: Act,
		uid: number,
		here: any?,
		offense: string,
		extra: any?
	): (boolean, string, string?)
		local x = table.clone(extra or {})
		x.offense = offense
		if loaded(here) then
			local view = ctx.data.get(here)
			local step = nextStep(view.strikes, offense)
			local ok, status = runStep(act, uid, here, step, offense, x)
			if ok and APPLIED[status] then
				recordStrike(uid, here, offense, step.action)
			end
			return ok, if ok then step.action else status, if ok then status else nil
		end
		-- absent: the step is chosen where the target's save is (on delivery). A staff sender must be
		-- able to take every step of that ladder; "system" is checked against auto.permissions there.
		if act.kind == "staff" then
			local ladder = cfg().ladders[cfg().offenses[offense].ladder]
			for _, step in ladder do
				if not can(act, stepPermission(step)) then
					refuse(act, "punish", uid, "no_permission")
					return false, "no_permission", nil
				end
			end
			local ok, reason = permit(act, ladder[1].action, stepPermission(ladder[1]))
			if not ok then
				refuse(act, "punish", uid, reason :: string)
				return false, reason :: string, nil
			end
			ok, reason = rankCheck(act, uid, nil)
			if not ok then
				refuse(act, "punish", uid, reason :: string)
				return false, reason :: string, nil
			end
		end
		-- (Addendum G) the sender's role caps ride with the punish and are enforced on delivery
		local caps: any = nil
		if act.kind == "staff" and adminOn() and type(ctx.deps[Admin].limitsOf) == "function" then
			local okCaps, limits = pcall(ctx.deps[Admin].limitsOf, act.player)
			if not okCaps or type(limits) ~= "table" then
				-- (fix 2) caps unknown: refuse rather than send an uncapped punish (fails closed)
				ctx.log.warn(`punish: Admin.limitsOf failed: {tostring(limits)}`)
				refuse(act, "punish", uid, "failed")
				return false, "failed", nil
			else
				caps = {
					maxBanSeconds = if type(limits.maxBanSeconds) == "number"
						then limits.maxBanSeconds
						else nil,
					maxMuteSeconds = if type(limits.maxMuteSeconds) == "number"
						then limits.maxMuteSeconds
						else nil,
				}
			end
		end
		local ok, status = sendTo(
			act,
			uid,
			{ kind = "punish", offense = offense, source = x.source, details = x.details, caps = caps },
			{ action = "punish", target = uid, offense = offense, source = x.source, details = x.details }
		)
		return ok, status, if ok then status else nil
	end

	--------------------------------------------------------------------------
	-- message delivery (the target's server, or their next load)
	--------------------------------------------------------------------------

	local function receive(player: any, payload: any, processed: () -> ())
		if type(payload) ~= "table" or type(payload.id) ~= "string" or type(payload.kind) ~= "string" then
			processed()
			return
		end
		online[player.UserId] = player
		local kind = payload.kind
		local t = ctx.now()
		local remote: Act = {
			kind = if payload.byKind == "staff"
					or payload.byKind == "server"
					or payload.byKind == "console"
					or payload.byKind == "system"
				then payload.byKind
				else "server",
			by = nil,
			userId = if type(payload.by) == "number" then payload.by else 0,
			remote = true,
		}
		if remote.kind == "staff" and type(payload.caps) == "table" then
			local c = payload.caps
			remote.caps = {
				maxBanSeconds = if type(c.maxBanSeconds) == "number" then c.maxBanSeconds else nil,
				maxMuteSeconds = if type(c.maxMuteSeconds) == "number" then c.maxMuteSeconds else nil,
			}
		end
		local stale = type(payload.at) ~= "number" or t - payload.at > cfg().crossServer.kickMaxAgeSeconds
		local dup = false
		local step: any = nil
		local done = ctx.data.update(player, function(s: any)
			if table.find(s.seen, payload.id) ~= nil then
				dup = true
				return
			end
			table.insert(s.seen, payload.id)
			while #s.seen > SEEN_MAX do
				table.remove(s.seen, 1)
			end
			if kind == "mute" and type(payload.untilTs) == "number" then
				s.mute =
					{ untilTs = payload.untilTs, reasonKey = if isKey(payload.key) then payload.key else "" }
			elseif kind == "unmute" then
				s.mute = { untilTs = 0, reasonKey = "" }
			elseif kind == "warn" then
				s.warnings += 1
			elseif
				kind == "strike"
				and type(payload.offense) == "string"
				and type(payload.step) == "string"
				and type(payload.strikeAt) == "number"
			then
				addStrike(s, payload.offense, payload.strikeAt, payload.step)
			elseif
				kind == "punish"
				and type(payload.offense) == "string"
				and cfg().offenses[payload.offense]
			then
				step = nextStep(s.strikes, payload.offense)
			end
		end)
		if not done then
			return -- not loaded any more: delivered again on the next load
		end
		processed()
		if dup then
			return
		end
		if kind == "kick" then
			if stale then
				write(remote, {
					action = "kick",
					target = player.UserId,
					status = "failed",
					note = "Moderation.note.staleKick",
				})
				return
			end
			local key = if isKey(payload.key) then payload.key else cfg().kick.presetKeys[1]
			local text = if type(payload.text) == "string" then payload.text else textFor(player, key)
			kickHere(player, text)
		elseif kind == "mute" and type(payload.untilTs) == "number" then
			if payload.untilTs > t then
				afterMute(player, payload.untilTs, if isKey(payload.key) then payload.key else nil, true)
			end
		elseif kind == "unmute" then
			afterUnmute(player, true)
		elseif kind == "warn" and isKey(payload.key) then
			notice(player, payload.key)
		elseif kind == "punish" and step ~= nil then
			if step.action == "kick" and stale then
				write(remote, {
					action = "kick",
					target = player.UserId,
					status = "failed",
					note = "Moderation.note.staleKick",
					offense = payload.offense,
				})
				return
			end
			local x = {
				offense = payload.offense,
				source = if type(payload.source) == "string" then payload.source else nil,
				details = if type(payload.details) == "string" then payload.details else nil,
			}
			task.spawn(function()
				local ok, status = runStep(remote, player.UserId, player, step, payload.offense, x)
				if ok and APPLIED[status] then
					recordStrike(player.UserId, player, payload.offense, step.action)
				end
			end)
		end
	end

	--------------------------------------------------------------------------
	-- the API
	--------------------------------------------------------------------------

	local function displayKeyAllowed(key: any): boolean
		if type(key) ~= "string" then
			return false
		end
		if table.find(cfg().ban.displayKeys, key) ~= nil then
			return true
		end
		for _, offense in cfg().offenses do
			if offense.displayKey == key then
				return true
			end
		end
		return false
	end

	function api.ban(target: any, opts2: any): (boolean, string)
		local act = actorOf(opts2, "Moderation.ban")
		if not isOn() then
			return false, "disabled"
		end
		local uid, here = targetOf(target)
		if uid == nil then
			return false, "invalid"
		end
		local seconds = opts2.seconds
		if seconds == nil then
			seconds = -1
		elseif seconds ~= -1 and not Util.isCount(seconds) then
			return false, "invalid"
		end
		local offense = opts2.offense
		if offense ~= nil and (type(offense) ~= "string" or cfg().offenses[offense] == nil) then
			return false, "invalid"
		end
		local displayKey = opts2.displayKey
		if displayKey == nil then
			displayKey = if offense ~= nil then cfg().offenses[offense].displayKey else nil
			displayKey = displayKey or cfg().ban.defaultDisplayKey
		end
		if not displayKeyAllowed(displayKey) then
			return false, "invalid"
		end
		local displayText = opts2.displayText
		if displayText ~= nil then
			local len = if type(displayText) == "string" then utf8.len(displayText) else nil
			if
				not cfg().ban.allowFreeDisplay
				or len == nil
				or len < 1
				or len > cfg().ban.maxDisplayLength
			then
				return false, "invalid"
			end
		end
		local privateReason = opts2.privateReason
		if privateReason ~= nil and (type(privateReason) ~= "string" or privateReason == "") then
			return false, "invalid"
		end
		return banImpl(act, uid, here, {
			seconds = seconds,
			displayKey = displayKey,
			displayText = displayText,
			privateReason = privateReason,
			offense = offense,
		}, nil)
	end

	function api.unban(userId: number, opts2: any): (boolean, string)
		local act = actorOf(opts2, "Moderation.unban")
		if not isOn() then
			return false, "disabled"
		end
		if not Util.isCount(userId) then
			return false, "invalid"
		end
		local privateReason = opts2.privateReason
		if privateReason ~= nil and (type(privateReason) ~= "string" or privateReason == "") then
			return false, "invalid"
		end
		return unbanImpl(act, userId, privateReason)
	end

	local function historyKeys(): { [string]: string }
		local out: { [string]: string } = {}
		local keys = table.clone(cfg().ban.displayKeys)
		for _, offense in cfg().offenses do
			if type(offense.displayKey) == "string" then
				table.insert(keys, offense.displayKey)
			end
		end
		local appeal = english("Moderation.ban.appeal")
		for _, key in keys do
			local text = english(key)
			out[text] = key
			out[Util.cutChars(text .. " " .. appeal, DISPLAY_MAX)] = key
		end
		return out
	end

	function api.history(userId: number, opts2: any): (boolean, any)
		local act = actorOf(opts2, "Moderation.history")
		if not isOn() then
			return false, "disabled"
		end
		if not Util.isCount(userId) then
			return false, "invalid"
		end
		if act.kind == "system" then
			return false, "no_permission"
		end
		if act.kind == "staff" then
			local perm = if can(act, "ban") then "ban" else "audit.read"
			local ok, reason = permit(act, "history", perm)
			if not ok then
				return refuse(act, "history", userId, reason :: string)
			end
		end
		if ctx.isStudio then
			return false, "unavailable"
		end
		local t = ctx.now()
		local hit = historyCache[userId]
		if hit ~= nil and t - hit.at < cfg().history.cacheSeconds then
			return true, table.clone(hit.entries)
		end
		local players = playersService()
		local ok, page = pcall(function(): any
			return players:GetBanHistoryAsync(userId):GetCurrentPage()
		end)
		if not ok or type(page) ~= "table" then
			return false, "failed"
		end
		local known = historyKeys()
		local entries = {}
		for _, e in page do
			local banned = e.Ban == true
			local reasonKey = if banned
				then (known[tostring(e.DisplayReason)] or "Moderation.history.custom")
				else "Moderation.history.unban"
			table.insert(
				entries,
				table.freeze({
					ban = banned,
					reasonKey = reasonKey,
					startTime = tostring(e.StartTime),
					seconds = if type(e.Duration) == "number" then e.Duration else 0,
					placeId = if type(e.PlaceId) == "number" then e.PlaceId else 0,
				})
			)
		end
		historyCache[userId] = { at = t, entries = entries }
		return true, table.clone(entries)
	end

	function api.kick(target: any, opts2: any): (boolean, string)
		local act = actorOf(opts2, "Moderation.kick")
		if not isOn() then
			return false, "disabled"
		end
		local uid, here = targetOf(target)
		if uid == nil then
			return false, "invalid"
		end
		local text = opts2.text
		local key = opts2.key
		if text ~= nil then
			if not cfg().kick.allowFreeText or type(text) ~= "string" or text == "" then
				return false, "invalid"
			end
		end
		if key == nil then
			key = cfg().kick.presetKeys[1]
		end
		if type(key) ~= "string" or table.find(cfg().kick.presetKeys, key) == nil then
			return false, "invalid"
		end
		return kickImpl(act, uid, here, key, text, nil)
	end

	function api.serverBan(target: any, opts2: any): (boolean, string)
		local act = actorOf(opts2, "Moderation.serverBan")
		if not isOn() then
			return false, "disabled"
		end
		local uid, here = targetOf(target)
		if uid == nil then
			return false, "invalid"
		end
		local seconds = opts2.seconds or cfg().serverBan.defaultSeconds
		if
			type(seconds) ~= "number"
			or seconds ~= seconds
			or seconds <= 0
			or seconds > cfg().serverBan.maxSeconds
		then
			return false, "invalid"
		end
		local ok, reason = permit(act, "serverBan", "ban")
		if not ok then
			return refuse(act, "serverBan", uid, reason :: string)
		end
		ok, reason = rankCheck(act, uid, here)
		if not ok then
			return refuse(act, "serverBan", uid, reason :: string)
		end
		serverBans[uid] = ctx.now() + seconds
		if here ~= nil then
			kickHere(here, textFor(here, "Moderation.kick.serverBan"))
		end
		write(act, { action = "serverBan", target = uid, seconds = seconds })
		return true, "done"
	end

	function api.mute(target: any, opts2: any): (boolean, string)
		local act = actorOf(opts2, "Moderation.mute")
		if not isOn() then
			return false, "disabled"
		end
		local uid, here = targetOf(target)
		if uid == nil then
			return false, "invalid"
		end
		local seconds = opts2.seconds or cfg().mute.defaultSeconds
		if
			type(seconds) ~= "number"
			or seconds ~= seconds
			or seconds <= 0
			or seconds > cfg().mute.maxSeconds
		then
			return false, "invalid"
		end
		local key = opts2.key or cfg().mute.presetKeys[1]
		if type(key) ~= "string" or table.find(cfg().mute.presetKeys, key) == nil then
			return false, "invalid"
		end
		return muteImpl(act, uid, here, seconds, key, nil)
	end

	function api.unmute(target: any, opts2: any): (boolean, string)
		local act = actorOf(opts2, "Moderation.unmute")
		if not isOn() then
			return false, "disabled"
		end
		local uid, here = targetOf(target)
		if uid == nil then
			return false, "invalid"
		end
		return unmuteImpl(act, uid, here)
	end

	function api.isMuted(player: any): (boolean, number?)
		if not Actor.isPlayer(player) or not ctx.data.isLoaded(player) then
			return false, nil
		end
		local untilTs = ctx.data.get(player).mute.untilTs
		if type(untilTs) == "number" and untilTs > ctx.now() then
			return true, untilTs
		end
		return false, nil
	end

	function api.warn(target: any, opts2: any): (boolean, string)
		local act = actorOf(opts2, "Moderation.warn")
		if not isOn() then
			return false, "disabled"
		end
		local uid, here = targetOf(target)
		if uid == nil then
			return false, "invalid"
		end
		local key = opts2.key
		if type(key) ~= "string" or table.find(cfg().warn.presetKeys, key) == nil then
			return false, "invalid"
		end
		return warnImpl(act, uid, here, key, nil)
	end

	function api.punish(target: any, offense: string, opts2: any): (boolean, string, string?)
		local act = actorOf(opts2, "Moderation.punish")
		if not isOn() then
			return false, "disabled", nil
		end
		local uid, here = targetOf(target)
		if uid == nil or type(offense) ~= "string" or cfg().offenses[offense] == nil then
			return false, "invalid", nil
		end
		return punishImpl(act, uid, here, offense, nil)
	end

	local function sources(): { [string]: any }
		local out = table.clone(cfg().auto.sources)
		local extra = sc().autoSources
		if type(extra) == "table" then
			for name, src in extra do
				out[name] = src
			end
		end
		return out
	end

	-- the automatic hook: never yields (a crossing's punish is spawned), acts as "system"
	function api.report(player: any, source: string, severity: number, details: any?): boolean
		if not cfg().auto.enabled or not isOn() then
			return false
		end
		if type(source) ~= "string" then
			return false
		end
		local src = sources()[source]
		if src == nil then
			return false
		end
		if type(severity) ~= "number" or severity ~= severity or severity <= 0 or severity == math.huge then
			return false
		end
		local uid, here = targetOf(player)
		if uid == nil then
			return false
		end
		local t = ctx.now()
		local k = `{uid}|{source}`
		local w = windows[k]
		local events = {}
		if w ~= nil then
			for _, ev in w do
				if t - ev.at < src.windowSeconds then
					table.insert(events, ev)
				end
			end
		end
		table.insert(events, { at = t, severity = severity })
		local sum = 0
		for _, ev in events do
			sum += ev.severity
		end
		if sum >= src.threshold then
			windows[k] = nil
			local encoded = if details ~= nil then Util.json(details, cfg().audit.detailsMaxBytes) else nil
			task.spawn(function()
				local ok, err = pcall(function()
					punishImpl(
						{ kind = "system", by = "system", userId = 0 },
						uid,
						here,
						src.offense,
						{ source = source, details = encoded }
					)
				end)
				if not ok then
					ctx.log.warn(`report {source}: punish failed: {tostring(err)}`)
				end
			end)
		else
			windows[k] = events
		end
		return true
	end

	local function auditQuery(act: Act, q: any): (boolean, any, boolean?, boolean?)
		if act.kind == "system" then
			return false, "no_permission", nil, nil
		end
		local viewer: any = nil
		if act.kind == "staff" then
			local ok, reason = permit(act, "audit", "audit.read")
			if not ok then
				return false, reason, nil, nil
			end
			viewer = act.userId
		end
		return audit.query(viewer, q)
	end
	part.auditQuery = auditQuery

	function api.audit(opts2: any): (boolean, any)
		local act = actorOf(opts2, "Moderation.audit")
		local target = opts2.target
		if target ~= nil and not Util.isCount(target) then
			return false, "invalid"
		end
		local day = opts2.day
		if day ~= nil and (type(day) ~= "number" or day % 1 ~= 0 or day < 0) then
			return false, "invalid"
		end
		local limit = opts2.limit or cfg().panel.auditPageSize
		if not Util.isCount(limit) or limit > cfg().panel.auditMaxRows then
			return false, "invalid"
		end
		-- (Addendum G H2) a day read is paged: page n = the next audit.chunksPerRead chunks, newest
		-- first; the third value says older chunks exist
		local page = opts2.page or 1
		if not Util.isCount(page) then
			return false, "invalid"
		end
		local ok, list, more = auditQuery(act, { target = target, day = day, limit = limit, page = page })
		if not ok then
			return false, list
		end
		return true, list, more == true
	end

	-- (L20) an audit entry from another kit module; whitelisted actions only
	function api.record(entry: any, opts2: any): (boolean, string?)
		local act = actorOf(opts2, "Moderation.record")
		if type(entry) ~= "table" or table.find(Server.RECORD_ACTIONS, entry.action) == nil then
			return false, "invalid"
		end
		if entry.target ~= nil and not Util.isCount(entry.target) then
			return false, "invalid"
		end
		if entry.reasonKey ~= nil and not isKey(entry.reasonKey) then
			return false, "invalid"
		end
		if entry.note ~= nil and not isKey(entry.note) then
			return false, "invalid"
		end
		if entry.seconds ~= nil and (type(entry.seconds) ~= "number" or entry.seconds ~= entry.seconds) then
			return false, "invalid"
		end
		if entry.status ~= nil and not STATUSES[entry.status] then
			return false, "invalid"
		end
		write(act, {
			action = entry.action,
			target = entry.target,
			reasonKey = entry.reasonKey,
			note = entry.note,
			seconds = entry.seconds,
			status = entry.status,
		})
		return true, nil
	end

	api.signals = signals

	part.api = api
	part.actions = {}
	part.net = o.net

	--------------------------------------------------------------------------
	-- joins, leaves, ticks
	--------------------------------------------------------------------------

	local function holdOrAdmit(player: any)
		if cfg().onUnknownStatus == "hold" then
			kickHere(player, textFor(player, "Moderation.kick.hold"))
		else
			rechecks[player] = ctx.now() + cfg().unknownRecheckSeconds
		end
	end

	local function checkPending(player: any)
		local okCall, known, entry = pcall(pending.lookup, player.UserId)
		if not okCall or not known then
			holdOrAdmit(player)
			return
		end
		rechecks[player] = nil
		if type(entry) == "table" and entry.kind == "ban" then
			local full = if entry.displayKey ~= nil
				then entry
				else { displayKey = cfg().ban.defaultDisplayKey }
			kickHere(player, banMessage(player, full))
		end
	end

	local function onLoaded(player: any)
		online[player.UserId] = player
		local untilBan = serverBans[player.UserId]
		if untilBan ~= nil then
			if untilBan > ctx.now() then
				kickHere(player, textFor(player, "Moderation.kick.serverBan"))
				return
			end
			serverBans[player.UserId] = nil
		end
		local view = ctx.data.get(player)
		if view.mute.untilTs > ctx.now() then
			afterMute(player, view.mute.untilTs, nil, false)
		end
		task.spawn(checkPending, player)
	end

	local function onRemoving(player: any)
		if online[player.UserId] == player then
			online[player.UserId] = nil
		end
		muteUntil[player] = nil
		rechecks[player] = nil
		chat.forget(player.UserId)
	end

	local function tick()
		local t = ctx.now()
		for player, untilTs in muteUntil do
			if untilTs <= t then
				afterUnmute(player, true)
			end
		end
		for player, at in rechecks do
			if at <= t then
				rechecks[player] = nil
				task.spawn(checkPending, player)
			end
		end
		for uid, at in serverBans do
			if at <= t then
				serverBans[uid] = nil
			end
		end
		for k, events in windows do
			local last = events[#events]
			if last == nil or t - last.at > DAY then
				windows[k] = nil
			end
		end
		audit.tick()
		pending.tick()
		if t >= nextSweepAt then
			nextSweepAt = t + SWEEP_EVERY
			task.spawn(function()
				local ok, err = pcall(audit.sweep, SWEEP_EVERY)
				if not ok then
					ctx.log.warn(`audit sweep failed: {tostring(err)}`)
				end
			end)
		end
	end

	--------------------------------------------------------------------------
	-- lifecycle
	--------------------------------------------------------------------------

	function part.init(context: any)
		ctx = context
		local c = ctx.config
		if c.flag ~= nil then
			local ok, err = pcall(ctx.flags.isOn, c.flag)
			if not ok then
				error(`[Moderation] config.flag: {tostring(err)}`, 0)
			end
		end
		local errors = Check.config(c, ctx.serverConfig)
		if #errors > 0 then
			error("[Moderation] " .. table.concat(errors, "; "), 0)
		end
		created.Actioned = ctx.signals.new("Actioned")
		created.Muted = ctx.signals.new("Muted")
		created.Banned = ctx.signals.new("Banned")

		if type(o.jobId) == "string" and o.jobId ~= "" then
			job = o.jobId
		elseif not ctx.isStudio then
			local ok, id = pcall(function(): any
				return game.JobId
			end)
			if ok and type(id) == "string" and id ~= "" then
				job = id
			end
		end
		local okVersion, placeVersion = pcall(function(): any
			return game.PlaceVersion
		end)
		local map = ctx.data.sortedMap("pending")
		audit = Audit.new({
			shared = ctx.data.shared,
			map = map,
			cfg = c,
			now = ctx.now,
			job = job,
			log = ctx.log,
			placeVersion = if okVersion and type(placeVersion) == "number" then placeVersion else 0,
		})
		pending = Pending.new({
			shared = ctx.data.shared,
			map = map,
			cfg = c,
			now = ctx.now,
			job = job,
			log = ctx.log,
			call = callPlayers,
			done = function(entry: any, status: string, note: string?)
				local act: Act = {
					kind = if type(entry.byKind) == "string" then entry.byKind else "server",
					by = nil,
					userId = if type(entry.by) == "number" then entry.by else 0,
				}
				write(act, {
					action = entry.kind,
					target = entry.userId,
					reasonKey = entry.displayKey,
					privateReason = entry.auditPrivate,
					seconds = entry.seconds,
					offense = entry.offense,
					source = entry.source,
					status = status,
					note = note,
				})
				if status == "ok" and entry.kind == "ban" and created.Banned ~= nil then
					created.Banned:Fire(entry.userId, entry.seconds)
				end
			end,
		})
		chat = Chat.new({
			textChat = c.mute.textChat,
			voice = c.mute.voice,
			service = function(): any
				return ctx.services.get("TextChatService")
			end,
			log = ctx.log,
		})

		ctx.data.messages.onReceive(function(player: any, payload: any, processed: () -> ())
			task.spawn(receive, player, payload, processed)
		end)

		if adminOn() then
			Panel.register(ctx.depsExt[Admin], {
				api = api,
				cfg = c,
				write = write,
				auditQuery = auditQuery,
				findOnline = findOnline,
				adminApi = function(): any
					return ctx.deps[Admin]
				end,
			})
		end
		Console.register(ctx.console, api)
	end

	function part.start(_context: any)
		local players = playersService()
		local okEnabled, enabled = pcall(function(): any
			return players.BanningEnabled
		end)
		if okEnabled and enabled == false and not warnedBanning then
			warnedBanning = true
			ctx.log.warn(
				"Players.BanningEnabled is off: every ban will fail. Turn it on in Studio (Players properties)."
			)
		end
		chat.start()
		ctx.data.onLoaded(onLoaded)
		ctx.lifecycle.onPlayerRemoving(onRemoving)
		ctx.lifecycle.onTick(1, function()
			tick()
		end)
		ctx.lifecycle.onShutdown(function()
			local deadline = os.clock() + cfg().audit.shutdownSeconds
			pcall(pending.shutdown, deadline)
			pcall(audit.flush, deadline)
			chat.stop()
		end)
	end

	-- read-only views for specs
	function part.debug(): any
		return {
			job = job,
			audit = audit,
			pending = pending,
			chat = chat,
			serverBans = serverBans,
		}
	end

	return part
end

return Server
