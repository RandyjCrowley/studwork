--!strict
-- Shared schema, exact value validation and typed wire conversion for preferences.
local Schema = {}
export type Value = boolean | number | string
export type Definition = {
	id: string,
	type: string,
	default: Value,
	category: string,
	labelKey: string,
	descriptionKey: string?,
	scope: string,
	min: number?,
	max: number?,
	step: number?,
	choices: { string }?,
	apply: ((Value) -> ())?,
}
Schema.DEFAULTS = {
	builtins = {},
	schema = {},
	debounceSeconds = 0.5,
	saveDebounceSeconds = 2,
	maxSettings = 128,
	maxBatch = 32,
	rate = { rate = 4, burst = 8 },
	audio = { musicGroup = "CoreMusic", effectsGroup = "CoreEffects" },
}
Schema.MAX_REQUEST = 4294967295
Schema.STEP_EPSILON = 0.000001
local function finite(v: any): boolean
	return type(v) == "number" and v == v and math.abs(v) < math.huge
end
function Schema.id(v: any): boolean
	return type(v) == "string" and #v > 0 and #v <= 32 and string.match(v, "^[%w_]+$") ~= nil
end
local function key(v: any): boolean
	return type(v) == "string" and #v <= 100 and string.match(v, "^[%a][%w_]*%.[%w_.]+$") ~= nil
end
function Schema.validate(def: any, value: any): boolean
	if type(def) ~= "table" then
		return false
	end
	if def.type == "toggle" then
		return type(value) == "boolean"
	end
	if def.type == "slider" then
		if
			not finite(value)
			or not finite(def.min)
			or not finite(def.max)
			or not finite(def.step)
			or def.step <= 0
			or def.max < def.min
		then
			return false
		end
		if value < def.min or value > def.max then
			return false
		end
		local steps = (value - def.min) / def.step
		return math.abs(steps - math.floor(steps + 0.5)) <= Schema.STEP_EPSILON
	end
	if def.type == "choice" then
		if type(value) ~= "string" or type(def.choices) ~= "table" then
			return false
		end
		for _, choice in def.choices do
			if choice == value then
				return true
			end
		end
	end
	return false
end
function Schema.validateDefinition(def: any): (boolean, string?)
	if type(def) ~= "table" or getmetatable(def) ~= nil or not Schema.id(def.id) then
		return false, "definition"
	end
	local allowed = {
		id = true,
		type = true,
		default = true,
		category = true,
		labelKey = true,
		descriptionKey = true,
		scope = true,
		min = true,
		max = true,
		step = true,
		choices = true,
		apply = true,
	}
	for field in def do
		if not allowed[field] then
			return false, "field"
		end
	end
	if
		not Schema.id(def.category)
		or not key(def.labelKey)
		or (def.descriptionKey ~= nil and not key(def.descriptionKey))
	then
		return false, "metadata"
	end
	if def.scope ~= "client" and def.scope ~= "saved" then
		return false, "scope"
	end
	if def.apply ~= nil and type(def.apply) ~= "function" then
		return false, "apply"
	end
	if def.type == "choice" then
		if
			type(def.choices) ~= "table"
			or getmetatable(def.choices) ~= nil
			or #def.choices == 0
			or #def.choices > 32
		then
			return false, "choices"
		end
		local seen: { [string]: boolean } = {}
		local n = 0
		for i, choice in def.choices do
			if
				type(i) ~= "number"
				or i % 1 ~= 0
				or i < 1
				or i > #def.choices
				or type(choice) ~= "string"
				or #choice == 0
				or #choice > 64
				or string.find(choice, "%c")
				or seen[choice]
			then
				return false, "choices"
			end
			seen[choice] = true
			n += 1
		end
		if n ~= #def.choices then
			return false, "choices"
		end
	elseif def.choices ~= nil then
		return false, "choices"
	end
	if def.type == "slider" then
		if
			not finite(def.min)
			or not finite(def.max)
			or not finite(def.step)
			or def.min >= def.max
			or def.step <= 0
			or def.step > def.max - def.min
		then
			return false, "range"
		end
	elseif def.min ~= nil or def.max ~= nil or def.step ~= nil then
		return false, "range"
	end
	if not Schema.validate(def, def.default) then
		return false, "default"
	end
	return true, nil
end
local function builtin(id: string, kind: string, default: Value, category: string, scope: string): any
	return {
		id = id,
		type = kind,
		default = default,
		category = category,
		scope = scope,
		labelKey = "Settings." .. id,
	}
end
function Schema.builtins(_config: any?): { [string]: any }
	local defs: { [string]: any } = {}
	for _, id in { "musicVolume", "effectsVolume" } do
		local d = builtin(id, "slider", 1, "audio", "saved")
		d.min, d.max, d.step = 0, 1, 0.05
		defs[id] = d
	end
	defs.reduceMotion = builtin("reduceMotion", "toggle", false, "accessibility", "client")
	defs.lowDetail = builtin("lowDetail", "toggle", false, "graphics", "client")
	defs.uiScale = builtin("uiScale", "slider", 1, "accessibility", "client")
	defs.uiScale.min, defs.uiScale.max, defs.uiScale.step = 0.8, 1.2, 0.05
	defs.textSize = builtin("textSize", "choice", "platform", "accessibility", "client")
	defs.textSize.choices = { "platform", "standard", "large" }
	defs.colorBlind = builtin("colorBlind", "toggle", false, "accessibility", "client")
	defs.haptics = builtin("haptics", "toggle", true, "gameplay", "client")
	defs.showTips = builtin("showTips", "toggle", true, "gameplay", "saved")
	return defs
end
function Schema.resolve(config: any?): { [string]: any }
	local c = config or Schema.DEFAULTS
	local defs = Schema.builtins(c)
	for id, override in c.builtins or {} do
		assert(defs[id] ~= nil, "Settings: unknown built-in")
		if override == false then
			defs[id] = nil
		else
			assert(type(override) == "table", "Settings: invalid built-in override")
			local merged = table.clone(defs[id])
			for k, value in override do
				merged[k] = value
			end
			assert(merged.id == id, "Settings: built-in id cannot change")
			defs[id] = merged
		end
	end
	local custom = c.schema or {}
	assert(type(custom) == "table", "Settings: schema must be a list")
	local n = 0
	for i, def in custom do
		assert(
			type(i) == "number" and i % 1 == 0 and i >= 1 and i <= #custom,
			"Settings: schema must be a list"
		)
		local valid = Schema.validateDefinition(def)
		assert(valid, "Settings: invalid schema definition")
		assert(defs[def.id] == nil, "Settings: duplicate setting id")
		defs[def.id] = table.clone(def)
		n += 1
	end
	assert(n == #custom, "Settings: sparse schema")
	n = 0
	for _, def in defs do
		local valid = Schema.validateDefinition(def)
		assert(valid, "Settings: invalid definition")
		n += 1
	end
	assert(n <= (c.maxSettings or Schema.DEFAULTS.maxSettings), "Settings: too many definitions")
	return defs
end
function Schema.sanitize(section: any): any
	local clean: { [string]: Value } = {}
	if type(section) == "table" and type(section.values) == "table" then
		for id, value in section.values do
			local kind = type(value)
			if
				Schema.id(id)
				and (
					kind == "boolean"
					or (kind == "number" and finite(value))
					or (kind == "string" and #value <= 64 and string.find(value, "%c") == nil)
				)
			then
				clean[id] = value
			end
		end
	end
	return { values = clean }
end
function Schema.encode(value: any): (string, boolean, number, string)
	if type(value) == "boolean" then
		return "toggle", value, 0, ""
	end
	if type(value) == "number" then
		return "slider", false, value, ""
	end
	if type(value) == "string" then
		return "choice", false, 0, value
	end
	return "invalid", false, 0, ""
end
function Schema.decode(
	def: any,
	kind: any,
	boolValue: any,
	numberValue: any,
	stringValue: any
): (boolean, any)
	if
		type(def) ~= "table"
		or kind ~= def.type
		or type(boolValue) ~= "boolean"
		or not finite(numberValue)
		or type(stringValue) ~= "string"
		or #stringValue > 64
	then
		return false, nil
	end
	local value: any = if kind == "toggle"
		then boolValue
		elseif kind == "slider" then numberValue
		else stringValue
	if not Schema.validate(def, value) then
		return false, nil
	end
	return true, value
end
return Schema
