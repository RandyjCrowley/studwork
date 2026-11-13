--!strict
--[[
	Admin module definition (kit: moderation, v1.0.0). Staff roles and permissions (ServerConfig
	users and group rules), the per-staff limits, and the staff panel the other moderation modules
	register into. Design: docs/framework/kits/moderation.md (Admin).

	No save section: roles come from ServerConfig.Admin and group lookups each session.
	Replicated: extra.staff, set ONLY for staff players (ctx.replicate.set, never setAll); a
	non-staff player has no `staff` key at all.

	config (GameConfig.config.Admin): flag, roles, studioRole, groupCacheSeconds,
	groupLookupsPerMinute, groupRetrySeconds, refusedAuditSeconds, limits, panel, grant, announce,
	shutdown (the page's table). `roles` is checked by the server part at init (rank 1..1000,
	permissions, maxBanSeconds, maxMuteSeconds, label).
	ServerConfig.Admin (server-only): users = { [userId] = role }, groups = { { groupId, roles = {
	{ roleId?, minRank?, role } } } }.

	optional: Economy (only the built-in grant action), TextFilter (Addendum F: free panel text,
	announcements, through TextFilter "public"). Admin never names Moderation or Reports:
	they register their actions, tabs and the audit sink through Admin's extensions in init.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))
local TextFilter =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TextFilter"):WaitForChild("module"))

-- The arguments a panel action receives (every one a request from a client: `run` re-validates).
export type ActionArgs = {
	preset: string?,
	duration: number?,
	text: string?,
	-- (M18) the grant action's amount and currency ride in `duration` / `preset` on the wire;
	-- an action that takes an amount gets it here (1..config.Admin.grant.max), not in `duration`
	amount: number?,
	note: string?, -- a row action's picked note key (RowAction.notes)
}

-- A panel action (registerAction). `id` matches [%w_]{1,32}; `labelKey` is a strings key.
export type ActionDef = {
	id: string,
	permission: string,
	labelKey: string,
	target: "player" | "userId" | "none",
	presets: { string }?,
	durations: { number }?,
	freeText: boolean?,
	run: (staff: Player, targetUserId: number?, args: ActionArgs) -> (boolean, string?),
}

export type Cell = string | number | boolean
export type Row = { [string]: Cell }

-- (design §11) a row action may offer choices: `presets` (strings keys, e.g. resolutions) and
-- `notes` (preset note keys). The panel sends the picked ones; run gets args.preset / args.note.
-- Admin checks only isStaff + can(permission) before run (the module API run calls counts).
export type RowAction = {
	id: string,
	permission: string,
	labelKey: string,
	presets: { string }?,
	notes: { string }?,
	run: (staff: Player, rowId: string, args: ActionArgs) -> (boolean, string?),
}

-- A panel tab (registerTab). `fetch` returns one page of rows; rowActions act on a row's id.
export type TabDef = {
	id: string,
	permission: string,
	labelKey: string,
	fetch: (staff: Player, page: number) -> { rows: { Row }, columns: { string } },
	rowActions: { RowAction }?,
}

-- What Admin hands the registered audit sink for its own built-in actions (teleport, spectate,
-- announce, shutdown, grant). Moderation's sink turns it into an AuditEntry.
export type AuditRecord = {
	action: string,
	by: number, -- the staff member's UserId (0 = server/console)
	byKind: "staff" | "server" | "console" | "system",
	target: number?,
	reasonKey: string?,
	note: string?,
	seconds: number?,
	status: "ok" | "pending" | "failed" | "refused",
	amount: number?, -- the grant action: the amount and the currency given
	currency: string?,
}

-- One configured role (config.Admin.roles[name]).
export type RoleDef = {
	rank: number,
	permissions: { string },
	maxBanSeconds: number?,
	maxMuteSeconds: number?,
	label: string?,
}

-- The replicated extra.staff value (staff only).
export type StaffState = {
	role: string,
	permissions: { string },
	actions: {
		{
			id: string,
			labelKey: string,
			target: string,
			presets: { string }?,
			durations: { number }?,
			freeText: boolean?,
			permission: string,
		}
	},
	tabs: { { id: string, labelKey: string, permission: string } },
}

-- The server API (StudWork.use(Admin) / ctx.deps[Admin]).
export type API = {
	can: (player: Player, permission: string) -> boolean,
	-- (Addendum G) optional `action`: the action being taken (default = permission); only "ban" and
	-- "ban.permanent" actions count toward limits.bansPerHour (unban, server ban, history don't)
	allow: (staff: Player, permission: string, action: string?) -> (boolean, string?),
	roleOf: (player: Player) -> string?,
	isStaff: (player: Player) -> boolean,
	permissions: (player: Player) -> { string },
	rankOf: (player: Player) -> number,
	-- (design §12) the role's caps; {} for non-staff (owner/admin: none)
	limitsOf: (staff: Player) -> { maxBanSeconds: number?, maxMuteSeconds: number? },
	rankOfUserId: (userId: number) -> (boolean, number),
	-- (added by the integration builder, design §12) true in Studio when the user's role comes only
	-- from studioRole (no ServerConfig.Admin.users entry): Admin and Moderation skip the rank rule
	-- for such a target (self-actions are still refused). Never yields.
	studioRoleOnly: (userId: number) -> boolean,
	-- (Addendum G H1) the rank when it is KNOWN without spending a group lookup, nil = unknown
	-- (a lookup in flight, failed or over budget). A Player: their resolved role (0 = resolved, not
	-- staff). A user id: that player in this server, else the users map, Studio, or group rules from
	-- fresh cache only. Never yields. Moderation and Reports fail closed on nil.
	rankOfChecked: (playerOrUserId: Player | number) -> number?,
	onlineStaff: () -> { Player },
	signals: { StaffJoined: any },
}

-- Extensions (ctx.depsExt[Admin]; call in init).
export type Extensions = {
	registerPermission: (name: string, opts: { roles: { string }? }?) -> (),
	registerAction: (def: ActionDef) -> (),
	registerTab: (def: TabDef) -> (),
	registerDataView: (id: string, fn: (target: Player) -> { [string]: Cell }) -> (),
	onStaffMove: (fn: (staff: Player, target: Player, kind: "to" | "bring") -> ()) -> (),
	registerAuditSink: (fn: (entry: AuditRecord) -> ()) -> (),
	-- (added by the Admin builder) the "public" text filter Admin runs free panel text through
	-- (announcements, an action's `freeText`). With TextFilter enabled Admin filters with it
	-- (Addendum F); a registered filter overrides that. Neither: free text is refused ("no_filter").
	-- fn returns (true, the broadcast string) or (false, reason).
	registerTextFilter: (fn: (author: Player, text: string) -> (boolean, string?)) -> (),
}

-- The client API (StudWork.use(Admin) on the client).
export type ClientAPI = {
	isStaff: () -> boolean,
	permissions: () -> { string },
	role: () -> string?,
	panel: () -> (),
	actions: { run: (...any) -> (), fetch: (...any) -> (), panelOpen: () -> () },
}

local WEEK = 7 * 86400

local function roleKey(role: string): string
	return "Admin.role." .. role
end

return StudWork.defineModule({
	name = "Admin",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Staff roles, permissions and the staff panel (moderation kit)",
	optional = { Economy, TextFilter },
	config = {
		schema = {
			flag = "string?",
			roles = "{[string]: table}",
			studioRole = "string",
			groupCacheSeconds = "number(0..)",
			groupLookupsPerMinute = "integer(1..)",
			groupRetrySeconds = "number(1..)",
			refusedAuditSeconds = "number(0..)",
			limits = { actionsPerMinute = "integer(1..)", bansPerHour = "integer(1..)" },
			panel = { playerListMax = "integer(1..200)" },
			grant = { max = "integer(1..)", currencies = "{string}" },
			announce = { presetKeys = "{string}", freeText = "boolean", maxLength = "integer(1..200)" },
			shutdown = { presetKeys = "{string}" },
		},
		defaults = {
			roles = {
				owner = { rank = 400, permissions = { "*" }, label = roleKey("owner") },
				admin = {
					rank = 300,
					permissions = {
						"ban",
						"ban.permanent",
						"kick",
						"mute",
						"warn",
						"reports.read",
						"reports.resolve",
						"reports.reporters",
						"audit.read",
						"teleport",
						"spectate",
						"data.read",
						"announce",
					},
					label = roleKey("admin"),
				},
				moderator = {
					rank = 200,
					permissions = {
						"ban",
						"kick",
						"mute",
						"warn",
						"reports.read",
						"reports.resolve",
						"audit.read",
						"teleport",
						"spectate",
					},
					maxBanSeconds = WEEK,
					maxMuteSeconds = 86400,
					label = roleKey("moderator"),
				},
				helper = {
					rank = 100,
					permissions = { "kick", "mute", "warn", "reports.read" },
					maxMuteSeconds = 3600,
					label = roleKey("helper"),
				},
			},
			studioRole = "owner",
			groupCacheSeconds = 600,
			groupLookupsPerMinute = 60,
			groupRetrySeconds = 60,
			-- a refused staff request is audited at most once per (staff, action) per this many seconds
			-- (Addendum E; Moderation's audit.refusedEverySeconds for its own refusals)
			refusedAuditSeconds = 3600,
			limits = { actionsPerMinute = 30, bansPerHour = 20 },
			panel = { playerListMax = 50 },
			grant = { max = 10000, currencies = {} }, -- currencies {} = Economy's primary currency only
			announce = {
				presetKeys = { "Admin.announce.restart", "Admin.announce.event", "Admin.announce.rules" },
				freeText = true,
				maxLength = 200,
			},
			shutdown = { presetKeys = { "Admin.shutdown.update", "Admin.shutdown.generic" } },
		},
	},
	-- English defaults; one Admin.role.<role> per configured role (English = the role id) unless
	-- listed here
	strings = function(config: any): { [string]: string }
		local out: { [string]: string } = {
			["Admin.title"] = "Staff panel",
			["Admin.open"] = "Staff",
			["Admin.close"] = "Close",
			["Admin.role.owner"] = "Owner",
			["Admin.role.admin"] = "Admin",
			["Admin.role.moderator"] = "Moderator",
			["Admin.role.helper"] = "Helper",
			["Admin.tab.players"] = "Players",
			["Admin.tab.reports"] = "Reports",
			["Admin.tab.audit"] = "Audit",
			["Admin.tab.announce"] = "Announce",
			["Admin.tab.data"] = "Data",
			["Admin.action.teleportTo"] = "Go to",
			["Admin.action.bring"] = "Bring",
			["Admin.action.spectate"] = "Spectate",
			["Admin.action.stopSpectate"] = "Stop spectating",
			["Admin.action.announce"] = "Announce",
			["Admin.action.shutdown"] = "Shut down server",
			["Admin.action.grant"] = "Grant currency",
			["Admin.action.dataView"] = "View data",
			["Admin.announce.restart"] = "This server will restart soon.",
			["Admin.announce.event"] = "An event is starting!",
			["Admin.announce.rules"] = "Please follow the game rules.",
			["Admin.announce.title"] = "Announcement",
			["Admin.shutdown.update"] = "This server is shutting down for an update. Please rejoin.",
			["Admin.shutdown.generic"] = "This server is shutting down. Please rejoin.",
			["Admin.panel.target"] = "Player",
			["Admin.panel.userId"] = "User ID",
			["Admin.panel.reason"] = "Reason",
			["Admin.panel.duration"] = "Duration",
			["Admin.panel.text"] = "Message",
			["Admin.panel.amount"] = "Amount",
			["Admin.panel.currency"] = "Currency",
			["Admin.panel.confirm"] = "Confirm",
			["Admin.panel.confirmAgain"] = "Tap again to confirm",
			["Admin.panel.pickAction"] = "Pick an action",
			["Admin.panel.pickPlayer"] = "Pick a player first",
			["Admin.panel.pickReason"] = "Pick a reason",
			["Admin.panel.pickDuration"] = "Pick a duration",
			["Admin.panel.pickAmount"] = "Type an amount",
			["Admin.panel.pickNote"] = "Pick a note",
			["Admin.panel.note"] = "Note",
			["Admin.value.yes"] = "Yes",
			["Admin.value.no"] = "No",
			["Admin.panel.cancel"] = "Cancel",
			["Admin.panel.previous"] = "Previous",
			["Admin.panel.next"] = "Next",
			["Admin.panel.empty"] = "Nothing here",
			["Admin.panel.loading"] = "Loading...",
			["Admin.panel.page"] = "Page {page}",
			["Admin.duration.minutes"] = "{n} min",
			["Admin.duration.hours"] = "{n} h",
			["Admin.duration.days"] = "{n} d",
			["Admin.duration.permanent"] = "Permanent",
			["Admin.column.player"] = "Player",
			["Admin.column.userId"] = "User ID",
			["Admin.column.role"] = "Role",
			["Admin.column.value"] = "Value",
			["Admin.data.firstJoin"] = "First join",
			["Admin.data.lastSeen"] = "Last seen",
			["Admin.data.sessions"] = "Sessions",
			["Admin.data.balance"] = "Balance",
			["Admin.result.ok"] = "Done",
			["Admin.result.done"] = "Done",
			["Admin.result.sent"] = "Sent to the player's server",
			["Admin.result.pending"] = "Queued: it finishes when Roblox is reachable",
			["Admin.result.banned"] = "Banned",
			["Admin.result.unbanned"] = "Unbanned",
			["Admin.result.no_permission"] = "You don't have permission for that",
			["Admin.result.rate_limited"] = "Too many staff actions. Wait a moment.",
			["Admin.result.outranked"] = "You can't act on that player",
			["Admin.result.invalid"] = "That request isn't valid",
			["Admin.result.disabled"] = "That feature is switched off",
			["Admin.result.failed"] = "That didn't work. Try again.",
			["Admin.result.not_found"] = "That player isn't in this server",
			["Admin.result.unknown_rank"] = "Couldn't check that player's role. Try again.",
			["Admin.result.too_long_for_role"] = "That's longer than your role allows",
			["Admin.result.unavailable"] = "Not available here",
			["Admin.result.no_filter"] = "Typed text needs the text filter; pick a preset",
			["Admin.result.claimed"] = "Someone else already claimed that",
		}
		local roles = if type(config) == "table" then config.roles else nil
		if type(roles) == "table" then
			for role in roles do
				if type(role) == "string" and string.match(role, "^[%w_]+$") ~= nil and #role <= 32 then
					local key = roleKey(role)
					if out[key] == nil then
						out[key] = role
					end
				end
			end
		end
		return out
	end,
	client = "Admin",
})
