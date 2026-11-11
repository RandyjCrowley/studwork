--!strict
--[[
	Inventory client state readers (pure; core-v1.3.1 R19: moved from the framework HUD's Slices, which
	now names no module). Read this module's per-module client slice of the replicated state
	(module-api.md §10: state.modules.Inventory.data / .extra), or a v1.2 flat state's fields.
	State.inventory(state) -> { item }   data.inventory ({} when absent)
]]

local State = {}

local NAME = "Inventory"

-- state.modules.Inventory (a v1.3 state) or the state itself (a v1.2 flat state); nil fields read as nil
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

-- data.<key> of this module's slice (v1.2 flat: state.data.<key>)
local function data(state: any, key: string): any
	return field(field(slice(state), "data"), key)
end

function State.inventory(state: any): { any }
	local inv = data(state, "inventory")
	return if type(inv) == "table" then inv else {}
end

return State
