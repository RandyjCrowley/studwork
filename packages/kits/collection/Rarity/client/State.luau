--!strict
--[[
	Rarity client state readers (pure; v1.3.1 R19: moved from the framework HUD's Slices, which
	now names no module). Read this module's per-module client slice of the replicated state
	(module-api.md §10: state.modules.Rarity.data / .extra), or a v1.2 flat state's fields.
	State.odds(state) -> { [tableId]: odds }   extra.odds ({} when absent)
	State.itemOdds(state, tableId?, itemKey?)   (v1.6.0) the per-item odds the server disclosed
	    (framework field itemOdds = { [tableId]: { [itemKey]: OddsDetail } }): the whole map ({}
	    when absent), one table's map, or one item's OddsDetail (nil) for UI.OddsTable's `detail`
]]

local State = {}

local NAME = "Rarity"

-- state.modules.Rarity (a v1.3 state) or the state itself (a v1.2 flat state); nil fields read as nil
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

function State.odds(state: any): { [string]: any }
	local odds = extra(state, "odds")
	return if type(odds) == "table" then odds else {}
end

function State.itemOdds(state: any, tableId: string?, itemKey: string?): any
	local fw = field(state, "framework")
	local all = field(fw, "itemOdds")
	if type(all) ~= "table" then
		all = {}
	end
	if tableId == nil then
		return all
	end
	local mine = all[tableId]
	if itemKey == nil then
		return if type(mine) == "table" then mine else {}
	end
	return field(mine, itemKey)
end

return State
