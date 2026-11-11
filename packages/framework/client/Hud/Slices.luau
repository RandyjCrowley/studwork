--!strict
--[[
	Pure readers of the replicated state for the HUD, on the per-module client slices
	(module-api.md §10): state.modules.<Name>.data / .extra.<key>. A v1.2-shaped state (no
	`modules`: a scaffold still on the v1.2 Core facade) is read from its flat fields.
	core-v1.3.1 (R19): the framework names no module here; each kit's client part reads its own
	slice (e.g. the economy module's currency widget).
]]

local Slices = {}

local function slice(state: any, name: string): any
	if type(state) ~= "table" or type(state.modules) ~= "table" then
		return nil
	end
	local m = state.modules[name]
	return if type(m) == "table" then m else {}
end

local function field(t: any, key: string): any
	return if type(t) == "table" then t[key] else nil
end

function Slices.isModular(state: any): boolean
	return type(state) == "table" and type(state.modules) == "table"
end

function Slices.data(state: any, name: string): any
	local m = slice(state, name)
	if m ~= nil then
		return field(m, "data")
	end
	return field(state, "data")
end

function Slices.extra(state: any, name: string, key: string): any
	local m = slice(state, name)
	if m ~= nil then
		return field(field(m, "extra"), key)
	end
	return field(state, key)
end

function Slices.loaded(state: any): boolean
	return type(state) == "table" and state.loaded == true
end

return Slices
