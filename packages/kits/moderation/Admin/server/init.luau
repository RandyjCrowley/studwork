--!strict
--[[
	Admin: the server part (docs/framework/kits/moderation.md "Admin", design §3, §8-§10).

	  api: can, allow, roleOf, isStaff, permissions, rankOf, rankOfUserId, rankOfChecked,
	       studioRoleOnly, limitsOf, onlineStaff,
	       signals StaffJoined(player, role)
	  extensions (call in init): registerPermission, registerAction, registerTab, registerDataView,
	       onStaffMove, registerAuditSink, registerTextFilter
	  actions (net.blink): run(actionId, targetUserId?, preset?, duration?, text?), fetch(tabId, page),
	       panelOpen(0). Every request checks staff FIRST: a non-staff request is dropped with no
	       reply (identical to an unknown action), counted only in a server log line.
	  server -> client: Rows(tabId, page, json), RunResult(ok, key), Spectate(userId?) to that staff
	       player; Announce(payload) to everyone in this server.

	Roles: ServerConfig.Admin.users first; otherwise every group rule through
	GroupService:GetRolesInGroupAsync (cached per user and group for groupCacheSeconds, at most
	groupLookupsPerMinute lookups per server), the highest-rank matching role wins. A failed or
	over-budget lookup = not staff (or the cached role) and a re-check after groupRetrySeconds.
	Studio: a player without a `users` entry has config.studioRole.

	Wire conventions (the net.blink shape is frozen):
	  * a row action is Run("<tabId>/<rowActionId>", nil, rowId) where rowId is the `id` of a row
	    the server sent that staff member for that tab (any other id is refused);
	  * an action with an amount (the built-in grant) carries it in `duration` (1..grant.max);
	  * Announce's payload is "k|<strings key>" (a preset) or "t|<filtered text>".

	Panel delivery: Server.placePanel(gui) clones ./Panel into a ScreenGui (ResetOnSpawn = false)
	in that staff player's PlayerGui only; Server.removePanel(instance) destroys it (flag off, role
	lost). Both are seams a spec may replace (the spec's fake PlayerGui records what it got).

	The module is a factory (`new`): one part per runtime, `part.net` swappable in specs.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Check = require(script.Check)
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))
local TextFilter =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TextFilter"):WaitForChild("module"))

local Server = {}

Server.Check = Check

-- the ScreenGui a staff player's panel arrives in (PlayerGui.<PANEL_NAME>.Panel is the module)
Server.PANEL_NAME = "StudWorkAdminPanel"
Server.ANNOUNCE_KEY = "k|"
Server.ANNOUNCE_TEXT = "t|"

local MINUTE = 60
local HOUR = 3600
local ROWS_JSON_MAX = 30000 -- net.blink Rows: string(0..30000)
local ROWS_MAX = 100
local CELL_MAX = 200
local COLUMNS_MAX = 12
local KEY_MAX = 64 -- net.blink Key
local TEXT_MAX = 200 -- net.blink Run text
local ANNOUNCE_MAX = 400 -- net.blink Announce
local MOVE_OFFSET = 4 -- studs in front of the player moved to (not a balance number)
local DISPLAY_ORDER = 20

-- tab ids the panel owns (registerTab can't take them)
Server.RESERVED_TABS = table.freeze({ "players", "announce", "data" })

-- Live: the Panel ModuleScript (this server part's child) cloned into a ScreenGui in `gui`.
-- Under Lune there is no Instance to clone: nothing is placed (a spec replaces this seam).
function Server.placePanel(gui: any): any
	local source = script:FindFirstChild("Panel")
	if typeof(source) ~= "Instance" then
		return nil
	end
	local holder = Instance.new("ScreenGui")
	holder.Name = Server.PANEL_NAME
	holder.ResetOnSpawn = false
	holder.DisplayOrder = DISPLAY_ORDER
	holder.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	holder.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	local copy = (source :: any):Clone()
	copy.Name = "Panel"
	copy.Parent = holder
	holder.Parent = gui
	return holder
end

function Server.removePanel(existing: any)
	existing:Destroy()
end

local function isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function isUserId(v: any): boolean
	-- Studio test players have negative ids; 0 is nobody
	return isFiniteNumber(v) and v % 1 == 0 and v ~= 0 and math.abs(v) < 2 ^ 53
end

-- drop entries older than `since` from a sorted list of timestamps
local function prune(list: { number }, since: number)
	local n = 0
	for _, t in list do
		if t > since then
			break
		end
		n += 1
	end
	for _ = 1, n do
		table.remove(list, 1)
	end
end

-- UTF-8 safe cut to at most `max` bytes
local function cut(s: string, max: number): string
	if #s <= max then
		return s
	end
	local out = string.sub(s, 1, max)
	while #out > 0 and utf8.len(out) == nil do
		out = string.sub(out, 1, #out - 1)
	end
	return out
end

-- the RunResult key: a bare reason maps to Admin.result.<reason>, a dotted strings key passes
function Server.resultKey(ok: boolean, reason: any): string
	if type(reason) == "string" then
		if string.match(reason, "^[%w_]+$") ~= nil and #reason <= KEY_MAX - #"Admin.result." then
			return "Admin.result." .. reason
		end
		if string.match(reason, "^[%w_]+%.[%w_.]+$") ~= nil and #reason <= KEY_MAX then
			return reason
		end
	end
	return if ok then "Admin.result.ok" else "Admin.result.failed"
end

-- one cell of a panel row: number, boolean or a short string (anything else dropped)
local function cell(v: any): any
	if type(v) == "boolean" then
		return v
	elseif isFiniteNumber(v) then
		return v
	elseif type(v) == "string" then
		return cut(v, CELL_MAX)
	end
	return nil
end

function Server.new(): any
	local ctx: any = nil
	local part: any = {}
	local created: { [string]: any } = {}
	local started = false

	-- registered by other modules
	local permissions: { [string]: { roles: { string } } } = {}
	local actionDefs: { [string]: any } = {}
	local actionOrder: { string } = {}
	local tabDefs: { [string]: any } = {}
	local tabOrder: { string } = {}
	local dataViews: { [string]: (any) -> any } = {}
	local dataViewOrder: { string } = {}
	local moveHooks: { (any, any, string) -> () } = {}
	local auditSink: ((any) -> ())? = nil
	local textFilter: ((any, string) -> (boolean, string?))? = nil

	-- the built-in actions (built in start: they read config and Economy)
	local builtins: { [string]: any } = {}
	local builtinOrder: { string } = {}

	-- players and roles
	local online: { [any]: boolean } = {}
	local byUserId: { [number]: any } = {}
	local info: { [any]: any } = {} -- player -> { role, rank, perms, all }
	local resolved: { [any]: boolean } = {} -- the last resolution had no failed/skipped lookup
	local resolving: { [any]: boolean } = {}
	local retryAt: { [any]: number } = {}
	local stateSet: { [any]: boolean } = {} -- extra.staff was set for this player
	local delivered: { [any]: any } = {}
	local shownRows: { [any]: { [string]: { [string]: boolean } } } = {}
	local spectating: { [any]: number } = {} -- staff player -> the user id they spectate

	-- group lookups
	local groupCache: { [string]: { at: number, roles: { any } } } = {}
	local lookupTimes: { number } = {}

	-- per-staff limits (by user id, so a rejoin doesn't reset them)
	local actionTimes: { [number]: { number } } = {}
	local banTimes: { [number]: { number } } = {}

	local dropped = 0
	local flagOn = true
	local shutdownKey: string? = nil

	-- api.signals is copied by the framework before init: a proxy (kept by identity) that serves
	-- the signals init creates with ctx.signals.new.
	local signals = setmetatable({}, {
		__index = function(_, key: any): any
			return created[key]
		end,
	})

	local function isOn(): boolean
		local flag = ctx.config.flag
		if flag == nil then
			return true
		end
		local ok, on = pcall(ctx.flags.isOn, flag)
		return ok and on == true
	end

	local function beforeStart(what: string)
		if started then
			error(`Admin.{what}: call it in your module's init (Admin has started)`, 3)
		end
	end

	local function roleDef(name: any): any
		return if type(name) == "string" then ctx.config.roles[name] else nil
	end

	local function isPlayer(p: any): boolean
		return (typeof(p) == "Instance" or type(p) == "table") and type(p.UserId) == "number"
	end

	------------------------------------------------------------------------------------------
	-- Role resolution
	------------------------------------------------------------------------------------------

	local function takeLookup(): boolean
		local now = ctx.now()
		prune(lookupTimes, now - MINUTE)
		if #lookupTimes >= ctx.config.groupLookupsPerMinute then
			return false
		end
		table.insert(lookupTimes, now)
		return true
	end

	-- a user's roles in one group -> (roles?, fresh). roles nil = unknown; fresh = false when the
	-- answer came from a stale cache entry or nothing (failed or over budget: re-check later)
	local function groupRoles(userId: number, groupId: number, cachedOnly: boolean?): ({ any }?, boolean)
		local key = `{userId}:{groupId}`
		local cached = groupCache[key]
		if cached ~= nil and ctx.now() - cached.at < ctx.config.groupCacheSeconds then
			return cached.roles, true
		end
		local stale = if cached ~= nil then cached.roles else nil
		if cachedOnly or not takeLookup() then
			return stale, false
		end
		local ok, result = pcall(function(): any
			local groups = ctx.services.get("GroupService")
			return groups:GetRolesInGroupAsync(userId, groupId)
		end)
		if not ok or type(result) ~= "table" then
			ctx.log.warn(`group lookup failed (user {userId}, group {groupId}); checked again later`)
			return stale, false
		end
		local roles = {}
		if result.IsMember ~= false and type(result.Roles) == "table" then
			for _, r in result.Roles do
				if type(r) == "table" then
					table.insert(roles, { id = r.Id, rank = r.Rank })
				end
			end
		end
		groupCache[key] = { at = ctx.now(), roles = roles }
		return roles, true
	end

	local function ruleMatches(rule: any, roles: { any }): boolean
		for _, r in roles do
			if rule.roleId ~= nil and r.id == rule.roleId then
				return true
			end
			if rule.minRank ~= nil and type(r.rank) == "number" and r.rank >= rule.minRank then
				return true
			end
		end
		return false
	end

	local function higher(current: string?, candidate: string?): string?
		local c = roleDef(candidate)
		if c == nil then
			return current
		end
		local cur = roleDef(current)
		if cur == nil or c.rank > cur.rank then
			return candidate
		end
		return current
	end

	-- (complete, role?) for any user id; yields on group lookups (never with cachedOnly: fresh cache
	-- entries only, anything else makes the answer incomplete)
	local function resolveUserId(userId: number, cachedOnly: boolean?): (boolean, string?)
		local sc = if type(ctx.serverConfig) == "table" then ctx.serverConfig else {}
		local users = if type(sc.users) == "table" then sc.users else {}
		local mapped = users[userId]
		if roleDef(mapped) ~= nil then
			return true, mapped
		end
		if ctx.isStudio then
			return true, ctx.config.studioRole
		end
		local best: string? = nil
		local complete = true
		if type(sc.groups) == "table" then
			for _, rule in sc.groups do
				local roles, fresh = groupRoles(userId, rule.groupId, cachedOnly)
				if not fresh then
					complete = false
				end
				if roles ~= nil then
					for _, r in rule.roles do
						if ruleMatches(r, roles) then
							best = higher(best, r.role)
						end
					end
				end
			end
		end
		return complete, best
	end

	local function allPermissions(): { string }
		local out = table.clone(Check.BUILT_IN) :: { string }
		for name in permissions do
			table.insert(out, name)
		end
		table.sort(out)
		return out
	end

	local function buildInfo(role: string): any
		local def = roleDef(role)
		local perms: { [string]: boolean } = {}
		local all = false
		for _, p in def.permissions do
			if p == "*" then
				all = true
			else
				perms[p] = true
			end
		end
		for name, reg in permissions do
			if table.find(reg.roles, role) ~= nil then
				perms[name] = true
			end
		end
		local list: { string }
		if all then
			list = allPermissions()
		else
			list = {}
			for p in perms do
				table.insert(list, p)
			end
			table.sort(list)
		end
		return { role = role, rank = def.rank, perms = perms, all = all, list = table.freeze(list) }
	end

	------------------------------------------------------------------------------------------
	-- The API
	------------------------------------------------------------------------------------------

	local EMPTY: { string } = table.freeze({})

	local api: any = {}

	local function staffInfo(player: any): any
		if not isOn() then
			return nil
		end
		return info[player]
	end

	function api.can(player: any, permission: string): boolean
		if type(permission) ~= "string" then
			return false
		end
		local i = staffInfo(player)
		if i == nil then
			return false
		end
		return i.all or i.perms[permission] == true
	end

	-- (Addendum A) the permission check plus Admin.limits; reasons no_permission | rate_limited | disabled
	-- (Addendum G) `action` (default = permission): only a "ban" / "ban.permanent" action counts toward
	-- bansPerHour, so an unban, a server ban or a history read checks `ban` without using a ban
	function api.allow(staff: any, permission: string, action: string?): (boolean, string?)
		if not isOn() then
			return false, "disabled"
		end
		if not api.can(staff, permission) then
			return false, "no_permission"
		end
		local limits = ctx.config.limits
		local now = ctx.now()
		local uid = staff.UserId
		local acts = actionTimes[uid] or {}
		actionTimes[uid] = acts
		prune(acts, now - MINUTE)
		if #acts >= limits.actionsPerMinute then
			return false, "rate_limited"
		end
		local bans: { number }? = nil
		local acting = if type(action) == "string" then action else permission
		local isBan = acting == "ban" or acting == "ban.permanent"
		if isBan and (permission == "ban" or permission == "ban.permanent") then
			local list = banTimes[uid] or {}
			banTimes[uid] = list
			prune(list, now - HOUR)
			if #list >= limits.bansPerHour then
				return false, "rate_limited"
			end
			bans = list
		end
		table.insert(acts, now)
		if bans ~= nil then
			table.insert(bans, now)
		end
		return true, nil
	end

	function api.roleOf(player: any): string?
		local i = staffInfo(player)
		return if i ~= nil then i.role else nil
	end

	function api.isStaff(player: any): boolean
		return staffInfo(player) ~= nil
	end

	function api.permissions(player: any): { string }
		local i = staffInfo(player)
		return if i ~= nil then i.list else EMPTY
	end

	-- (design §12) the role's caps: { maxBanSeconds?, maxMuteSeconds? } (frozen; {} for non-staff)
	local NO_LIMITS = table.freeze({})
	function api.limitsOf(staff: any): any
		local i = staffInfo(staff)
		if i == nil then
			return NO_LIMITS
		end
		local def = roleDef(i.role)
		return table.freeze({ maxBanSeconds = def.maxBanSeconds, maxMuteSeconds = def.maxMuteSeconds })
	end

	-- the role rank of an online player (0 = not staff)
	function api.rankOf(player: any): number
		local i = staffInfo(player)
		return if i ~= nil then i.rank else 0
	end

	-- (B4) yields: users map, then group rules (cache + budget); (false, 0) = unknown (fail closed)
	function api.rankOfUserId(userId: number): (boolean, number)
		if not isUserId(userId) then
			return false, 0
		end
		if not isOn() then
			return true, 0
		end
		local p = byUserId[userId]
		if p ~= nil and resolved[p] then
			return true, api.rankOf(p)
		end
		local complete, role = resolveUserId(userId)
		if not complete then
			return false, 0
		end
		local def = roleDef(role)
		return true, if def ~= nil then def.rank else 0
	end

	-- (Addendum G H1) the rank when known without a group lookup; nil = unknown. Never yields.
	function api.rankOfChecked(who: any): number?
		if not isOn() then
			return 0
		end
		local p: any = nil
		local userId: number? = nil
		if type(who) == "number" then
			if not isUserId(who) then
				return nil
			end
			userId = who
			p = byUserId[who]
		elseif isPlayer(who) then
			p = who
			userId = who.UserId
		else
			return nil
		end
		if p ~= nil and online[p] then
			if not resolved[p] then
				return nil
			end
			local i = info[p]
			return if i ~= nil then i.rank else 0
		end
		local okCall, complete, role = pcall(resolveUserId, userId :: number, true)
		if not okCall or not complete then
			return nil
		end
		local def = roleDef(role)
		return if def ~= nil then def.rank else 0
	end

	-- (design §12) true in Studio when the user's role comes only from config.studioRole (no
	-- ServerConfig.Admin.users entry): the rank rule is skipped for such a target. Never yields.
	function api.studioRoleOnly(userId: number): boolean
		if not ctx.isStudio or not isUserId(userId) then
			return false
		end
		local sc = if type(ctx.serverConfig) == "table" then ctx.serverConfig else {}
		local users = if type(sc.users) == "table" then sc.users else {}
		return roleDef(users[userId]) == nil
	end

	function api.onlineStaff(): { any }
		local out = {}
		if not isOn() then
			return out
		end
		for p in online do
			if info[p] ~= nil then
				table.insert(out, p)
			end
		end
		table.sort(out, function(a, b)
			return a.UserId < b.UserId
		end)
		return out
	end

	api.signals = signals

	------------------------------------------------------------------------------------------
	-- Extensions
	------------------------------------------------------------------------------------------

	local extensions: any = {}

	function extensions.registerPermission(name: string, opts: any?)
		beforeStart("registerPermission")
		if type(name) ~= "string" or string.match(name, "^[%w_.]+$") == nil or #name > 64 then
			error("Admin.registerPermission(name, opts?): name is 1..64 letters, digits, _ or .", 2)
		end
		if permissions[name] ~= nil or table.find(Check.BUILT_IN, name) ~= nil then
			error(`Admin.registerPermission: '{name}' is already a permission`, 2)
		end
		local roles = if type(opts) == "table" and type(opts.roles) == "table" then opts.roles else {}
		for _, role in roles do
			if type(role) ~= "string" then
				error("Admin.registerPermission: opts.roles is a list of role names", 2)
			end
		end
		permissions[name] = { roles = table.clone(roles) }
	end

	local BUILTIN_ACTIONS = table.freeze({
		"teleportTo",
		"bring",
		"spectate",
		"stopSpectate",
		"announce",
		"shutdown",
		"grant",
		"dataView",
	})

	function extensions.registerAction(def: any)
		beforeStart("registerAction")
		local errors = Check.actionDef(def)
		if #errors > 0 then
			error("Admin.registerAction: " .. table.concat(errors, "; "), 2)
		end
		if actionDefs[def.id] ~= nil or table.find(BUILTIN_ACTIONS, def.id) ~= nil then
			error(`Admin.registerAction: action '{def.id}' is already registered`, 2)
		end
		actionDefs[def.id] = def
		table.insert(actionOrder, def.id)
	end

	function extensions.registerTab(def: any)
		beforeStart("registerTab")
		local errors = Check.tabDef(def)
		if #errors > 0 then
			error("Admin.registerTab: " .. table.concat(errors, "; "), 2)
		end
		if tabDefs[def.id] ~= nil or table.find(Server.RESERVED_TABS, def.id) ~= nil then
			error(`Admin.registerTab: tab '{def.id}' is already registered`, 2)
		end
		tabDefs[def.id] = def
		table.insert(tabOrder, def.id)
	end

	function extensions.registerDataView(id: string, fn: (any) -> any)
		beforeStart("registerDataView")
		if not Check.isId(id) or type(fn) ~= "function" then
			error(
				"Admin.registerDataView(id, fn): id is 1..32 letters, digits or _; fn a function(target)",
				2
			)
		end
		if dataViews[id] ~= nil then
			error(`Admin.registerDataView: '{id}' is already registered`, 2)
		end
		dataViews[id] = fn
		table.insert(dataViewOrder, id)
	end

	function extensions.onStaffMove(fn: (any, any, string) -> ())
		if type(fn) ~= "function" then
			error("Admin.onStaffMove(fn): fn must be a function(staff, target, kind)", 2)
		end
		table.insert(moveHooks, fn)
	end

	function extensions.registerAuditSink(fn: (any) -> ())
		beforeStart("registerAuditSink")
		if type(fn) ~= "function" then
			error("Admin.registerAuditSink(fn): fn must be a function(entry)", 2)
		end
		if auditSink ~= nil then
			error("Admin.registerAuditSink: a sink is already registered", 2)
		end
		auditSink = fn
	end

	function extensions.registerTextFilter(fn: (any, string) -> (boolean, string?))
		beforeStart("registerTextFilter")
		if type(fn) ~= "function" then
			error(
				"Admin.registerTextFilter(fn): fn must be a function(author, text) -> (ok, shown | reason)",
				2
			)
		end
		if textFilter ~= nil then
			error("Admin.registerTextFilter: a text filter is already registered", 2)
		end
		textFilter = fn
	end

	part.api = api
	part.extensions = extensions

	------------------------------------------------------------------------------------------
	-- Audit, replies, staff state, panel delivery
	------------------------------------------------------------------------------------------

	local function audit(record: any)
		if auditSink ~= nil then
			local ok, err = pcall(auditSink :: any, table.freeze(record))
			if ok then
				return
			end
			ctx.log.warn(`audit sink failed: {tostring(err)}`)
		end
		ctx.log.info(
			`audit {record.action} by {record.byKind}:{record.by} target {tostring(record.target)} status {record.status}`
		)
	end

	local function fire(player: any, eventName: string, ...: any)
		local net = part.net
		local event = if type(net) == "table" then net[eventName] else nil
		if event == nil then
			return
		end
		local ok, err = pcall(ctx.net.fire, player, event, ...)
		if not ok then
			ctx.log.warn(`{eventName} not sent: {tostring(err)}`)
		end
	end

	local function reply(player: any, ok: boolean, reason: any)
		fire(player, "RunResult", ok == true, Server.resultKey(ok == true, reason))
	end

	-- (design §12) a refused built-in action goes to a registered sink as "refused", at most once
	-- per (staff, action) per hour (no sink: nothing, the reply is enough)
	local AUDIT_ACTION = {
		teleportTo = "teleport",
		bring = "teleport",
		spectate = "spectate",
		stopSpectate = "spectate",
		announce = "announce",
		shutdown = "shutdown",
		grant = "grant",
		dataView = "custom",
	}
	local refusedAt: { [string]: number } = {}
	local function auditRefused(staff: any, actionId: string, targetUserId: any, reason: any)
		if auditSink == nil then
			return
		end
		local key = `{staff.UserId}:{actionId}`
		local now = ctx.now()
		local last = refusedAt[key]
		if last ~= nil and now - last < ctx.config.refusedAuditSeconds then
			return
		end
		refusedAt[key] = now
		audit({
			-- a registered action is audited under its own id (Moderation's "ban", ...)
			action = AUDIT_ACTION[actionId] or (if actionDefs[actionId] ~= nil then actionId else "custom"),
			by = staff.UserId,
			byKind = "staff",
			target = if isUserId(targetUserId) then targetUserId else nil,
			note = Server.resultKey(false, reason),
			status = "refused",
		})
	end

	local function defFor(id: any): any
		if type(id) ~= "string" then
			return nil
		end
		return builtins[id] or actionDefs[id]
	end

	local function staffState(player: any): any
		local i = info[player]
		local actions = {}
		local function offer(def: any)
			if api.can(player, def.permission) then
				table.insert(actions, {
					id = def.id,
					labelKey = def.labelKey,
					target = def.target,
					presets = def.presets,
					durations = def.durations,
					freeText = def.freeText,
					permission = def.permission,
					amount = if def.amount then { min = 1, max = ctx.config.grant.max } else nil,
				})
			end
		end
		for _, id in builtinOrder do
			offer(builtins[id])
		end
		for _, id in actionOrder do
			offer(actionDefs[id])
		end
		local tabs = {}
		for _, id in tabOrder do
			local tab = tabDefs[id]
			if api.can(player, tab.permission) then
				local rowActions = {}
				for _, ra in tab.rowActions or {} do
					if api.can(player, ra.permission) then
						table.insert(rowActions, {
							id = ra.id,
							labelKey = ra.labelKey,
							permission = ra.permission,
							presets = if type(ra.presets) == "table" then ra.presets else nil,
							notes = if type(ra.notes) == "table" then ra.notes else nil,
						})
					end
				end
				table.insert(tabs, {
					id = tab.id,
					labelKey = tab.labelKey,
					permission = tab.permission,
					rowActions = rowActions,
				})
			end
		end
		return {
			role = i.role,
			label = roleDef(i.role).label,
			rank = i.rank,
			permissions = i.list,
			actions = actions,
			tabs = tabs,
			playerListMax = ctx.config.panel.playerListMax,
		}
	end

	local function deliver(player: any): boolean
		local ok, placed = pcall(function(): boolean
			local gui = player:FindFirstChild("PlayerGui")
			if gui == nil then
				return false
			end
			if gui:FindFirstChild(Server.PANEL_NAME) ~= nil then
				return true
			end
			return Server.placePanel(gui) ~= nil
		end)
		local done = ok and placed == true
		delivered[player] = if done then true else nil
		return done
	end

	local function undeliver(player: any)
		if not delivered[player] then
			return
		end
		delivered[player] = nil
		local ok, err = pcall(function()
			local gui = player:FindFirstChild("PlayerGui")
			local existing = if gui ~= nil then gui:FindFirstChild(Server.PANEL_NAME) else nil
			if existing ~= nil then
				Server.removePanel(existing)
			end
		end)
		if not ok then
			ctx.log.warn(`panel not removed for {player.UserId}: {tostring(err)}`)
		end
	end

	-- extra.staff and the panel follow the player's effective staff status (flag + role)
	local function apply(player: any)
		if staffInfo(player) ~= nil then
			ctx.replicate.set(player, "staff", staffState(player))
			stateSet[player] = true
			deliver(player)
		else
			if stateSet[player] then
				stateSet[player] = nil
				ctx.replicate.set(player, "staff", nil)
			end
			undeliver(player)
			shownRows[player] = nil
		end
	end

	local function resolve(player: any)
		if resolving[player] then
			return
		end
		resolving[player] = true
		retryAt[player] = nil
		local ok, complete, role = pcall(resolveUserId, player.UserId)
		resolving[player] = nil
		if not online[player] then
			return
		end
		if not ok then
			ctx.log.warn(`role resolution failed for {player.UserId}: {tostring(complete)}`)
			complete, role = false, nil
		end
		if not complete then
			retryAt[player] = ctx.now() + ctx.config.groupRetrySeconds
		end
		resolved[player] = complete == true
		local before = info[player]
		if role ~= nil then
			if before == nil or before.role ~= role then
				info[player] = buildInfo(role :: string)
			end
		elseif complete then
			info[player] = nil
		end
		apply(player)
		if before == nil and info[player] ~= nil and isOn() then
			created.StaffJoined:Fire(player, info[player].role)
		end
	end

	local function dropRequest(player: any, what: string)
		dropped += 1
		local uid = if isPlayer(player) then player.UserId else "?"
		ctx.log.info(`dropped a {what} request from non-staff user {uid} ({dropped} dropped so far)`)
	end

	------------------------------------------------------------------------------------------
	-- Rows (tabs and the data view)
	------------------------------------------------------------------------------------------

	local function sendRows(player: any, tabId: string, page: number, result: any)
		local columns = {}
		if type(result.columns) == "table" then
			for _, c in result.columns do
				if type(c) == "string" and #c <= KEY_MAX and #columns < COLUMNS_MAX then
					table.insert(columns, c)
				end
			end
		end
		local rows = {}
		local ids: { [string]: boolean } = {}
		if type(result.rows) == "table" then
			for _, r in result.rows do
				if #rows >= ROWS_MAX then
					break
				end
				if type(r) == "table" then
					local row = {}
					for k, v in r do
						if type(k) == "string" and #k <= KEY_MAX then
							row[k] = cell(v)
						end
					end
					if row.id ~= nil then
						row.id = cut(tostring(row.id), KEY_MAX)
						ids[row.id] = true
					end
					table.insert(rows, row)
				end
			end
		end
		local payload: any = { columns = columns, rows = rows, target = result.target }
		local json = HttpService:JSONEncode(payload)
		while #json > ROWS_JSON_MAX and #rows > 0 do
			table.remove(rows)
			json = HttpService:JSONEncode(payload)
		end
		local mine = shownRows[player] or {}
		shownRows[player] = mine
		mine[tabId] = ids
		fire(player, "Rows", tabId, page, json)
	end

	local function playersPage(page: number): any
		local list = {}
		for p in online do
			table.insert(list, p)
		end
		table.sort(list, function(a, b)
			return a.UserId < b.UserId
		end)
		local size = ctx.config.panel.playerListMax
		local rows = {}
		for i = (page - 1) * size + 1, math.min(#list, page * size) do
			local p = list[i]
			table.insert(rows, { id = tostring(p.UserId), userId = p.UserId, name = tostring(p.Name) })
		end
		return { columns = { "name", "userId" }, rows = rows, total = #list }
	end

	local function grantCurrencies(): { string }
		if not ctx.isEnabled(Economy) then
			return {}
		end
		local listed = ctx.config.grant.currencies
		if #listed > 0 then
			return table.clone(listed)
		end
		local primary = ctx.deps[Economy].primaryCurrency()
		-- a paid currency is granted only when the game lists it explicitly
		if ctx.compliance.isPaidCurrency(primary) then
			return {}
		end
		return { primary }
	end

	-- a data-view string must be a declared strings key (B7); numbers and booleans pass
	local function viewValue(v: any): any
		if type(v) == "boolean" or isFiniteNumber(v) then
			return v
		end
		if type(v) == "string" and #v <= KEY_MAX and ctx.text.english(v) ~= v then
			return v
		end
		return nil
	end

	local function dataRows(target: any): any
		local rows = {}
		local function push(section: string, label: string, value: any, kind: string?)
			if value ~= nil then
				table.insert(rows, {
					id = tostring(#rows + 1),
					section = section,
					label = label,
					value = value,
					kind = kind,
				})
			end
		end
		local facts = ctx.framework
		local function fact(name: string): any
			local ok, v = pcall(facts[name], target)
			return if ok and isFiniteNumber(v) then v else nil
		end
		push("Admin.tab.data", "Admin.data.firstJoin", fact("firstJoin"), "time")
		push("Admin.tab.data", "Admin.data.lastSeen", fact("lastSeen"), "time")
		push("Admin.tab.data", "Admin.data.sessions", fact("sessions"), "number")
		for _, id in dataViewOrder do
			local ok, values = pcall(dataViews[id], target)
			if ok and type(values) == "table" then
				local keys = {}
				for k in values do
					if type(k) == "string" and #k <= KEY_MAX then
						table.insert(keys, k)
					end
				end
				table.sort(keys)
				for _, k in keys do
					local v = viewValue(values[k])
					push(id, k, v, if type(v) == "string" then "key" else nil)
				end
			elseif not ok then
				ctx.log.warn(`data view '{id}' failed: {tostring(values)}`)
			end
		end
		if ctx.isEnabled(Economy) then
			local economy = ctx.deps[Economy]
			local currencies = grantCurrencies()
			local primary = economy.primaryCurrency()
			if table.find(currencies, primary) == nil then
				table.insert(currencies, 1, primary)
			end
			for _, currency in currencies do
				local ok, balance = pcall(economy.balance, target, currency)
				if ok and isFiniteNumber(balance) then
					push("Admin.data.balance", currency, balance, "number")
				end
			end
		end
		return { columns = { "section", "label", "value" }, rows = rows, target = target.UserId }
	end

	------------------------------------------------------------------------------------------
	-- The built-in actions
	------------------------------------------------------------------------------------------

	local function staffRecord(staff: any, action: string, extra: any): any
		local record: any = { action = action, by = staff.UserId, byKind = "staff", status = "ok" }
		for k, v in extra or {} do
			record[k] = v
		end
		return record
	end

	-- moves `mover` next to `anchor`; onStaffMove hooks run first
	local function move(staff: any, target: any, kind: string): boolean
		for _, hook in moveHooks do
			local ok, err = pcall(hook :: any, staff, target, kind)
			if not ok then
				ctx.log.warn(`onStaffMove hook failed: {tostring(err)}`)
			end
		end
		local mover = if kind == "to" then staff else target
		local anchor = if kind == "to" then target else staff
		local ok = pcall(function()
			local dest = anchor.Character:GetPivot()
			local placed = dest
			local shifted, value = pcall(function(): any
				return dest * CFrame.new(0, 0, MOVE_OFFSET)
			end)
			if shifted then
				placed = value
			end
			mover.Character:PivotTo(placed)
		end)
		return ok
	end

	local function runMove(kind: string): any
		return function(staff: any, targetUserId: number?, _args: any): (boolean, string?)
			local target = byUserId[targetUserId :: number]
			if target == nil then
				return false, "not_found"
			end
			local ok = move(staff, target, kind)
			audit(staffRecord(staff, "teleport", {
				target = targetUserId,
				note = if kind == "to" then "Admin.action.teleportTo" else "Admin.action.bring",
				status = if ok then "ok" else "failed",
			}))
			return ok, if ok then "done" else "failed"
		end
	end

	local function runSpectate(staff: any, targetUserId: number?, _args: any): (boolean, string?)
		local target = byUserId[targetUserId :: number]
		if target == nil then
			return false, "not_found"
		end
		-- StreamingEnabled: stream the target's area to the staff client
		pcall(function()
			staff.ReplicationFocus = target.Character.PrimaryPart
		end)
		spectating[staff] = target.UserId
		fire(staff, "Spectate", target.UserId)
		audit(staffRecord(staff, "spectate", { target = targetUserId }))
		return true, "done"
	end

	local function runStopSpectate(staff: any, _targetUserId: number?, _args: any): (boolean, string?)
		pcall(function()
			staff.ReplicationFocus = nil
		end)
		spectating[staff] = nil
		fire(staff, "Spectate", nil)
		audit(staffRecord(staff, "spectate", { note = "Admin.action.stopSpectate" }))
		return true, "done"
	end

	local function runAnnounce(staff: any, _targetUserId: number?, args: any): (boolean, string?)
		local payload: string
		if args.preset ~= nil and args.text == nil then
			payload = Server.ANNOUNCE_KEY .. args.preset
		elseif args.text ~= nil and args.preset == nil then
			payload = Server.ANNOUNCE_TEXT .. args.text -- already filtered "public" (onRun)
		else
			return false, "invalid"
		end
		payload = cut(payload, ANNOUNCE_MAX)
		local net = part.net
		if type(net) == "table" and net.Announce ~= nil then
			ctx.net.fireAll(net.Announce, payload)
		end
		audit(staffRecord(staff, "announce", { reasonKey = args.preset }))
		return true, "done"
	end

	local function shutdownServer(key: string, record: any)
		shutdownKey = key
		audit(record)
		local list = {}
		for p in online do
			table.insert(list, p)
		end
		table.sort(list, function(a, b)
			return a.UserId < b.UserId
		end)
		for _, p in list do
			local ok, err = pcall(function()
				p:Kick(ctx.text.format(p, key))
			end)
			if not ok then
				ctx.log.warn(`shutdown: kick failed for {p.UserId}: {tostring(err)}`)
			end
		end
	end

	local function runShutdown(staff: any, _targetUserId: number?, args: any): (boolean, string?)
		if args.preset == nil then
			return false, "invalid"
		end
		shutdownServer(args.preset, staffRecord(staff, "shutdown", { reasonKey = args.preset }))
		return true, "done"
	end

	local function grant(target: any, amount: number, currency: string, byUserIdValue: number): boolean
		local ok, granted = pcall(ctx.deps[Economy].grant, target, amount, `admin:{byUserIdValue}`, currency)
		return ok and granted ~= false
	end

	local function runGrant(staff: any, targetUserId: number?, args: any): (boolean, string?)
		local target = byUserId[targetUserId :: number]
		if target == nil then
			return false, "not_found"
		end
		local currency, amount = args.preset, args.amount
		if currency == nil or amount == nil or table.find(grantCurrencies(), currency) == nil then
			return false, "invalid"
		end
		local ok = grant(target, amount, currency, staff.UserId)
		audit(staffRecord(staff, "grant", {
			target = targetUserId,
			amount = amount,
			currency = currency,
			status = if ok then "ok" else "failed",
		}))
		return ok, if ok then "done" else "failed"
	end

	local function runDataView(staff: any, targetUserId: number?, _args: any): (boolean, string?)
		local target = byUserId[targetUserId :: number]
		if target == nil then
			return false, "not_found"
		end
		sendRows(staff, "data", 1, dataRows(target))
		audit(staffRecord(staff, "custom", { target = targetUserId, note = "Admin.action.dataView" }))
		return true, "done"
	end

	local function buildBuiltins()
		local cfg = ctx.config
		local list: { any } = {
			{
				id = "teleportTo",
				permission = "teleport",
				labelKey = "Admin.action.teleportTo",
				target = "player",
				run = runMove("to"),
			},
			{
				id = "bring",
				permission = "teleport",
				labelKey = "Admin.action.bring",
				target = "player",
				run = runMove("bring"),
			},
			{
				id = "spectate",
				permission = "spectate",
				labelKey = "Admin.action.spectate",
				target = "player",
				run = runSpectate,
			},
			{
				id = "stopSpectate",
				permission = "spectate",
				labelKey = "Admin.action.stopSpectate",
				target = "none",
				run = runStopSpectate,
			},
			{
				id = "announce",
				permission = "announce",
				labelKey = "Admin.action.announce",
				target = "none",
				presets = table.clone(cfg.announce.presetKeys),
				freeText = cfg.announce.freeText,
				textMax = cfg.announce.maxLength,
				run = runAnnounce,
			},
			{
				id = "shutdown",
				permission = "shutdown",
				labelKey = "Admin.action.shutdown",
				target = "none",
				presets = table.clone(cfg.shutdown.presetKeys),
				run = runShutdown,
			},
			{
				id = "dataView",
				permission = "data.read",
				labelKey = "Admin.action.dataView",
				target = "player",
				run = runDataView,
			},
		}
		local currencies = grantCurrencies()
		if #currencies > 0 then
			table.insert(list, {
				id = "grant",
				permission = "data.grant",
				labelKey = "Admin.action.grant",
				target = "player",
				presets = currencies,
				amount = true,
				run = runGrant,
			})
		end
		for _, def in list do
			builtins[def.id] = table.freeze(def)
			table.insert(builtinOrder, def.id)
		end
	end

	------------------------------------------------------------------------------------------
	-- Client requests. Staff is checked first; a non-staff request gets no reply at all.
	------------------------------------------------------------------------------------------

	-- preset / duration / amount / text against the definition (no filtering yet)
	local function checkArgs(def: any, preset: any, duration: any, text: any): (any?, string?)
		local args: any = {}
		if preset ~= nil then
			if
				type(preset) ~= "string"
				or type(def.presets) ~= "table"
				or table.find(def.presets, preset) == nil
			then
				return nil, "invalid"
			end
			args.preset = preset
		end
		if duration ~= nil then
			if not isFiniteNumber(duration) then
				return nil, "invalid"
			end
			if def.amount then
				if duration % 1 ~= 0 or duration < 1 or duration > ctx.config.grant.max then
					return nil, "invalid"
				end
				args.amount = duration
			else
				if type(def.durations) ~= "table" or table.find(def.durations, duration) == nil then
					return nil, "invalid"
				end
				args.duration = duration
			end
		end
		if text ~= nil then
			if type(text) ~= "string" or def.freeText ~= true then
				return nil, "invalid"
			end
			local max = math.min(def.textMax or TEXT_MAX, TEXT_MAX)
			if #text > max or string.match(text, "%S") == nil then
				return nil, "invalid"
			end
		end
		return args, nil
	end

	-- self and equal/higher rank are refused; an unknown rank fails closed
	local function rankAllows(staff: any, targetUserId: number): (boolean, string?)
		if targetUserId == staff.UserId then
			return false, "outranked"
		end
		-- (design §12) Studio: everyone is staff (studioRole), so the rank rule is skipped for a
		-- target whose role comes only from studioRole; a ServerConfig users entry still counts
		if api.studioRoleOnly(targetUserId) then
			return true, nil
		end
		local ok, rank = api.rankOfUserId(targetUserId)
		if not ok then
			return false, "unknown_rank"
		end
		if rank > 0 and rank >= api.rankOf(staff) then
			return false, "outranked"
		end
		return true, nil
	end

	-- TextFilter "public" (Addendum F): (true, broadcast string) or (false, reason)
	local function textFilterPublic(author: any, raw: string): (boolean, string?)
		local ok, r = ctx.deps[TextFilter].filter(author, raw, "public")
		if ok == true and type(r) == "table" and type(r.public) == "string" then
			return true, r.public
		end
		return false, if r == "rate_limited" then "rate_limited" else "failed"
	end

	-- free text through the registered "public" filter (an override), else TextFilter when it is
	-- enabled (Addendum F); only the broadcast string goes on
	local function filtered(staff: any, raw: string): (string?, string?)
		local filter = textFilter
		if filter == nil and ctx.isEnabled(TextFilter) then
			filter = textFilterPublic
		end
		if filter == nil then
			return nil, "no_filter"
		end
		local called, ok, shown = pcall(filter, staff, raw)
		if not called then
			ctx.log.warn(`text filter failed: {tostring(ok)}`)
			return nil, "failed"
		end
		if ok ~= true or type(shown) ~= "string" or string.match(shown, "%S") == nil then
			return nil, if shown == "rate_limited" then "rate_limited" else "failed"
		end
		return shown, nil
	end

	-- a row action's choices ride in `text` as "<preset>" or "<preset>|<note>" (each one of the
	-- row action's own `presets` / `notes` keys: never free text)
	local function rowChoices(ra: any, text: any): (any?, string?)
		local presets = if type(ra.presets) == "table" then ra.presets else {}
		local notes = if type(ra.notes) == "table" then ra.notes else {}
		if text == nil then
			if #presets > 0 then
				return nil, "invalid"
			end
			return {}, nil
		end
		if type(text) ~= "string" then
			return nil, "invalid"
		end
		local choice, note = string.match(text, "^([^|]+)|([^|]+)$")
		if choice == nil then
			choice = text
		end
		if table.find(presets, choice) == nil then
			return nil, "invalid"
		end
		if note ~= nil and table.find(notes, note) == nil then
			return nil, "invalid"
		end
		return { preset = choice, note = note }, nil
	end

	-- (design §11) a registered row action checks isStaff + can only; the module API it calls with
	-- by = staff does the counting (Admin.allow)
	local function runRowAction(
		player: any,
		tabId: string,
		rowActionId: string,
		rowId: any,
		text: any,
		extra: boolean
	)
		local tab = tabDefs[tabId]
		if tab == nil then
			reply(player, false, "invalid")
			return
		end
		if not api.can(player, tab.permission) then
			reply(player, false, "no_permission")
			return
		end
		local ra = nil
		for _, candidate in tab.rowActions or {} do
			if candidate.id == rowActionId then
				ra = candidate
			end
		end
		if ra == nil then
			reply(player, false, "invalid")
			return
		end
		if not api.can(player, ra.permission) then
			reply(player, false, "no_permission")
			return
		end
		local shown = shownRows[player] and shownRows[player][tabId]
		if extra or type(rowId) ~= "string" or shown == nil or shown[rowId] ~= true then
			reply(player, false, "invalid")
			return
		end
		local args, bad = rowChoices(ra, text)
		if args == nil then
			reply(player, false, bad)
			return
		end
		local ok, result, reason = pcall(ra.run, player, rowId, table.freeze(args))
		if not ok then
			ctx.log.warn(`row action {tabId}/{rowActionId} failed: {tostring(result)}`)
			reply(player, false, "failed")
			return
		end
		reply(player, result == true, reason)
	end

	local function onRun(player: any, actionId: any, targetUserId: any, preset: any, duration: any, text: any)
		if staffInfo(player) == nil then
			dropRequest(player, "run")
			return
		end
		if type(actionId) == "string" then
			local tabId, rowActionId = string.match(actionId, "^([%w_]+)/([%w_]+)$")
			if tabId ~= nil and rowActionId ~= nil then
				runRowAction(player, tabId, rowActionId, preset, text, targetUserId ~= nil or duration ~= nil)
				return
			end
		end
		local def = defFor(actionId)
		if def == nil then
			reply(player, false, "invalid")
			return
		end
		-- (Addendum E) a refused staff request is audited (throttled per staff and action); a
		-- registered action refused here never reaches its module, so Admin audits it too
		local function refuse(reason: any)
			reply(player, false, reason)
			auditRefused(player, def.id, targetUserId, reason)
		end
		-- (design §11) a built-in action counts the per-staff limits here (allow, once); a registered
		-- action checks only the permission: its run calls the module API with by = staff, whose
		-- Admin.allow counts it
		local allowed, why
		if builtins[def.id] == def then
			allowed, why = api.allow(player, def.permission)
		elseif api.can(player, def.permission) then
			allowed, why = true, nil
		else
			allowed, why = false, "no_permission"
		end
		if not allowed then
			refuse(why)
			return
		end
		local args, bad = checkArgs(def, preset, duration, text)
		if args == nil then
			refuse(bad)
			return
		end
		if def.target == "none" then
			if targetUserId ~= nil then
				refuse("invalid")
				return
			end
		else
			if not isUserId(targetUserId) then
				refuse("invalid")
				return
			end
			if def.target == "player" and byUserId[targetUserId] == nil then
				refuse("not_found")
				return
			end
			local rankOk, rankWhy = rankAllows(player, targetUserId)
			if not rankOk then
				refuse(rankWhy)
				return
			end
		end
		if text ~= nil then
			local shown, refused = filtered(player, text)
			if shown == nil then
				refuse(refused)
				return
			end
			args.text = shown
		end
		local ok, result, reason = pcall(def.run, player, targetUserId, table.freeze(args))
		if not ok then
			ctx.log.warn(`action {def.id} failed: {tostring(result)}`)
			reply(player, false, "failed")
			return
		end
		reply(player, result == true, reason)
	end

	local function onFetch(player: any, tabId: any, page: any)
		if staffInfo(player) == nil then
			dropRequest(player, "fetch")
			return
		end
		if
			type(tabId) ~= "string"
			or not isFiniteNumber(page)
			or page % 1 ~= 0
			or page < 1
			or page > 65535
		then
			reply(player, false, "invalid")
			return
		end
		if tabId == "players" then
			sendRows(player, "players", page, playersPage(page))
			return
		end
		local tab = tabDefs[tabId]
		if tab == nil then
			reply(player, false, "invalid")
			return
		end
		-- (design §11) a tab fetch counts once toward the per-staff limits
		local allowed, why = api.allow(player, tab.permission)
		if not allowed then
			reply(player, false, why)
			return
		end
		local ok, result = pcall(tab.fetch, player, page)
		if not ok or type(result) ~= "table" then
			ctx.log.warn(`tab {tabId} fetch failed: {tostring(result)}`)
			reply(player, false, "failed")
			return
		end
		sendRows(player, tabId, page, result)
	end

	local function onPanelOpen(player: any, _zero: number?)
		if staffInfo(player) == nil then
			dropRequest(player, "panelOpen")
			return
		end
		apply(player)
	end

	part.actions = {
		run = { limit = { rate = 1, burst = 5 }, handler = onRun },
		fetch = { limit = { rate = 1, burst = 4 }, handler = onFetch },
		panelOpen = { limit = { rate = 0.2, burst = 2 }, handler = onPanelOpen },
	}

	-- read-only views for specs and the builder (what other modules registered)
	part.registered = function(): any
		return {
			permissions = permissions,
			actions = actionOrder,
			tabs = tabOrder,
			dataViews = dataViewOrder,
			moveHooks = #moveHooks,
			auditSink = auditSink ~= nil,
			textFilter = textFilter ~= nil,
			builtins = builtinOrder,
		}
	end

	------------------------------------------------------------------------------------------
	-- Console (server-only: the framework runs every command with player = nil)
	------------------------------------------------------------------------------------------

	local function consoleRecord(action: string, extra: any): any
		local record: any = { action = action, by = 0, byKind = "console", status = "ok" }
		for k, v in extra or {} do
			record[k] = v
		end
		return record
	end

	local function onlineByArg(arg: any): any
		local id = tonumber(arg)
		return if id ~= nil then byUserId[id] else nil
	end

	local function registerConsole()
		local console = ctx.console
		-- a player-run console command (none exists live) needs the same permission
		local function trusted(player: any, permission: string): boolean
			return player == nil or api.can(player, permission)
		end

		console.register("staff", function(player: any): string
			if not trusted(player, "audit.read") then
				return "no_permission"
			end
			local parts = {}
			for _, p in api.onlineStaff() do
				table.insert(parts, `{p.UserId}={api.roleOf(p)}`)
			end
			return if #parts == 0 then "no staff online" else table.concat(parts, " ")
		end, "admin staff  (the staff in this server and their roles)")

		console.register("role", function(player: any, userId: any): string
			if not trusted(player, "audit.read") then
				return "no_permission"
			end
			local id = tonumber(userId)
			if id == nil or not isUserId(id) then
				return "usage: admin role <userId>"
			end
			local p = byUserId[id]
			if p ~= nil and resolved[p] then
				return `{id}: {api.roleOf(p) or "none"} (rank {api.rankOf(p)})`
			end
			local ok, rank = api.rankOfUserId(id)
			return if ok then `{id}: rank {rank}` else `{id}: unknown (lookup failed or over budget)`
		end, "admin role <userId>")

		console.register("announce", function(player: any, key: any): string
			if not trusted(player, "announce") then
				return "no_permission"
			end
			if type(key) ~= "string" or table.find(ctx.config.announce.presetKeys, key) == nil then
				return "usage: admin announce <presetKey> (one of config.Admin.announce.presetKeys)"
			end
			local net = part.net
			if type(net) == "table" and net.Announce ~= nil then
				ctx.net.fireAll(net.Announce, Server.ANNOUNCE_KEY .. key)
			end
			audit(consoleRecord("announce", { reasonKey = key }))
			return "announced"
		end, "admin announce <presetKey>")

		console.register("shutdown", function(player: any, key: any): string
			if not trusted(player, "shutdown") then
				return "no_permission"
			end
			if type(key) ~= "string" or table.find(ctx.config.shutdown.presetKeys, key) == nil then
				return "usage: admin shutdown <presetKey> (one of config.Admin.shutdown.presetKeys)"
			end
			shutdownServer(key, consoleRecord("shutdown", { reasonKey = key }))
			return "shutting down"
		end, "admin shutdown <presetKey>")

		console.register("grant", function(player: any, amountArg: any, currency: any, userId: any): string
			if not trusted(player, "data.grant") then
				return "no_permission"
			end
			local amount = tonumber(amountArg)
			local target = onlineByArg(userId)
			if amount == nil or amount % 1 ~= 0 or amount < 1 or amount > ctx.config.grant.max then
				return `usage: admin grant <amount 1..{ctx.config.grant.max}> <currency> <userId>`
			end
			if target == nil then
				return "not_found (the player must be in this server)"
			end
			if type(currency) ~= "string" or table.find(grantCurrencies(), currency) == nil then
				return `invalid currency (one of: {table.concat(grantCurrencies(), ", ")})`
			end
			local ok = grant(target, amount, currency, 0)
			audit(consoleRecord("grant", {
				target = target.UserId,
				amount = amount,
				currency = currency,
				status = if ok then "ok" else "failed",
			}))
			return if ok then "granted" else "failed"
		end, "admin grant <amount> <currency> <userId>")

		console.register("tp", function(player: any, fromId: any, toId: any): string
			if not trusted(player, "teleport") then
				return "no_permission"
			end
			local from, to = onlineByArg(fromId), onlineByArg(toId)
			if from == nil or to == nil or from == to then
				return "usage: admin tp <userId to move> <userId to move to> (both in this server)"
			end
			local ok = move(from, to, "to")
			audit(consoleRecord("teleport", {
				target = from.UserId,
				note = "Admin.action.teleportTo",
				status = if ok then "ok" else "failed",
			}))
			return if ok then "moved" else "failed (no character)"
		end, "admin tp <userId to move> <userId to move to>")

		console.register("data", function(player: any, userId: any): string
			if not trusted(player, "data.read") then
				return "no_permission"
			end
			local target = onlineByArg(userId)
			if target == nil then
				return "usage: admin data <userId> (the player must be in this server)"
			end
			local parts = {}
			for _, row in dataRows(target).rows do
				table.insert(parts, `{row.section}/{row.label}={tostring(row.value)}`)
			end
			return table.concat(parts, " ")
		end, "admin data <userId>")
	end

	------------------------------------------------------------------------------------------
	-- Lifecycle
	------------------------------------------------------------------------------------------

	function part.init(context: any)
		ctx = context
		local cfg = ctx.config
		if cfg.flag ~= nil then
			local ok, err = pcall(ctx.flags.isOn, cfg.flag)
			if not ok then
				error(`[Admin] config.flag: {tostring(err)}`, 0)
			end
		end
		local errors = Check.config(cfg, ctx.serverConfig)
		if #errors > 0 then
			error("[Admin] " .. table.concat(errors, "; "), 0)
		end
		created.StaffJoined = ctx.signals.new("StaffJoined")
		registerConsole()

		ctx.lifecycle.onPlayerLoaded(function(player: any)
			online[player] = true
			byUserId[player.UserId] = player
			if shutdownKey ~= nil then
				local key = shutdownKey :: string
				pcall(function()
					player:Kick(ctx.text.format(player, key))
				end)
				return
			end
			task.spawn(resolve, player)
		end)

		ctx.lifecycle.onPlayerRemoving(function(player: any)
			online[player] = nil
			if byUserId[player.UserId] == player then
				byUserId[player.UserId] = nil
			end
			info[player] = nil
			resolved[player] = nil
			resolving[player] = nil
			retryAt[player] = nil
			stateSet[player] = nil
			delivered[player] = nil
			shownRows[player] = nil
			spectating[player] = nil
			-- (Addendum G) staff spectating the player who left: focus cleared, the client told
			for staff, uid in spectating do
				if uid == player.UserId then
					spectating[staff] = nil
					pcall(function()
						staff.ReplicationFocus = nil
					end)
					fire(staff, "Spectate", nil)
				end
			end
		end)

		-- the flag kill switch and the re-check of failed / over-budget group lookups
		ctx.lifecycle.onTick(1, function()
			local on = isOn()
			if on ~= flagOn then
				flagOn = on
				for p in online do
					apply(p)
					if on and info[p] ~= nil then
						created.StaffJoined:Fire(p, info[p].role)
					end
				end
			end
			local now = ctx.now()
			for p, at in retryAt do
				if at <= now and online[p] then
					task.spawn(resolve, p)
				end
			end
		end)
	end

	function part.start(_context: any)
		started = true
		flagOn = isOn()
		buildBuiltins()
	end

	return part
end

return Server
