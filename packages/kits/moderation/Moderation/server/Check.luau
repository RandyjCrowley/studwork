--!strict
--[[
	Moderation config checks the schema language can't express (ladders, offences, auto sources).
	Pure: Check.config(cfg, serverConfig?) -> { string } (every problem, never fail-fast); the
	server part raises them together at init, so a bad config fails boot.
]]

local Check = {}

Check.STEP_ACTIONS = table.freeze({ "warn", "mute", "kick", "ban" })
Check.AUTO_ACTIONS = table.freeze({ "warn", "mute", "kick", "ban" })

local function isId(v: any): boolean
	return type(v) == "string" and #v >= 1 and #v <= 32 and string.match(v, "^[%w_]+$") ~= nil
end

local function isPositive(v: any): boolean
	return type(v) == "number" and v == v and v > 0 and v < math.huge
end

local function checkSources(sources: any, path: string, offenses: any, errors: { string })
	if sources == nil then
		return
	end
	if type(sources) ~= "table" then
		table.insert(errors, `{path}: must be a table`)
		return
	end
	for name, src in sources do
		local p = `{path}.{tostring(name)}`
		if not isId(name) then
			table.insert(errors, `{p}: a source name is 1..32 letters, digits or _`)
		end
		if type(src) ~= "table" then
			table.insert(errors, p .. ": must be { threshold, windowSeconds, offense }")
			continue
		end
		if not isPositive(src.threshold) then
			table.insert(errors, `{p}.threshold: a number > 0`)
		end
		if not isPositive(src.windowSeconds) then
			table.insert(errors, `{p}.windowSeconds: a number > 0`)
		end
		if type(src.offense) ~= "string" or offenses[src.offense] == nil then
			table.insert(
				errors,
				`{p}.offense: '{tostring(src.offense)}' is not in config.Moderation.offenses`
			)
		end
	end
end

-- (Addendum G) a ladder step's own message key: one of that action's presets
local function keyList(action: string): string
	return if action == "ban" then "ban.displayKeys (or an offence displayKey)" else `{action}.presetKeys`
end

local function stepKeyAllowed(cfg: any, action: string, key: any): boolean
	if type(key) ~= "string" then
		return false
	end
	if action == "ban" then
		if table.find(cfg.ban.displayKeys, key) ~= nil then
			return true
		end
		for _, offense in cfg.offenses do
			if type(offense) == "table" and offense.displayKey == key then
				return true
			end
		end
		return false
	end
	local section = cfg[action]
	return type(section) == "table" and table.find(section.presetKeys, key) ~= nil
end

function Check.config(cfg: any, serverConfig: any?): { string }
	local errors: { string } = {}
	for name, steps in cfg.ladders do
		local p = `config.Moderation.ladders.{tostring(name)}`
		if not isId(name) then
			table.insert(errors, `{p}: a ladder name is 1..32 letters, digits or _`)
		end
		if #steps == 0 then
			table.insert(errors, `{p}: needs at least one step`)
		end
		for i, step in steps do
			if type(step) ~= "table" or table.find(Check.STEP_ACTIONS, step.action) == nil then
				table.insert(errors, `{p}[{i}].action: one of warn, mute, kick, ban`)
			elseif step.seconds ~= nil and step.seconds ~= -1 and not isPositive(step.seconds) then
				table.insert(errors, `{p}[{i}].seconds: a number > 0 (or -1 = permanent ban)`)
			elseif step.key ~= nil and not stepKeyAllowed(cfg, step.action, step.key) then
				table.insert(
					errors,
					`{p}[{i}].key: '{tostring(step.key)}' is not one of config.Moderation.{keyList(
						step.action
					)}`
				)
			end
		end
	end
	for name, offense in cfg.offenses do
		local p = `config.Moderation.offenses.{tostring(name)}`
		if not isId(name) then
			table.insert(errors, `{p}: an offence name is 1..32 letters, digits or _`)
		end
		if type(offense.ladder) ~= "string" or cfg.ladders[offense.ladder] == nil then
			table.insert(
				errors,
				`{p}.ladder: '{tostring(offense.ladder)}' is not in config.Moderation.ladders`
			)
		end
		if offense.displayKey ~= nil and type(offense.displayKey) ~= "string" then
			table.insert(errors, `{p}.displayKey: a strings key`)
		end
		if offense.warnKey ~= nil and table.find(cfg.warn.presetKeys, offense.warnKey) == nil then
			table.insert(
				errors,
				`{p}.warnKey: '{tostring(offense.warnKey)}' is not one of config.Moderation.warn.presetKeys`
			)
		end
	end
	for _, perm in cfg.auto.permissions do
		if table.find(Check.AUTO_ACTIONS, perm) == nil then
			table.insert(
				errors,
				`config.Moderation.auto.permissions: '{tostring(perm)}' is not one of warn, mute, kick, ban`
			)
		end
	end
	checkSources(cfg.auto.sources, "config.Moderation.auto.sources", cfg.offenses, errors)
	local sc = if type(serverConfig) == "table" then serverConfig else {}
	checkSources(sc.autoSources, "ServerConfig.Moderation.autoSources", cfg.offenses, errors)
	if sc.admins ~= nil then
		local ok = type(sc.admins) == "table"
		if ok then
			for _, id in sc.admins do
				if type(id) ~= "number" then
					ok = false
				end
			end
		end
		if not ok then
			table.insert(errors, "ServerConfig.Moderation.admins: a list of user ids")
		end
	end
	if cfg.serverBan.defaultSeconds > cfg.serverBan.maxSeconds then
		table.insert(errors, "config.Moderation.serverBan.defaultSeconds: more than maxSeconds")
	end
	if cfg.mute.defaultSeconds > cfg.mute.maxSeconds then
		table.insert(errors, "config.Moderation.mute.defaultSeconds: more than maxSeconds")
	end
	local function durations(list: any, path: string, max: number?, permanent: boolean)
		for i, v in list do
			local okValue = (permanent and v == -1)
				or (isPositive(v) and v % 1 == 0 and (max == nil or v <= max))
			if not okValue then
				table.insert(
					errors,
					`{path}[{i}]: an integer number of seconds > 0{if max then " and at most " .. max else ""}{if permanent
						then " (or -1 = permanent)"
						else ""}`
				)
			end
		end
	end
	durations(cfg.panel.banDurations, "config.Moderation.panel.banDurations", nil, true)
	durations(cfg.panel.muteDurations, "config.Moderation.panel.muteDurations", cfg.mute.maxSeconds, false)
	durations(
		cfg.panel.serverBanDurations,
		"config.Moderation.panel.serverBanDurations",
		cfg.serverBan.maxSeconds,
		false
	)
	if table.find(cfg.ban.displayKeys, cfg.ban.defaultDisplayKey) == nil then
		table.insert(errors, "config.Moderation.ban.defaultDisplayKey: must be one of ban.displayKeys")
	end
	return errors
end

return Check
