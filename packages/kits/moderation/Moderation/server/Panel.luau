--!strict
--[[
	Moderation's part of the Admin panel (design §3, §4: "Moderation calls Admin's registerAction /
	registerTab / registerAuditSink in init when Admin is enabled").

	  Panel.register(ext, deps)   ext = ctx.depsExt[Admin]; deps = { api, cfg, write, auditQuery,
	                              findOnline, adminApi }

	Actions (Admin checks the permission with can before `run`, design §11; every run re-validates its
	arguments here and goes through the same Moderation API as server code, with by = the staff
	member): ban, unban, kick, serverban, mute, unmute, warn, punish. A run answers
	(ok, "Moderation.result.<status or reason>"), a strings key the panel shows.
	Tab "audit" (audit.read): the day's audit, config.panel.auditPageSize rows a page, read a chunk
	page (audit.chunksPerRead chunks, newest first) at a time: at most one store read per request.
	Audit sink: Admin's own actions (teleport, announce, grant, ...) land in the same audit log.
]]

local Panel = {}

local ACTION_ID = "^[%w_%.]+$"
local STATUSES = { ok = true, pending = true, failed = true, refused = true }
local BY_KINDS = { staff = true, server = true, console = true, system = true }

Panel.COLUMNS = table.freeze({
	"Moderation.column.at",
	"Moderation.column.by",
	"Moderation.column.target",
	"Moderation.column.action",
	"Moderation.column.reason",
	"Moderation.column.status",
})

local function result(ok: boolean, status: string): (boolean, string)
	return ok, "Moderation.result." .. status
end

local function offered(list: { number }, value: any): boolean
	return type(value) == "number" and table.find(list, value) ~= nil
end

function Panel.row(e: any): { [string]: string | number | boolean }
	return {
		["Moderation.column.at"] = e.at or 0,
		["Moderation.column.by"] = e.by or 0,
		["Moderation.column.target"] = e.target or 0,
		["Moderation.column.action"] = tostring(e.action),
		["Moderation.column.reason"] = e.reasonKey or e.note or "",
		["Moderation.column.status"] = "Moderation.status." .. tostring(e.status),
	}
end

function Panel.register(ext: any, deps: any)
	local api = deps.api
	local cfg = deps.cfg
	local panel = cfg.panel

	local function target(userId: any): any
		if type(userId) ~= "number" then
			return nil
		end
		return deps.findOnline(userId) or userId
	end

	local offenseByKey: { [string]: string } = {}
	local offenseKeys: { string } = {}
	for id in cfg.offenses do
		local key = "Moderation.offense." .. id
		offenseByKey[key] = id
		table.insert(offenseKeys, key)
	end
	table.sort(offenseKeys)

	ext.registerAction({
		id = "ban",
		permission = "ban",
		labelKey = "Moderation.action.ban",
		target = "userId",
		presets = cfg.ban.displayKeys,
		durations = panel.banDurations,
		freeText = cfg.ban.allowFreeDisplay,
		run = function(staff: any, userId: number?, args: any): (boolean, string?)
			local t = target(userId)
			if t == nil or not offered(panel.banDurations, args.duration) then
				return result(false, "invalid")
			end
			return result(api.ban(t, {
				by = staff,
				seconds = if args.duration == -1 then nil else args.duration,
				displayKey = args.preset,
				displayText = args.text,
			}))
		end,
	})
	ext.registerAction({
		id = "unban",
		permission = "ban",
		labelKey = "Moderation.action.unban",
		target = "userId",
		run = function(staff: any, userId: number?, _args: any): (boolean, string?)
			if type(userId) ~= "number" then
				return result(false, "invalid")
			end
			return result(api.unban(userId, { by = staff }))
		end,
	})
	ext.registerAction({
		id = "kick",
		permission = "kick",
		labelKey = "Moderation.action.kick",
		target = "userId",
		presets = cfg.kick.presetKeys,
		freeText = cfg.kick.allowFreeText,
		run = function(staff: any, userId: number?, args: any): (boolean, string?)
			local t = target(userId)
			if t == nil then
				return result(false, "invalid")
			end
			return result(api.kick(t, { by = staff, key = args.preset, text = args.text }))
		end,
	})
	ext.registerAction({
		id = "serverban",
		permission = "ban",
		labelKey = "Moderation.action.serverBan",
		target = "player",
		durations = panel.serverBanDurations,
		run = function(staff: any, userId: number?, args: any): (boolean, string?)
			local t = target(userId)
			if t == nil or not offered(panel.serverBanDurations, args.duration) then
				return result(false, "invalid")
			end
			return result(api.serverBan(t, { by = staff, seconds = args.duration }))
		end,
	})
	ext.registerAction({
		id = "mute",
		permission = "mute",
		labelKey = "Moderation.action.mute",
		target = "userId",
		presets = cfg.mute.presetKeys,
		durations = panel.muteDurations,
		run = function(staff: any, userId: number?, args: any): (boolean, string?)
			local t = target(userId)
			if t == nil or not offered(panel.muteDurations, args.duration) then
				return result(false, "invalid")
			end
			return result(api.mute(t, { by = staff, seconds = args.duration, key = args.preset }))
		end,
	})
	ext.registerAction({
		id = "unmute",
		permission = "mute",
		labelKey = "Moderation.action.unmute",
		target = "userId",
		run = function(staff: any, userId: number?, _args: any): (boolean, string?)
			local t = target(userId)
			if t == nil then
				return result(false, "invalid")
			end
			return result(api.unmute(t, { by = staff }))
		end,
	})
	ext.registerAction({
		id = "warn",
		permission = "warn",
		labelKey = "Moderation.action.warn",
		target = "userId",
		presets = cfg.warn.presetKeys,
		run = function(staff: any, userId: number?, args: any): (boolean, string?)
			local t = target(userId)
			if t == nil then
				return result(false, "invalid")
			end
			return result(api.warn(t, { by = staff, key = args.preset }))
		end,
	})
	ext.registerAction({
		id = "punish",
		permission = "warn",
		labelKey = "Moderation.action.punish",
		target = "userId",
		presets = offenseKeys,
		run = function(staff: any, userId: number?, args: any): (boolean, string?)
			local t = target(userId)
			local offense = if type(args.preset) == "string" then offenseByKey[args.preset] else nil
			if t == nil or offense == nil then
				return result(false, "invalid")
			end
			local ok, stepOrReason, status = api.punish(t, offense, { by = staff })
			return result(ok, if ok then status or stepOrReason else stepOrReason)
		end,
	})

	ext.registerTab({
		id = "audit",
		permission = "audit.read",
		labelKey = "Moderation.tab.audit",
		fetch = function(staff: any, page: number): any
			local size = panel.auditPageSize
			local p = if type(page) == "number" and page >= 1 and page % 1 == 0 then page else 1
			-- Admin's Fetch already counted this request (Admin.allow, design §11)
			local act = { kind = "staff", by = staff, userId = staff.UserId, player = staff, counted = true }
			-- (Addendum G H2) the day is read a chunk page at a time (audit.chunksPerRead chunks, newest
			-- first); tab page p walks the chunk pages from the read cache and reads the store at most
			-- once per request
			local audit = cfg.audit
			local all = audit.chunksPerRead * audit.chunkSize + audit.bufferMax
			local wanted = p * size
			local entries: { any } = {}
			local chunkPage = 1
			local readOnce = false
			while #entries < wanted do
				local ok, list, more, fromStore =
					deps.auditQuery(act, { limit = all, page = chunkPage, cacheOnly = readOnce })
				if not ok then
					break
				end
				readOnce = readOnce or fromStore == true
				for _, e in list do
					table.insert(entries, e)
				end
				if not more then
					break
				end
				chunkPage += 1
			end
			local rows = {}
			for i = (p - 1) * size + 1, math.min(wanted, #entries) do
				table.insert(rows, Panel.row(entries[i]))
			end
			return { rows = rows, columns = table.clone(Panel.COLUMNS) }
		end,
	})

	ext.registerAuditSink(function(rec: any)
		if type(rec) ~= "table" or type(rec.action) ~= "string" or #rec.action > 32 then
			return
		end
		if string.match(rec.action, ACTION_ID) == nil then
			return
		end
		local kind = if BY_KINDS[rec.byKind] then rec.byKind else "server"
		deps.write({ kind = kind, by = nil, userId = if type(rec.by) == "number" then rec.by else 0 }, {
			action = rec.action,
			target = if type(rec.target) == "number" then rec.target else nil,
			reasonKey = if type(rec.reasonKey) == "string" and #rec.reasonKey <= 64
				then rec.reasonKey
				else nil,
			note = if type(rec.note) == "string" and #rec.note <= 64 then rec.note else nil,
			seconds = if type(rec.seconds) == "number" then rec.seconds else nil,
			-- Admin's grant: kept in the entry (a finite number, a short currency id)
			amount = if type(rec.amount) == "number"
					and rec.amount == rec.amount
					and math.abs(rec.amount) < math.huge
				then rec.amount
				else nil,
			currency = if type(rec.currency) == "string"
					and string.match(rec.currency, "^[%w_]+$") ~= nil
					and #rec.currency <= 32
				then rec.currency
				else nil,
			status = if STATUSES[rec.status] then rec.status else "ok",
		})
	end)
end

return Panel
