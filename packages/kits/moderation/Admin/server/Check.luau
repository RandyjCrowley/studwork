--!strict
--[[
	Admin config checks the schema language can't express (roles, studioRole, ServerConfig.Admin)
	and the extension definition checks (ActionDef, TabDef). Pure; every check returns the list of
	problems (never fail-fast) or raises with all of them.

	  Check.BUILT_IN                         the built-in permissions (games add with registerPermission)
	  Check.config(cfg, serverConfig?) -> { string }
	  Check.actionDef(def) -> { string }     ActionDef (id [%w_]{1,32}, permission, labelKey, target, ...)
	  Check.tabDef(def) -> { string }        TabDef (id, permission, labelKey, fetch, rowActions?)
	  Check.isId(v) -> boolean
]]

local Check = {}

Check.BUILT_IN = table.freeze({
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
	"data.grant",
	"announce",
	"shutdown",
})

Check.TARGETS = table.freeze({ "player", "userId", "none" })

local MAX_RANK = 1000

function Check.isId(v: any): boolean
	return type(v) == "string" and #v >= 1 and #v <= 32 and string.match(v, "^[%w_]+$") ~= nil
end

local function isPermission(v: any): boolean
	return type(v) == "string" and #v >= 1 and #v <= 64 and string.match(v, "^[%w_.%*]+$") ~= nil
end

local function isPositive(v: any): boolean
	return type(v) == "number" and v == v and v > 0 and v < math.huge
end

function Check.config(cfg: any, serverConfig: any?): { string }
	local errors: { string } = {}
	for name, role in cfg.roles do
		local p = `config.Admin.roles.{tostring(name)}`
		if not Check.isId(name) then
			table.insert(errors, `{p}: a role name is 1..32 letters, digits or _`)
		end
		if type(role) ~= "table" then
			table.insert(
				errors,
				p .. ": must be { rank, permissions, maxBanSeconds?, maxMuteSeconds?, label? }"
			)
			continue
		end
		local rank = role.rank
		if type(rank) ~= "number" or rank % 1 ~= 0 or rank < 1 or rank > MAX_RANK then
			table.insert(errors, `{p}.rank: an integer 1..{MAX_RANK}`)
		end
		if type(role.permissions) ~= "table" then
			table.insert(errors, `{p}.permissions: a list of permission names or "*"`)
		else
			for _, perm in role.permissions do
				if not isPermission(perm) then
					table.insert(errors, `{p}.permissions: '{tostring(perm)}' is not a permission name`)
				end
			end
		end
		if role.maxBanSeconds ~= nil and not isPositive(role.maxBanSeconds) then
			table.insert(errors, `{p}.maxBanSeconds: a number > 0`)
		end
		if role.maxMuteSeconds ~= nil and not isPositive(role.maxMuteSeconds) then
			table.insert(errors, `{p}.maxMuteSeconds: a number > 0`)
		end
		if role.label ~= nil and type(role.label) ~= "string" then
			table.insert(errors, `{p}.label: a strings key`)
		end
	end
	if cfg.roles[cfg.studioRole] == nil then
		table.insert(
			errors,
			`config.Admin.studioRole: '{tostring(cfg.studioRole)}' is not in config.Admin.roles`
		)
	end
	local sc = if type(serverConfig) == "table" then serverConfig else {}
	if sc.users ~= nil then
		if type(sc.users) ~= "table" then
			table.insert(errors, "ServerConfig.Admin.users: { [userId] = role }")
		else
			for userId, role in sc.users do
				if type(userId) ~= "number" or cfg.roles[role] == nil then
					table.insert(
						errors,
						`ServerConfig.Admin.users[{tostring(userId)}]: a user id mapped to a role in config.Admin.roles`
					)
				end
			end
		end
	end
	if sc.groups ~= nil then
		if type(sc.groups) ~= "table" then
			table.insert(
				errors,
				"ServerConfig.Admin.groups: { { groupId, roles = { { roleId?, minRank?, role } } } }"
			)
		else
			for i, rule in sc.groups do
				local p = `ServerConfig.Admin.groups[{i}]`
				if type(rule) ~= "table" or type(rule.groupId) ~= "number" or type(rule.roles) ~= "table" then
					table.insert(errors, p .. ": { groupId, roles = { { roleId?, minRank?, role } } }")
					continue
				end
				for j, r in rule.roles do
					if type(r) ~= "table" or cfg.roles[r.role] == nil then
						table.insert(errors, `{p}.roles[{j}].role: a role in config.Admin.roles`)
					elseif r.roleId == nil and r.minRank == nil then
						table.insert(errors, `{p}.roles[{j}]: needs roleId or minRank`)
					end
				end
			end
		end
	end
	return errors
end

local function checkCommon(def: any, what: string, errors: { string })
	if not Check.isId(def.id) then
		table.insert(errors, `{what}.id: 1..32 letters, digits or _`)
	end
	if not isPermission(def.permission) or def.permission == "*" then
		table.insert(errors, `{what}.permission: a permission name`)
	end
	if type(def.labelKey) ~= "string" then
		table.insert(errors, `{what}.labelKey: a strings key`)
	end
end

function Check.actionDef(def: any): { string }
	local errors: { string } = {}
	if type(def) ~= "table" then
		return { "ActionDef: must be a table" }
	end
	checkCommon(def, "ActionDef", errors)
	if table.find(Check.TARGETS, def.target) == nil then
		table.insert(errors, 'ActionDef.target: "player", "userId" or "none"')
	end
	if def.presets ~= nil and type(def.presets) ~= "table" then
		table.insert(errors, "ActionDef.presets: a list of strings keys")
	end
	if def.durations ~= nil and type(def.durations) ~= "table" then
		table.insert(errors, "ActionDef.durations: a list of seconds")
	end
	if def.freeText ~= nil and type(def.freeText) ~= "boolean" then
		table.insert(errors, "ActionDef.freeText: a boolean")
	end
	if type(def.run) ~= "function" then
		table.insert(errors, "ActionDef.run: a function(staff, targetUserId?, args) -> (boolean, string?)")
	end
	return errors
end

function Check.tabDef(def: any): { string }
	local errors: { string } = {}
	if type(def) ~= "table" then
		return { "TabDef: must be a table" }
	end
	checkCommon(def, "TabDef", errors)
	if type(def.fetch) ~= "function" then
		table.insert(errors, "TabDef.fetch: a function(staff, page) -> { rows, columns }")
	end
	if def.rowActions ~= nil then
		if type(def.rowActions) ~= "table" then
			table.insert(errors, "TabDef.rowActions: a list")
		else
			for i, ra in def.rowActions do
				if type(ra) ~= "table" or type(ra.run) ~= "function" then
					table.insert(errors, "TabDef.rowActions[" .. i .. "]: { id, permission, labelKey, run }")
				else
					checkCommon(ra, `TabDef.rowActions[{i}]`, errors)
					for _, field in { "presets", "notes" } do
						local v = ra[field]
						local okList = v == nil or type(v) == "table"
						if type(v) == "table" then
							for _, k in v do
								if type(k) ~= "string" or #k > 64 or string.find(k, "|", 1, true) ~= nil then
									okList = false
								end
							end
						end
						if not okList then
							table.insert(
								errors,
								`TabDef.rowActions[{i}].{field}: a list of strings keys (no "|")`
							)
						end
					end
				end
			end
		end
	end
	return errors
end

return Check
