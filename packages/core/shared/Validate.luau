--!strict
--[[
	Pure validation helpers for untrusted values (remote arguments, config). Shared by server
	services; zero Roblox dependencies. NaN/inf never pass a numeric check.
]]

local Validate = {}

function Validate.isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Validate.isPositiveNumber(value: any): boolean
	return Validate.isFiniteNumber(value) and value > 0
end

function Validate.isNonNegativeNumber(value: any): boolean
	return Validate.isFiniteNumber(value) and value >= 0
end

function Validate.isInteger(value: any): boolean
	return Validate.isFiniteNumber(value) and math.floor(value) == value
end

function Validate.inRange(value: any, min: number, max: number): boolean
	return Validate.isFiniteNumber(value) and value >= min and value <= max
end

-- Non-empty string no longer than maxLen, optionally matching a Lua pattern.
function Validate.isShortString(value: any, maxLen: number, pattern: string?): boolean
	if type(value) ~= "string" then
		return false
	end
	local len = #value
	if len == 0 or len > maxLen then
		return false
	end
	if pattern and string.match(value, pattern) == nil then
		return false
	end
	return true
end

-- Identifier-like strings used for ids coming from clients (item ids, upgrade ids, slot ids, uids).
Validate.ID_PATTERN = "^[%w_%-%.:]+$"

function Validate.isId(value: any, maxLen: number?): boolean
	return Validate.isShortString(value, maxLen or 64, Validate.ID_PATTERN)
end

return Validate
