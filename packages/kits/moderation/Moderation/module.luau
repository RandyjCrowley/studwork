--!strict
--[[
	Moderation module definition (kit: moderation, v1.0.0). Bans through Players:BanAsync (retried
	while Roblox is unreachable), kicks, this-server bans, mutes, warnings, offence ladders, the
	automatic `report` hook and the audit log. Design: docs/framework/kits/moderation.md
	(Moderation, Audit log, Cross-server behaviour).

	Save section "moderation" (v1) = { mute = { untilTs, reasonKey }, strikes = { { offense, at,
	step } }, warnings, seen = { messageId } (capped) }, NOT replicated: the player's own mute end
	reaches their client as extra.muted (ctx.replicate.set).
	Strings: Moderation.* (ban/kick/warn/mute presets, notices, the Audit tab, history). Ban and
	kick messages are keys; Moderation.ban.appeal is the appeal line appended to every ban message
	(set it in GameConfig.strings).

	config (GameConfig.config.Moderation): flag, ban, kick, serverBan, mute, warn, ladders, offenses,
	strikes, auto, audit, retry, crossServer, pending, history, onUnknownStatus (the page's table).
	Ladders, offences and auto sources are checked by the server part at init.
	ServerConfig.Moderation (server-only): admins = { userId }? (the fallback staff list while
	Admin is off), autoSources (merged over config.auto.sources).

	optional: Admin (permissions, ranks, panel actions and the Audit tab), TextFilter (free text).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Admin = require(Modules:WaitForChild("Admin"):WaitForChild("module"))
local TextFilter = require(Modules:WaitForChild("TextFilter"):WaitForChild("module"))

-- Who acts (design B5): REQUIRED on every mutating call. A Player = a staff request (permission
-- and rank checked); "server" = game code; "console" = a console line with no player; "system" =
-- automatic (only config.auto.permissions).
export type Actor = Player | "server" | "console" | "system"

-- One audit log entry (Moderation.audit, the Actioned signal, the Audit tab).
export type AuditEntry = {
	id: string,
	at: number,
	server: string, -- the JobId, or "studio"
	placeVersion: number,
	by: number, -- the staff member's UserId; 0 = server, console or system
	byKind: "staff" | "server" | "system" | "console",
	target: number?,
	action: string,
	reasonKey: string?,
	privateReason: string?, -- filtered, capped (audit.privateReasonMax), staff-only
	seconds: number?,
	offense: string?,
	source: string?,
	status: "ok" | "pending" | "failed" | "refused",
	note: string?, -- a strings key
	details: string?, -- (added by the module builder) report details, JSON, at most audit.detailsMaxBytes
	amount: number?, -- (added by the integration builder) Admin's grant: the amount granted
	currency: string?, -- (added by the integration builder) Admin's grant: the currency id
}

export type BanOpts = {
	by: Actor,
	seconds: number?, -- nil or -1 = permanent (needs ban.permanent)
	displayKey: string?,
	displayText: string?,
	privateReason: string?,
	offense: string?,
}

export type HistoryEntry = {
	ban: boolean,
	reasonKey: string, -- a preset key whose English matches Roblox's DisplayReason, else Moderation.history.custom
	startTime: string,
	seconds: number,
	placeId: number,
}

-- The server API (StudWork.use(Moderation) / ctx.deps[Moderation]). Mutating calls return
-- (ok, status | reason): statuses "banned" | "unbanned" | "pending" | "done" | "sent";
-- reasons "no_permission" | "outranked" | "invalid" | "disabled" | "rate_limited" |
-- "too_long_for_role" | "unknown_rank" | "failed" | "unavailable" | "no_filter".
export type API = {
	ban: (target: Player | number, opts: BanOpts) -> (boolean, string),
	unban: (userId: number, opts: { by: Actor, privateReason: string? }) -> (boolean, string),
	history: (userId: number, opts: { by: Actor }) -> (boolean, any),
	kick: (target: Player | number, opts: { by: Actor, key: string?, text: string? }) -> (boolean, string),
	serverBan: (target: Player | number, opts: { by: Actor, seconds: number? }) -> (boolean, string),
	mute: (target: Player | number, opts: { by: Actor, seconds: number?, key: string? }) -> (boolean, string),
	unmute: (target: Player | number, opts: { by: Actor }) -> (boolean, string),
	isMuted: (player: Player) -> (boolean, number?),
	warn: (target: Player | number, opts: { by: Actor, key: string }) -> (boolean, string),
	punish: (target: Player | number, offense: string, opts: { by: Actor }) -> (boolean, string, string?),
	report: (
		player: Player | number,
		source: string,
		severity: number,
		details: { [string]: any }?
	) -> boolean,
	-- (Addendum G) opts.page (1..): a day read is paged by audit.chunksPerRead chunks, newest first;
	-- the third value is true when older chunks exist
	audit: (
		opts: { by: Actor, target: number?, day: number?, limit: number?, page: number? }
	) -> (boolean, any, boolean?),
	record: (
		entry: {
			action: string,
			target: number?,
			reasonKey: string?,
			note: string?,
			seconds: number?,
			status: string?,
		},
		opts: { by: Actor }
	) -> boolean,
	signals: { Actioned: any, Muted: any, Banned: any },
}

-- The client API (StudWork.use(Moderation) on the client).
export type ClientAPI = {
	isMuted: () -> (boolean, number?),
	-- (added by the module builder) a game's own notice UI: fn(key, args) for every Notice
	onNotice: (fn: (key: string, args: { [string]: any }) -> ()) -> any,
}

local MINUTE = 60
local HOUR = 3600
local DAY = 86400

local DEFAULT_LADDER = {
	{ action = "warn" },
	{ action = "mute", seconds = 10 * MINUTE },
	{ action = "kick" },
	{ action = "ban", seconds = DAY },
}

return StudWork.defineModule({
	name = "Moderation",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Bans, kicks, mutes, warnings, offence ladders and the audit log (moderation kit)",
	optional = { Admin, TextFilter },
	config = {
		schema = {
			flag = "string?",
			ban = {
				excludeAltAccounts = "boolean",
				applyDeviceBlock = "boolean",
				displayKeys = "{string}",
				allowFreeDisplay = "boolean",
				maxDisplayLength = "integer(1..400)",
				defaultDisplayKey = "string",
			},
			kick = { presetKeys = "{string}", allowFreeText = "boolean", maxLength = "integer(1..500)" },
			serverBan = { defaultSeconds = "number(1..)", maxSeconds = "number(1..)" },
			mute = {
				defaultSeconds = "number(1..)",
				maxSeconds = "number(1..)",
				textChat = "boolean",
				voice = "boolean",
				presetKeys = "{string}",
			},
			warn = { presetKeys = "{string}" },
			ladders = "{[string]: {table}}",
			offenses = "{[string]: table}",
			strikes = { decayDays = "number(0..)", max = "integer(1..)" },
			auto = { enabled = "boolean", permissions = "{string}", sources = "{[string]: table}" },
			audit = {
				retentionDays = "integer(1..90)",
				perTargetMax = "integer(1..)",
				flushSeconds = "number(1..)",
				chunkSize = "integer(1..)",
				bufferMax = "integer(1..)",
				readSecondsPerStaff = "number(0..)",
				readCacheSeconds = "number(0..)",
				privateReasonMax = "integer(0..1000)",
				detailsMaxBytes = "integer(0..)",
				refusedEverySeconds = "number(0..)",
				shutdownSeconds = "number(0..)",
				chunksPerRead = "integer(1..)",
			},
			retry = {
				base = "number(0..)",
				factor = "number(1..)",
				max = "number(1..)",
				maxAttempts = "integer(1..)",
			},
			crossServer = { kickMaxAgeSeconds = "number(1..)", perTargetPerHour = "integer(1..)" },
			pending = { indexExpiryDays = "number(1..)", pollSeconds = "number(1..)" },
			unknownRecheckSeconds = "number(1..)",
			panel = {
				banDurations = "{number}",
				muteDurations = "{number}",
				serverBanDurations = "{number}",
				auditPageSize = "integer(1..100)",
				auditMaxRows = "integer(1..1000)",
			},
			history = { cacheSeconds = "number(0..)" },
			onUnknownStatus = '"admit"|"hold"',
		},
		defaults = {
			ban = {
				excludeAltAccounts = false,
				applyDeviceBlock = false,
				displayKeys = {
					"Moderation.ban.rules",
					"Moderation.ban.cheating",
					"Moderation.ban.harassment",
				},
				allowFreeDisplay = false,
				maxDisplayLength = 200,
				defaultDisplayKey = "Moderation.ban.rules",
			},
			kick = {
				presetKeys = { "Moderation.kick.generic", "Moderation.kick.rules" },
				allowFreeText = false,
				maxLength = 500,
			},
			serverBan = { defaultSeconds = HOUR, maxSeconds = DAY },
			mute = {
				defaultSeconds = 10 * MINUTE,
				maxSeconds = 7 * DAY,
				textChat = true,
				voice = false,
				presetKeys = { "Moderation.mute.generic", "Moderation.mute.spam", "Moderation.mute.language" },
			},
			warn = {
				presetKeys = {
					"Moderation.warn.rules",
					"Moderation.warn.language",
					"Moderation.warn.cheating",
				},
			},
			ladders = { default = DEFAULT_LADDER },
			offenses = {
				cheating = { ladder = "default", displayKey = "Moderation.ban.cheating" },
				harassment = { ladder = "default", displayKey = "Moderation.ban.harassment" },
				rules = { ladder = "default", displayKey = "Moderation.ban.rules" },
			},
			strikes = { decayDays = 30, max = 20 },
			auto = { enabled = true, permissions = { "warn", "mute", "kick" }, sources = {} },
			audit = {
				retentionDays = 30,
				perTargetMax = 30,
				flushSeconds = 15,
				chunkSize = 100,
				bufferMax = 500,
				readSecondsPerStaff = 5,
				readCacheSeconds = 30,
				privateReasonMax = 300,
				detailsMaxBytes = 200,
				refusedEverySeconds = HOUR,
				shutdownSeconds = 5,
				-- (Addendum G) chunk keys one day read touches (plus the day directory); older pages on demand
				chunksPerRead = 4,
			},
			retry = { base = 5, factor = 2, max = 300, maxAttempts = 20 },
			crossServer = { kickMaxAgeSeconds = 600, perTargetPerHour = 5 },
			pending = { indexExpiryDays = 7, pollSeconds = 60 },
			-- onUnknownStatus = "admit": how often a let-in player's pending-ban status is read again
			unknownRecheckSeconds = 30,
			-- the choices the Admin panel offers (-1 = permanent ban); auditMaxRows = the most rows one
			-- audit read returns
			panel = {
				banDurations = { HOUR, DAY, 7 * DAY, -1 },
				muteDurations = { 5 * MINUTE, 10 * MINUTE, HOUR, DAY },
				serverBanDurations = { 10 * MINUTE, HOUR, DAY },
				auditPageSize = 20,
				auditMaxRows = 200,
			},
			history = { cacheSeconds = 60 },
			onUnknownStatus = "admit",
		},
	},
	data = {
		key = "moderation",
		version = 1,
		default = { mute = { untilTs = 0, reasonKey = "" }, strikes = {}, warnings = 0, seen = {} },
		replicate = false,
	},
	-- English defaults; one Moderation.offense.<id> per configured offence (English = the id)
	-- unless listed here
	strings = function(config: any): { [string]: string }
		local out: { [string]: string } = {
			["Moderation.ban.rules"] = "You broke the game rules.",
			["Moderation.ban.cheating"] = "Cheating or exploiting.",
			["Moderation.ban.harassment"] = "Harassing other players.",
			["Moderation.ban.appeal"] = "To appeal, contact the game's support.",
			["Moderation.kick.generic"] = "You were removed from this server.",
			["Moderation.kick.rules"] = "You were removed for breaking the game rules.",
			["Moderation.kick.banned"] = "You are banned from this game.",
			["Moderation.kick.serverBan"] = "You can't join this server right now.",
			["Moderation.kick.hold"] = "We couldn't check your account right now. Please try again in a minute.",
			["Moderation.warn.title"] = "Warning",
			["Moderation.warn.rules"] = "Please follow the game rules.",
			["Moderation.warn.language"] = "Please keep your language friendly.",
			["Moderation.warn.cheating"] = "Cheating isn't allowed. Next time you may be removed.",
			["Moderation.mute.generic"] = "You were muted.",
			["Moderation.mute.spam"] = "You were muted for spamming.",
			["Moderation.mute.language"] = "You were muted for your language.",
			["Moderation.mute.until"] = "You can chat again in {minutes} min.",
			["Moderation.mute.ended"] = "You can chat again.",
			["Moderation.notice.ok"] = "OK",
			["Moderation.history.custom"] = "Custom reason",
			["Moderation.history.ban"] = "Ban",
			["Moderation.history.unban"] = "Unban",
			["Moderation.action.ban"] = "Ban",
			["Moderation.action.unban"] = "Unban",
			["Moderation.action.kick"] = "Kick",
			["Moderation.action.serverBan"] = "Server ban",
			["Moderation.action.mute"] = "Mute",
			["Moderation.action.unmute"] = "Unmute",
			["Moderation.action.warn"] = "Warn",
			["Moderation.action.punish"] = "Punish",
			["Moderation.action.history"] = "Ban history",
			["Moderation.tab.audit"] = "Audit",
			["Moderation.column.at"] = "When",
			["Moderation.column.by"] = "By",
			["Moderation.column.target"] = "Player",
			["Moderation.column.action"] = "Action",
			["Moderation.column.reason"] = "Reason",
			["Moderation.column.status"] = "Status",
			["Moderation.status.ok"] = "Done",
			["Moderation.status.pending"] = "Pending",
			["Moderation.status.failed"] = "Failed",
			["Moderation.status.refused"] = "Refused",
			["Moderation.note.staleKick"] = "The kick arrived too late and was dropped",
			["Moderation.note.sendFailed"] = "The message to the player's server failed",
			["Moderation.note.retriesExhausted"] = "Roblox kept refusing; gave up",
			["Moderation.note.takeover"] = "Finished by another server",
			["Moderation.note.sent"] = "Sent to the player's server",
			["Moderation.note.pendingUnsaved"] = "Pending, kept by this server only (the store was down)",
			["Moderation.notice.title"] = "Notice",
			["Moderation.result.banned"] = "Banned.",
			["Moderation.result.unbanned"] = "Unbanned.",
			["Moderation.result.pending"] = "Roblox is busy: it will be retried.",
			["Moderation.result.done"] = "Done.",
			["Moderation.result.sent"] = "Sent to the player's server.",
			["Moderation.result.warn"] = "Warned.",
			["Moderation.result.mute"] = "Muted.",
			["Moderation.result.kick"] = "Kicked.",
			["Moderation.result.ban"] = "Banned.",
			["Moderation.result.no_permission"] = "You can't do that.",
			["Moderation.result.outranked"] = "You can't act on this player.",
			["Moderation.result.unknown_rank"] = "Couldn't check this player's role. Try again later.",
			["Moderation.result.invalid"] = "Check the choices and try again.",
			["Moderation.result.disabled"] = "Moderation is switched off.",
			["Moderation.result.rate_limited"] = "Too many actions. Wait a moment.",
			["Moderation.result.too_long_for_role"] = "That's longer than your role allows.",
			["Moderation.result.failed"] = "Roblox refused it.",
			["Moderation.result.unavailable"] = "Not available here.",
			["Moderation.result.no_filter"] = "Text needs the text filter.",
			["Moderation.offense.cheating"] = "Cheating",
			["Moderation.offense.harassment"] = "Harassment",
			["Moderation.offense.rules"] = "Breaking the rules",
		}
		local offenses = if type(config) == "table" then config.offenses else nil
		if type(offenses) == "table" then
			for id in offenses do
				if type(id) == "string" and string.match(id, "^[%w_]+$") ~= nil and #id <= 32 then
					local key = "Moderation.offense." .. id
					if out[key] == nil then
						out[key] = id
					end
				end
			end
		end
		return out
	end,
	client = "Moderation",
})
