--!strict
--[[
	GameConfig validation for the module framework (module-api.md §3 step 2, §11, §12, §13). Pure,
	shared by both sides. Like v1.2's ConfigValidate, ALL errors are collected and reported
	together, never fail-fast.

	ConfigValidate.validate(order, gameConfig) -> result
	  result.configs[name]  merged (defaults <- GameConfig.config.<Name>) frozen config per module
	  result.items          frozen item catalog (ItemFields.catalog)
	  result.theme          frozen merged theme
	  result.errors         every error
	  result.warnings       unknown keys ("typo?"), config for modules that aren't enabled
]]

local DefineModule = require(script.Parent.defineModule)
local Env = require(script.Parent.Env)
local Flags = require(script.Parent.Flags)
local Strings = require(script.Parent.Strings)
local Freeze = require(script.Parent.Freeze)
local ItemFields = require(script.Parent.ItemFields)
local Schema = require(script.Parent.Schema)
local Theme = require(script.Parent.Theme)

local ConfigValidate = {}

ConfigValidate.TOP_LEVEL = table.freeze({
	gameId = true,
	modules = true,
	config = true,
	items = true,
	products = true,
	events = true,
	theme = true,
	client = true,
	data = true,
	compliance = true,
	analytics = true, -- framework Analytics' funnel/clientSteps (read by server/Analytics)
	shop = true, -- (v1.6.1) framework Shop tuning (passPrefetchTimeout; server/Shop validates it)
	-- (v1.7.0, §23) environments, flags, store budgets, strings; all optional, inert until set
	environments = true,
	flags = true,
	flagOverride = true,
	storeBudgets = true,
	strings = true,
	localization = true,
})

export type Result = {
	strings: { [string]: string }, -- (v1.7.0) every module's English defaults, function forms run
	configs: { [string]: any },
	items: any,
	theme: any,
	errors: { string },
	warnings: { string },
}

local function inRange(v: any, lo: number, hi: number): boolean
	return type(v) == "number" and v == v and v >= lo and v <= hi
end

-- GameConfig.storeBudgets (§23.5): a bad value is a boot error.
function ConfigValidate.checkStoreBudgets(sb: any, errors: { string }, warnings: { string }?)
	if sb == nil then
		return
	end
	if type(sb) ~= "table" then
		table.insert(errors, "storeBudgets must be a table")
		return
	end
	local known = { orderedReserve = true, memoryUnits = true, memory = true, censusSeconds = true }
	for k in sb do
		if not known[k] then
			table.insert(errors, `storeBudgets.{tostring(k)}: unknown key`)
		end
	end
	if sb.orderedReserve ~= nil and not inRange(sb.orderedReserve, 0, 0.9) then
		table.insert(errors, "storeBudgets.orderedReserve must be a number in 0..0.9")
	end
	if sb.censusSeconds ~= nil and not inRange(sb.censusSeconds, 30, 600) then
		table.insert(errors, "storeBudgets.censusSeconds must be a number in 30..600")
	end
	if sb.memoryUnits ~= nil then
		if type(sb.memoryUnits) ~= "table" then
			table.insert(errors, "storeBudgets.memoryUnits must be { base, perPlayer }")
		else
			for _, k in { "base", "perPlayer" } do
				local v = sb.memoryUnits[k]
				if v ~= nil and not inRange(v, 0, 1e9) then
					table.insert(errors, `storeBudgets.memoryUnits.{k} must be a number >= 0`)
				end
			end
		end
	end
	local mem = sb.memory
	if mem ~= nil then
		if type(mem) ~= "table" then
			table.insert(errors, "storeBudgets.memory must be { reserve, defaultShare, shares }")
			return
		end
		if mem.reserve ~= nil and not inRange(mem.reserve, 0.05, 0.9) then
			table.insert(errors, "storeBudgets.memory.reserve must be a number in 0.05..0.9")
		end
		if mem.defaultShare ~= nil and not inRange(mem.defaultShare, 0.01, 1) then
			table.insert(errors, "storeBudgets.memory.defaultShare must be a number in 0.01..1")
		end
		local total = 0
		if mem.shares ~= nil then
			if type(mem.shares) ~= "table" then
				table.insert(errors, "storeBudgets.memory.shares must be { [ModuleName] = fraction }")
			else
				for name, share in mem.shares do
					if not inRange(share, 0.01, 1) then
						table.insert(
							errors,
							`storeBudgets.memory.shares.{tostring(name)} must be a number in 0.01..1`
						)
					else
						total += share
					end
				end
			end
		end
		local reserve = if inRange(mem.reserve, 0.05, 0.9) then mem.reserve else 0.2
		if warnings ~= nil and total > 1 - reserve then
			table.insert(
				warnings,
				`storeBudgets.memory.shares add up to {total}, more than 1 - reserve ({1 - reserve}); the total cap still holds`
			)
		end
	end
end

local function checkFlagOverride(fo: any, errors: { string })
	if fo == nil then
		return
	end
	if type(fo) ~= "table" then
		table.insert(errors, "flagOverride must be a table { enabled, keyPrefix, refreshSeconds }")
		return
	end
	for k in fo do
		if k ~= "enabled" and k ~= "keyPrefix" and k ~= "refreshSeconds" then
			table.insert(errors, `flagOverride.{tostring(k)}: unknown key`)
		end
	end
	if fo.enabled ~= nil and type(fo.enabled) ~= "boolean" then
		table.insert(errors, "flagOverride.enabled must be a boolean")
	end
	if fo.keyPrefix ~= nil and (type(fo.keyPrefix) ~= "string" or fo.keyPrefix == "") then
		table.insert(errors, "flagOverride.keyPrefix must be a non-empty string")
	end
	if fo.refreshSeconds ~= nil and not inRange(fo.refreshSeconds, 5, 600) then
		table.insert(errors, "flagOverride.refreshSeconds must be a number in 5..600")
	end
end

local function checkLocalization(loc: any, errors: { string })
	if loc == nil then
		return
	end
	if type(loc) ~= "table" then
		table.insert(errors, "localization must be { sourceLocale, useTranslators }")
		return
	end
	for k in loc do
		if k ~= "sourceLocale" and k ~= "useTranslators" then
			table.insert(errors, `localization.{tostring(k)}: unknown key`)
		end
	end
	if loc.sourceLocale ~= nil and (type(loc.sourceLocale) ~= "string" or loc.sourceLocale == "") then
		table.insert(errors, "localization.sourceLocale must be a locale id string")
	end
	if loc.useTranslators ~= nil and type(loc.useTranslators) ~= "boolean" then
		table.insert(errors, "localization.useTranslators must be a boolean")
	end
end

-- Every module's English defaults (a table, or the function form run once with the merged
-- config), then GameConfig.strings checked against them. -> { [key] = text }
local function collectStrings(
	order: { any },
	configs: { [string]: any },
	gameStrings: any,
	errors: { string },
	warnings: { string }
): { [string]: string }
	local defaults: { [string]: string } = table.clone(Strings.FRAMEWORK)
	for _, ref in order do
		local s = ref.strings
		if type(s) == "function" then
			local ok, result = pcall(s, configs[ref.name])
			if not ok then
				table.insert(errors, `{ref.name}: strings(config) failed: {tostring(result)}`)
				continue
			end
			local problems: { string } = {}
			Strings.check(result, ref.name, problems)
			for _, p in problems do
				table.insert(errors, `{ref.name}: {p}`)
			end
			s = if #problems == 0 then result else nil
		end
		if type(s) == "table" then
			for key, text in s do
				defaults[key] = text
			end
		end
	end
	if gameStrings ~= nil then
		if type(gameStrings) ~= "table" then
			table.insert(errors, "strings must be a table of key = English text")
			return defaults
		end
		for key, text in gameStrings do
			if not Strings.isKey(key) then
				table.insert(errors, `strings.{tostring(key)}: not a valid string key (<namespace>.<name>)`)
			elseif type(text) ~= "string" or text == "" then
				table.insert(errors, `strings.{key} must be a non-empty string`)
			elseif
				defaults[key] == nil
				and string.sub(key, 1, 5) ~= "game."
				and string.sub(key, 1, 3) ~= "ui."
			then
				table.insert(warnings, `strings.{key}: no module or framework defines this key (typo?)`)
			end
		end
	end
	return defaults
end

local OPEN_CLOUD_METHODS = { GET = true, POST = true, PATCH = true, DELETE = true }

-- ServerConfig.openCloud (§23.7): the shape only; the allow-list is applied per request (server/OpenCloud).
function ConfigValidate.checkOpenCloud(oc: any, errors: { string })
	if oc == nil then
		return
	end
	if type(oc) ~= "table" then
		table.insert(errors, "ServerConfig.openCloud must be { perMinute, secrets }")
		return
	end
	for k in oc do
		if k ~= "perMinute" and k ~= "secrets" then
			table.insert(errors, `ServerConfig.openCloud.{tostring(k)}: unknown key`)
		end
	end
	if oc.perMinute ~= nil and not (inRange(oc.perMinute, 1, 1e9)) then
		table.insert(errors, "ServerConfig.openCloud.perMinute must be a number >= 1")
	end
	if oc.secrets == nil then
		return
	end
	if type(oc.secrets) ~= "table" then
		table.insert(
			errors,
			"ServerConfig.openCloud.secrets must be { [secretName] = { modules, methods, paths } }"
		)
		return
	end
	for name, rule in oc.secrets do
		local where = `ServerConfig.openCloud.secrets.{tostring(name)}`
		if type(name) ~= "string" or name == "" or type(rule) ~= "table" then
			table.insert(errors, where .. " must be a rule table { modules, methods, paths }")
			continue
		end
		for _, field in { "modules", "methods", "paths" } do
			local list = rule[field]
			if type(list) ~= "table" or #list == 0 then
				table.insert(errors, `{where}.{field} must be a non-empty list of strings`)
				continue
			end
			for i, v in list do
				if type(v) ~= "string" or v == "" then
					table.insert(errors, `{where}.{field}[{tostring(i)}] must be a non-empty string`)
				elseif field == "methods" and not OPEN_CLOUD_METHODS[v] then
					table.insert(
						errors,
						`{where}.methods[{tostring(i)}] '{v}' must be GET, POST, PATCH or DELETE`
					)
				end
			end
		end
	end
end

-- extra (optional): { serverConfig = ServerConfig?, env = Env.Info? } (server side; the client passes env only)
function ConfigValidate.validate(order: { any }, gameConfig: any, extra: any?): Result
	local errors: { string } = {}
	local warnings: { string } = {}
	local configs: { [string]: any } = {}
	local result: Result =
		{ strings = {}, configs = configs, items = nil, theme = nil, errors = errors, warnings = warnings }
	if type(gameConfig) ~= "table" then
		table.insert(errors, "GameConfig must be a table")
		return result
	end
	if not DefineModule.isId(gameConfig.gameId) then
		table.insert(errors, "gameId must be a short id string ([%w_-.:], <= 48 chars)")
	end
	for key in gameConfig do
		if not ConfigValidate.TOP_LEVEL[key] then
			table.insert(warnings, `GameConfig.{tostring(key)}: unknown top-level key (typo?)`)
		end
	end

	local given = gameConfig.config
	if given ~= nil and type(given) ~= "table" then
		table.insert(errors, "config must be a table of <ModuleName> = { ... }")
		given = nil
	end
	local enabled: { [string]: boolean } = {}
	for _, ref in order do
		enabled[ref.name] = true
		local raw = if given then given[ref.name] else nil
		if raw ~= nil and type(raw) ~= "table" then
			table.insert(errors, `config.{ref.name} must be a table`)
			raw = nil
		end
		if ref.config == nil then
			if raw ~= nil then
				table.insert(errors, `config.{ref.name}: module '{ref.name}' declares no config schema`)
			end
			configs[ref.name] = table.freeze({})
			continue
		end
		local merged = Freeze.deepMerge(ref.config.defaults or {}, raw)
		Schema.validate(ref.config.schema, merged, `config.{ref.name}`, errors, warnings)
		configs[ref.name] = Freeze.deepFreeze(merged)
	end
	if given then
		for name in given do
			if not enabled[name] then
				table.insert(
					warnings,
					`config.{tostring(name)}: '{tostring(name)}' is not enabled in GameConfig.modules; its config is ignored`
				)
			end
		end
	end

	local itemNs = ItemFields.collect(order, errors)
	ItemFields.validateItems(gameConfig.items, itemNs, errors)
	result.items = ItemFields.catalog(if type(gameConfig.items) == "table" then gameConfig.items else {})
	result.theme = Theme.merge(order, gameConfig.theme, errors, configs, warnings)

	-- (v1.7.0, §23) the framework-level keys: all optional, validated together with the rest
	local serverConfig = if type(extra) == "table" then extra.serverConfig else nil
	local envInfo = if type(extra) == "table" then extra.env else nil
	local envErrors, envWarnings = Env.validate(gameConfig.environments, envInfo)
	for _, e in envErrors do
		table.insert(errors, e)
	end
	for _, w in envWarnings do
		table.insert(warnings, w)
	end
	local serverFlags = if type(serverConfig) == "table" then serverConfig.flags else nil
	if gameConfig.flags ~= nil or serverFlags ~= nil then
		for _, e in Flags.validate(gameConfig.flags, serverFlags, nil) do
			table.insert(errors, e)
		end
	end
	if type(serverConfig) == "table" then
		ConfigValidate.checkOpenCloud(serverConfig.openCloud, errors)
	end
	checkFlagOverride(gameConfig.flagOverride, errors)
	ConfigValidate.checkStoreBudgets(gameConfig.storeBudgets, errors, warnings)
	checkLocalization(gameConfig.localization, errors)
	result.strings = collectStrings(order, configs, gameConfig.strings, errors, warnings)
	return result
end

return ConfigValidate
