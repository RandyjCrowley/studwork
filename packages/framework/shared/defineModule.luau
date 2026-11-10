--!strict
--[[
	defineModule(spec) -> ModuleRef (module-api.md §2). Validates and freezes the definition. No
	side effects beyond remembering the returned table as a genuine ModuleRef (a weak set), so
	requiring a module definition is always safe.

	Every problem is collected and reported together:
	  [StudWork] defineModule(Economy): invalid module definition:
	    - dependsOn[1] is the string "Collection": dependencies are references ...
]]

local Freeze = require(script.Parent.Freeze)
local Schema = require(script.Parent.Schema)
local Semver = require(script.Parent.Semver)

local DefineModule = {}

-- Base ItemDef fields (module-api.md §12): no module may claim these as an item-field namespace.
DefineModule.BASE_ITEM_FIELDS = table.freeze({
	id = "string",
	name = "string",
	rarity = "string?",
	model = "string?",
	icon = "string?",
	tags = "{string}?",
	source = "string?",
	keepOnRebirth = "boolean?",
})

DefineModule.RESERVED_DATA_KEYS = table.freeze({ _framework = true, _versions = true })

local TOP_FIELDS = {
	name = true,
	version = true,
	framework = true,
	dependsOn = true,
	optional = true,
	config = true,
	data = true,
	itemFields = true,
	theme = true,
	server = true,
	client = true,
	description = true,
}
local DATA_FIELDS = {
	key = true,
	version = true,
	default = true,
	migrations = true,
	replicate = true,
	serverOnly = true,
	sanitize = true,
	adopts = true,
}
local THEME_FIELDS =
	{ colors = true, fonts = true, metrics = true, sounds = true, rarity = true, preset = true }

local refs: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

function DefineModule.isModuleRef(value: any): boolean
	return type(value) == "table" and refs[value] == true
end

local function isPascalName(s: any): boolean
	return type(s) == "string" and #s <= 48 and string.match(s, "^%u[%w]*$") ~= nil
end
DefineModule.isPascalName = isPascalName

local function isId(s: any): boolean
	return type(s) == "string" and #s > 0 and #s <= 48 and string.match(s, "^[%w_%-%.:]+$") ~= nil
end
DefineModule.isId = isId

local function checkRefList(list: any, field: string, errors: { string })
	if list == nil then
		return
	end
	if type(list) ~= "table" then
		table.insert(errors, `{field} must be a list of module references`)
		return
	end
	for i, dep in list do
		if type(i) ~= "number" then
			table.insert(errors, `{field} must be a list (array), got key {tostring(i)}`)
		elseif type(dep) == "string" then
			table.insert(
				errors,
				`{field}[{i}] is the string "{dep}": dependencies are references, not strings; require that module's module.luau and list the result`
			)
		elseif not DefineModule.isModuleRef(dep) then
			table.insert(
				errors,
				`{field}[{i}] is not a ModuleRef (a value returned by StudWork.defineModule)`
			)
		end
	end
end

local function checkData(data: any, errors: { string })
	if type(data) ~= "table" then
		table.insert(errors, "data must be a table { key, version, default, ... }")
		return
	end
	for k in data do
		if not DATA_FIELDS[k] then
			table.insert(errors, `data.{tostring(k)}: unknown field`)
		end
	end
	if not isId(data.key) then
		table.insert(errors, "data.key must be a short id string ([%w_-.:], <= 48 chars)")
	elseif DefineModule.RESERVED_DATA_KEYS[data.key] or string.sub(data.key, 1, 1) == "_" then
		table.insert(
			errors,
			`data.key '{data.key}' is reserved: keys starting with '_' belong to the framework`
		)
	end
	if type(data.version) ~= "number" or data.version < 1 or data.version % 1 ~= 0 then
		table.insert(errors, "data.version must be an integer >= 1")
	end
	if type(data.default) ~= "table" or getmetatable(data.default) ~= nil then
		table.insert(errors, "data.default must be a plain table (the section's shape for a new player)")
	end
	if data.migrations ~= nil then
		local isPlain = type(data.migrations) == "table" and getmetatable(data.migrations) == nil
		if isPlain then
			for k, fn in data.migrations do
				if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
					table.insert(
						errors,
						`data.migrations key {tostring(k)} must be an integer toVersion >= 1`
					)
				elseif type(fn) ~= "function" then
					table.insert(errors, `data.migrations[{k}] must be a function(old) -> new`)
				elseif type(data.version) == "number" and k > data.version then
					table.insert(errors, `data.migrations[{k}] is above data.version {data.version}`)
				end
			end
		elseif type(data.migrations) ~= "userdata" and type(data.migrations) ~= "table" then
			table.insert(
				errors,
				"data.migrations must be a migrations folder or a { [toVersion] = fn } table"
			)
		end
	end
	-- M6: replicate is an explicit field list, or false/nil. `true` is not an option.
	if data.replicate == true then
		table.insert(
			errors,
			'data.replicate = true is not supported (design review M6): list the fields the owning client sees, e.g. replicate = { "currency" }, or use false'
		)
	elseif data.replicate ~= nil and data.replicate ~= false then
		if type(data.replicate) ~= "table" then
			table.insert(errors, "data.replicate must be a list of field names, or false")
		else
			for i, f in data.replicate do
				if type(i) ~= "number" or type(f) ~= "string" then
					table.insert(errors, `data.replicate[{tostring(i)}] must be a field name string`)
				elseif type(data.default) == "table" and data.default[f] == nil then
					table.insert(errors, `data.replicate[{i}] '{f}' is not a field of data.default`)
				end
			end
		end
	end
	if data.serverOnly ~= nil then
		if type(data.serverOnly) ~= "table" then
			table.insert(errors, "data.serverOnly must be a list of field names")
		else
			for i, f in data.serverOnly do
				if type(f) ~= "string" then
					table.insert(errors, `data.serverOnly[{tostring(i)}] must be a field name string`)
				end
			end
		end
	end
	if data.sanitize ~= nil and type(data.sanitize) ~= "function" then
		table.insert(errors, "data.sanitize must be a function(section) -> section")
	end
	if data.adopts ~= nil and not isPascalName(data.adopts) then
		table.insert(
			errors,
			"data.adopts must be the PascalCase name of the module whose section this one takes over"
		)
	end
end

local function checkConfig(config: any, errors: { string })
	if type(config) ~= "table" then
		table.insert(errors, "config must be a table { schema, defaults }")
		return
	end
	for k in config do
		if k ~= "schema" and k ~= "defaults" then
			table.insert(errors, `config.{tostring(k)}: unknown field (expected schema, defaults)`)
		end
	end
	if config.schema == nil then
		table.insert(errors, "config.schema is required when config is given")
		return
	end
	Schema.checkSchema(config.schema, "config.schema", errors)
	if config.defaults ~= nil then
		if type(config.defaults) ~= "table" then
			table.insert(errors, "config.defaults must be a table")
			return
		end
		for key, value in config.defaults do
			local entry = if type(config.schema) == "table" then config.schema[key] else nil
			if entry == nil then
				table.insert(errors, `config.defaults.{tostring(key)}: no such key in config.schema`)
			else
				Schema.checkEntry(entry, value, `config.defaults.{tostring(key)}`, errors)
			end
		end
	end
end

local function checkItemFields(itemFields: any, errors: { string })
	if type(itemFields) ~= "table" then
		table.insert(
			errors,
			"itemFields must be a table { item = { ns = schema }, mutation = { ns = schema } }"
		)
		return
	end
	for kind, namespaces in itemFields do
		if kind ~= "item" and kind ~= "mutation" then
			table.insert(errors, `itemFields.{tostring(kind)}: unknown kind (expected item, mutation)`)
			continue
		end
		if type(namespaces) ~= "table" then
			table.insert(errors, `itemFields.{kind} must be a table of namespace -> schema`)
			continue
		end
		for ns, schema in namespaces do
			local where = `itemFields.{kind}.{tostring(ns)}`
			if not isId(ns) then
				table.insert(errors, `{where}: namespace must be an id string`)
			elseif DefineModule.BASE_ITEM_FIELDS[ns] then
				table.insert(errors, `{where}: '{ns}' is a base ItemDef field, not a namespace`)
			else
				Schema.checkSchema(schema, where, errors)
			end
		end
	end
end

local function checkTheme(theme: any, errors: { string })
	if type(theme) ~= "table" then
		table.insert(errors, "theme must be a table of token groups")
		return
	end
	for k, group in theme do
		if not THEME_FIELDS[k] then
			table.insert(errors, `theme.{tostring(k)}: unknown token group`)
		elseif k ~= "preset" and type(group) ~= "table" then
			table.insert(errors, `theme.{k} must be a table`)
		end
	end
	if type(theme.colors) == "table" then
		for name, hex in theme.colors do
			if type(hex) ~= "string" or string.match(hex, "^#%x%x%x%x%x%x$") == nil then
				table.insert(errors, `theme.colors.{tostring(name)} must be '#RRGGBB'`)
			end
		end
	end
end

local function freezeRef(spec: any): any
	local out = {}
	for k, v in spec do
		if k == "dependsOn" or k == "optional" then
			out[k] = table.freeze(table.clone(v)) -- keep ref identity
		elseif k == "data" then
			local d = {}
			for dk, dv in v do
				d[dk] = if dk == "migrations" then dv else Freeze.freezeCopy(dv)
			end
			out[k] = table.freeze(d)
		else
			out[k] = Freeze.freezeCopy(v)
		end
	end
	out.dependsOn = out.dependsOn or table.freeze({})
	out.optional = out.optional or table.freeze({})
	out.server = out.server or out.name
	return table.freeze(out)
end

function DefineModule.defineModule(spec: any): any
	local errors: { string } = {}
	if type(spec) ~= "table" then
		error("[StudWork] defineModule expects a table", 2)
	end
	local label = if type(spec.name) == "string" then spec.name else "?"
	for k in spec do
		if not TOP_FIELDS[k] then
			table.insert(errors, `{tostring(k)}: unknown field`)
		end
	end
	if not isPascalName(spec.name) then
		table.insert(
			errors,
			"name must be a PascalCase string (letters and digits, starting upper-case, <= 48 chars)"
		)
	end
	if not Semver.isVersion(spec.version) then
		table.insert(errors, 'version must be a semver string like "1.0.0"')
	end
	if not Semver.isRange(spec.framework) then
		table.insert(errors, 'framework must be a semver range like "^1.3.0"')
	end
	checkRefList(spec.dependsOn, "dependsOn", errors)
	checkRefList(spec.optional, "optional", errors)
	if type(spec.dependsOn) == "table" and type(spec.optional) == "table" then
		for _, d in spec.dependsOn do
			if table.find(spec.optional, d) then
				table.insert(errors, `{tostring(d.name)} is listed in both dependsOn and optional`)
			end
		end
	end
	if spec.config ~= nil then
		checkConfig(spec.config, errors)
	end
	if spec.data ~= nil then
		checkData(spec.data, errors)
	end
	if spec.itemFields ~= nil then
		checkItemFields(spec.itemFields, errors)
	end
	if spec.theme ~= nil then
		checkTheme(spec.theme, errors)
	end
	if spec.server ~= nil and not isPascalName(spec.server) then
		table.insert(errors, "server must be the PascalCase folder name under ServerScriptService.Modules")
	end
	if spec.client ~= nil and spec.client ~= false and not isPascalName(spec.client) then
		table.insert(
			errors,
			"client must be the PascalCase folder name under ReplicatedStorage.Modules (or nil)"
		)
	end
	if spec.description ~= nil and type(spec.description) ~= "string" then
		table.insert(errors, "description must be a string")
	end
	if #errors > 0 then
		error(
			`[StudWork] defineModule({label}): invalid module definition:\n  - {table.concat(errors, "\n  - ")}`,
			2
		)
	end
	local ref = freezeRef(spec)
	refs[ref] = true
	return ref
end

return table.freeze(DefineModule)
