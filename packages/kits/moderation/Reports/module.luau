--!strict
--[[
	Reports module definition (kit: moderation, v1.0.0). Players report players (in this server, or
	who left it recently); rate-limited, duplicates merged per target, reporters never shown to
	other players; the staff queue is an Admin tab. Design: docs/framework/kits/moderation.md
	(Reports).

	Save section "reports" (v1) = { sent = { { target, at } } } (the reporter's own, capped by
	limits.sentMax: durable cross-server reporter limits), NOT replicated.
	Replicated: extra.recent (setAll: { { userId, name } } of players who left this server in the
	last recentSeconds; names only, no reporter info).
	Strings: Reports.* (the screen, categories Reports.category.<id>, the staff tab, resolutions).

	config (GameConfig.config.Reports): flag, categories, note, limits, recentSeconds,
	contextMaxBytes, queue, autoAction, blockPrompt (the page's table).
	ServerConfig.Reports (server-only): admins = { userId }? (the fallback staff list while Admin
	is off).

	optional: Admin (permissions, the queue tab), Moderation (audit entries, autoAction),
	TextFilter (notes; without it notes are dropped and the report is still filed).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Admin = require(Modules:WaitForChild("Admin"):WaitForChild("module"))
local Moderation = require(Modules:WaitForChild("Moderation"):WaitForChild("module"))
local TextFilter = require(Modules:WaitForChild("TextFilter"):WaitForChild("module"))

-- Who acts (design B5): REQUIRED on every staff call (queue, claim, resolve).
export type Actor = Player | "server" | "console" | "system"

export type Resolution = "actioned" | "no_action" | "dismissed"

-- One merged report (one per target while open). `reporters` and `notes` are staff-only;
-- reporters are shown only with reports.reporters (others see `count`).
export type Report = {
	id: string,
	at: number,
	target: number,
	targetName: string,
	category: string,
	reporters: { number },
	count: number,
	notes: { string }, -- filtered, unattributed
	server: string, -- JobId
	placeVersion: number,
	context: { [string]: string | number | boolean }?,
	status: "open" | "claimed" | "resolved",
	claimedBy: number?,
	resolvedBy: number?,
	resolution: Resolution?,
	resolvedAt: number?,
}

export type RecentPlayer = { userId: number, name: string }

export type ContextFn = (targetUserId: number, target: Player?) -> { [string]: string | number | boolean }?

-- The server API (StudWork.use(Reports) / ctx.deps[Reports]).
export type API = {
	submit: (reporter: Player, targetUserId: number, category: string, note: string?) -> (boolean, string?),
	queue: (opts: { by: Actor, status: string?, limit: number? }) -> (boolean, any),
	-- (builder addition) the full record of one report (needs reports.read; reporters only with
	-- reports.reporters): the one place notes are read
	detail: (reportId: string, opts: { by: Actor }) -> (boolean, any),
	claim: (reportId: string, opts: { by: Actor }) -> (boolean, string?),
	resolve: (
		reportId: string,
		resolution: Resolution,
		opts: { by: Actor, note: string? }
	) -> (boolean, string?),
	registerContext: (fn: ContextFn) -> (),
	signals: { Submitted: any, Resolved: any },
}

export type Extensions = {
	registerContext: (fn: ContextFn) -> (),
}

-- The client API (StudWork.use(Reports) on the client).
export type ClientAPI = {
	open: (targetUserId: number?) -> (),
	recent: () -> { RecentPlayer },
	read: any, -- (builder addition) the Report screen's pure view state (client/State.luau)
	actions: { submit: (targetUserId: number, category: string, note: string?) -> () },
}

local HOUR = 3600

local CATEGORIES = { "cheating", "harassment", "inappropriate", "scam", "other" }

return StudWork.defineModule({
	name = "Reports",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Players report players; rate-limited, reporters private, a staff queue (moderation kit)",
	optional = { Admin, Moderation, TextFilter },
	config = {
		schema = {
			flag = "string?",
			categories = "{string}",
			note = { enabled = "boolean", maxLength = "integer(0..200)" },
			limits = {
				perReporterPerHour = "integer(1..)",
				perReporterPerDay = "integer(1..)",
				perPairPerDay = "integer(1..)",
				perTargetPerDay = "integer(1..)",
				sentMax = "integer(1..)",
			},
			recentSeconds = "number(0..)",
			contextMaxBytes = "integer(0..)",
			queue = { maxOpen = "integer(1..)", indexExpiryDays = "number(1..)" },
			autoAction = {
				enabled = "boolean",
				distinctReporters = "integer(1..)",
				windowSeconds = "number(1..)",
				source = "string",
				severity = "number(0..)",
			},
			blockPrompt = "boolean",
		},
		defaults = {
			categories = CATEGORIES,
			note = { enabled = true, maxLength = 120 },
			limits = {
				perReporterPerHour = 5,
				perReporterPerDay = 15,
				perPairPerDay = 1,
				perTargetPerDay = 30,
				sentMax = 50,
			},
			recentSeconds = 600,
			contextMaxBytes = 600,
			queue = { maxOpen = 300, indexExpiryDays = 7 },
			autoAction = {
				enabled = false,
				distinctReporters = 5,
				windowSeconds = HOUR / 2,
				source = "reports",
				severity = 1,
			},
			blockPrompt = true,
		},
	},
	data = {
		key = "reports",
		version = 1,
		default = { sent = {} },
		replicate = false,
	},
	-- English defaults; one Reports.category.<id> per configured category (English = the id)
	-- unless listed here
	strings = function(config: any): { [string]: string }
		local out: { [string]: string } = {
			["Reports.title"] = "Report a player",
			["Reports.open"] = "Report",
			["Reports.pick"] = "Who do you want to report?",
			["Reports.recent"] = "Left recently",
			["Reports.inServer"] = "In this server",
			["Reports.noPlayers"] = "Nobody to report right now",
			["Reports.why"] = "What happened?",
			["Reports.note"] = "Add a note (optional)",
			["Reports.submit"] = "Send report",
			["Reports.cancel"] = "Cancel",
			["Reports.back"] = "Back",
			["Reports.done"] = "Done",
			["Reports.thanks"] = "Thanks! Our team will look at your report.",
			["Reports.disabled"] = "Reports are switched off right now",
			["Reports.block"] = "Block this player too?",
			["Reports.category.cheating"] = "Cheating or exploiting",
			["Reports.category.harassment"] = "Bullying or harassment",
			["Reports.category.inappropriate"] = "Inappropriate behaviour",
			["Reports.category.scam"] = "Scamming",
			["Reports.category.other"] = "Something else",
			["Reports.tab.queue"] = "Reports",
			["Reports.column.at"] = "When",
			["Reports.column.target"] = "Player",
			["Reports.column.category"] = "Category",
			["Reports.column.count"] = "Reports",
			["Reports.column.reporters"] = "Reporters",
			["Reports.column.notes"] = "Notes",
			["Reports.column.status"] = "Status",
			["Reports.status.open"] = "Open",
			["Reports.status.claimed"] = "Claimed",
			["Reports.status.resolved"] = "Resolved",
			["Reports.action.claim"] = "Claim",
			["Reports.action.resolve"] = "Resolve",
			["Reports.resolution.actioned"] = "Action taken",
			["Reports.resolution.no_action"] = "No rule broken",
			["Reports.resolution.dismissed"] = "Dismissed",
			["Reports.resolveNote.actioned"] = "Action taken",
			["Reports.resolveNote.noViolation"] = "No rule broken",
			["Reports.resolveNote.duplicate"] = "Duplicate report",
			["Reports.resolveNote.insufficient"] = "Not enough to go on",
		}
		local categories = if type(config) == "table" then config.categories else nil
		if type(categories) == "table" then
			for _, id in categories do
				if type(id) == "string" and string.match(id, "^[%w_]+$") ~= nil and #id <= 32 then
					local key = "Reports.category." .. id
					if out[key] == nil then
						out[key] = id
					end
				end
			end
		end
		return out
	end,
	client = "Reports",
})
