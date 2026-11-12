--!strict
--[[
	Feature flags (module-api.md §23.2, docs/framework/kits/environments.md). Pure, both sides.

	  Flags.validate(flags, serverFlags, envName) -> { string }     every boot error, together
	  Flags.resolve(def, envName) -> boolean                        environment field > default
	  Flags.new(opts) -> state                                      one side's flag table
	    opts = { flags, serverFlags?, envName, side = "server" | "client", log? }
	    state.api            the FlagsAPI (isOn, onChanged, all, source), frozen
	    state.setOverride(name, value | nil) -> (applied, reason?)  server: the live override
	    state.replicated() -> { [name]: boolean }                   every flag without serverOnly
	    state.applyReplicated(values)                               client: take the server's values
	    state.names() -> { string }                                 declared names, sorted
	    state.overridable(name) -> boolean                          declared and override ~= false
	    state.onAnyChange(fn(name, on))                             framework internal: re-replicate

	Value = override (if the flag allows it) > the environment's field > default. A testOnly flag
	can never be on in live: config that would make it so is a boot error (validate), and an
	override can't switch it on there (setOverride refuses).
]]

local Signal = require(script.Parent.Signal)
local Types = require(script.Parent.Types)

local Flags = {}

Flags.NAME_PATTERN = "^[%a][%w_]{0,47}$"
Flags.FIELDS = table.freeze({
	default = "boolean",
	studio = "boolean",
	test = "boolean",
	live = "boolean",
	testOnly = "boolean",
	serverOnly = "boolean",
	override = "boolean",
	description = "string",
})
Flags.OVERRIDE_DEFAULTS = table.freeze({ enabled = false, keyPrefix = "flag_", refreshSeconds = 30 })

local function checkTable(flags: any, label: string, errors: { string })
	if flags == nil then
		return
	end
	if type(flags) ~= "table" then
		table.insert(errors, `{label} must be a table of name = {"{"} default = boolean, ... {"}"}`)
		return
	end
	for name, def in flags do
		local where = `{label}.{tostring(name)}`
		if type(name) ~= "string" or string.match(name, "^[%a][%w_]*$") == nil or #name > 48 then
			table.insert(errors, `{where}: flag names match ^[%a][%w_]{"{"}0,47{"}"}$`)
			continue
		end
		if type(def) ~= "table" then
			table.insert(errors, `{where} must be a table`)
			continue
		end
		for field, value in def do
			local want = Flags.FIELDS[field]
			if want == nil then
				table.insert(errors, `{where}.{tostring(field)}: unknown field`)
			elseif type(value) ~= want then
				table.insert(errors, `{where}.{field} must be a {want}`)
			end
		end
		if type(def.default) ~= "boolean" then
			table.insert(errors, `{where}.default is required and must be a boolean`)
		end
	end
end

-- Every flag error, together (reported with the other config errors at boot).
function Flags.validate(flags: any, serverFlags: any, _envName: string?): { string }
	local errors: { string } = {}
	checkTable(flags, "flags", errors)
	checkTable(serverFlags, "ServerConfig.flags", errors)
	if type(flags) == "table" and type(serverFlags) == "table" then
		for name in serverFlags do
			if flags[name] ~= nil then
				table.insert(
					errors,
					`flags.{tostring(name)} is declared in both GameConfig.flags and ServerConfig.flags`
				)
			end
		end
	end
	for _, group in { { "flags", flags }, { "ServerConfig.flags", serverFlags } } do
		local label, defs = group[1] :: string, group[2]
		if type(defs) == "table" then
			for name, def in defs do
				if type(def) == "table" and def.testOnly == true and type(def.default) == "boolean" then
					local liveValue = if def.live ~= nil then def.live else def.default
					if liveValue == true then
						table.insert(
							errors,
							`{label}.{tostring(name)} is testOnly but would be on in live (set live = false or default = false)`
						)
					end
				end
			end
		end
	end
	return errors
end

-- The configured value in one environment (no override).
function Flags.resolve(def: Types.FlagDef, envName: string): boolean
	local v = (def :: any)[envName]
	if type(v) == "boolean" then
		return v
	end
	return def.default
end

export type Options = {
	flags: any,
	serverFlags: any?,
	envName: Types.EnvName,
	side: "server" | "client",
	log: ((string) -> ())?,
}

function Flags.new(opts: Options): any
	local side = opts.side
	local envName: string = opts.envName
	local log = opts.log or function(_m: string) end
	local defs: { [string]: any } =
		table.clone((if type(opts.flags) == "table" then opts.flags else {}) :: any)
	local hidden: { [string]: boolean } = {}
	if side == "server" then
		for name, def in (if type(opts.serverFlags) == "table" then opts.serverFlags else {}) :: any do
			defs[name] = def
			hidden[name] = true
		end
	end
	local values: { [string]: boolean } = {}
	local overrides: { [string]: boolean } = {}
	local sources: { [string]: string } = {}
	local signals: { [string]: any } = {}
	local anyListeners: { (name: string, on: boolean) -> () } = {}
	for name, def in defs do
		values[name] = Flags.resolve(def, envName)
		sources[name] = "config"
	end

	local function serverOnly(name: string): boolean
		local def = defs[name]
		return def ~= nil and (def.serverOnly == true or hidden[name] == true)
	end

	local function check(what: string, name: any): any
		local def = if type(name) == "string" then defs[name] else nil
		if def == nil then
			error(
				`[StudWork] flags.{what}: unknown flag '{tostring(name)}' (declare it in GameConfig.flags)`,
				3
			)
		end
		if side == "client" and serverOnly(name) then
			error(
				`[StudWork] flags.{what}: '{name}' is serverOnly; its value is not available on the client`,
				3
			)
		end
		return def
	end

	local function set(name: string, on: boolean, source: string)
		local changed = values[name] ~= on
		values[name] = on
		sources[name] = source
		if changed then
			if signals[name] ~= nil then
				signals[name]:Fire(on)
			end
			for _, fn in anyListeners do
				fn(name, on)
			end
		end
	end

	local state: any = {}

	local function recompute(name: string)
		local def = defs[name]
		local o = overrides[name]
		if o ~= nil and def.override ~= false then
			set(name, o, "override")
		else
			set(name, Flags.resolve(def, envName), "config")
		end
	end

	-- Server: the live override. nil clears it. -> (applied, reason?)
	function state.setOverride(name: string, value: boolean?): (boolean, string?)
		local def = defs[name]
		if def == nil then
			return false, "unknown"
		end
		if value ~= nil and def.override == false then
			return false, "not_overridable"
		end
		if value == true and def.testOnly == true and envName == "live" then
			log(`[StudWork] flag '{name}' is testOnly: an override can't switch it on in live`)
			return false, "test_only"
		end
		overrides[name] = value :: any
		recompute(name)
		return true, nil
	end

	function state.replicated(): { [string]: boolean }
		local out: { [string]: boolean } = {}
		for name in defs do
			if not serverOnly(name) then
				out[name] = values[name]
			end
		end
		return out
	end

	-- Client: the server's values replace the locally resolved ones (never for a flag it can't see).
	function state.applyReplicated(replicated: any)
		if type(replicated) ~= "table" then
			return
		end
		for name, on in replicated do
			if defs[name] ~= nil and type(on) == "boolean" and not serverOnly(name) then
				local source = if on == Flags.resolve(defs[name], envName) then "config" else "override"
				set(name, on, source)
			end
		end
	end

	-- Framework internal: called after any flag's value changed (the server re-replicates).
	function state.onAnyChange(fn: (name: string, on: boolean) -> ())
		table.insert(anyListeners, fn)
	end

	function state.names(): { string }
		local out = {}
		for name in defs do
			table.insert(out, name)
		end
		table.sort(out)
		return out
	end

	function state.overridable(name: string): boolean
		local def = defs[name]
		return def ~= nil and def.override ~= false
	end

	function state.isHidden(name: string): boolean
		return hidden[name] == true
	end

	state.api = table.freeze({
		isOn = function(name: string): boolean
			check("isOn", name)
			return values[name]
		end,
		onChanged = function(name: string, fn: (on: boolean) -> ()): Types.Connection
			check("onChanged", name)
			if signals[name] == nil then
				signals[name] = Signal.new(`flags.{name}`)
			end
			return signals[name]:Connect(fn)
		end,
		all = function(): { [string]: boolean }
			local out: { [string]: boolean } = {}
			for name, on in values do
				if side == "server" or not serverOnly(name) then
					out[name] = on
				end
			end
			return table.freeze(out)
		end,
		source = function(name: string): "config" | "override"
			check("source", name)
			return sources[name] :: any
		end,
	}) :: Types.FlagsAPI

	return state
end

return table.freeze(Flags)
