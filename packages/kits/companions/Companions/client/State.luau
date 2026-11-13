--!strict
local Types = require(script.Parent.Parent.shared.Types)
local State = {}
local function field(state: any, section: string, key: string): any
	if type(state) ~= "table" or type(state.modules) ~= "table" then
		return nil
	end
	local slice = state.modules.Companions
	if type(slice) ~= "table" or type(slice[section]) ~= "table" then
		return nil
	end
	return slice[section][key]
end
function State.equipped(state: any): { string }
	local value = field(state, "data", "equipped")
	return if type(value) == "table" then value else {}
end
function State.manual(state: any): boolean
	return field(state, "data", "manual") == true
end
function State.bonus(state: any): number
	local value = field(state, "extra", "bonus")
	return if type(value) == "number" and value == value and value >= 1 and value <= 100 then value else 1
end
function State.enabled(state: any): boolean
	return field(state, "extra", "enabled") == true
end
function State.roster(state: any): Types.Roster
	local value = field(state, "extra", "roster")
	return if type(value) == "table" then value else {}
end
return State
