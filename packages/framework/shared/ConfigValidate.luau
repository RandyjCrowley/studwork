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
})

export type Result = {
	configs: { [string]: any },
	items: any,
	theme: any,
	errors: { string },
	warnings: { string },
}

function ConfigValidate.validate(order: { any }, gameConfig: any): Result
	local errors: { string } = {}
	local warnings: { string } = {}
	local configs: { [string]: any } = {}
	local result: Result =
		{ configs = configs, items = nil, theme = nil, errors = errors, warnings = warnings }
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
	return result
end

return ConfigValidate
