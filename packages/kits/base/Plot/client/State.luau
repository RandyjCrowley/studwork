--!strict
--[[
	Plot client state readers (pure; core-v1.3.1 R19: moved from the framework HUD's Slices, which
	now names no module). Read this module's per-module client slice of the replicated state
	(module-api.md §10: state.modules.Plot.data / .extra), or a v1.2 flat state's fields.
	State.plotName(state) -> string?   extra.plotName
]]

local State = {}

local NAME = "Plot"

-- state.modules.Plot (a v1.3 state) or the state itself (a v1.2 flat state); nil fields read as nil
local function slice(state: any): any
	if type(state) ~= "table" then
		return nil
	end
	if type(state.modules) ~= "table" then
		return state
	end
	local m = state.modules[NAME]
	return if type(m) == "table" then m else {}
end

local function field(t: any, key: string): any
	return if type(t) == "table" then t[key] else nil
end

local function isModular(state: any): boolean
	return type(state) == "table" and type(state.modules) == "table"
end

-- extra.<key> of this module's slice (v1.2 flat: state.<key>)
local function extra(state: any, key: string): any
	local s = slice(state)
	if isModular(state) then
		return field(field(s, "extra"), key)
	end
	return field(s, key)
end

function State.plotName(state: any): string?
	local name = extra(state, "plotName")
	return if type(name) == "string" then name else nil
end

return State
