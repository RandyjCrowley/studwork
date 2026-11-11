--!strict
--[[
	Pure helpers shared by the collection kit's server parts (zero Roblox dependencies; tested
	under Lune). Replaces the v1.2 Core.Validate imports (kit code may not import framework internals).

	isFiniteNumber / isPositiveNumber / isNonNegativeNumber / isInteger
	isShortString(value, maxLen, pattern?)   non-empty string <= maxLen matching pattern
	isId(value, maxLen?)                     ID_PATTERN, default max 64
	frozenCopy(value)                        deep copy, every table frozen
	newUid()                                 a fresh item instance uid: HttpService GUID on Roblox,
	                                         a random 128-bit hex GUID elsewhere (Lune tests)
]]

local Util = {}

function Util.isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Util.isPositiveNumber(value: any): boolean
	return Util.isFiniteNumber(value) and value > 0
end

function Util.isNonNegativeNumber(value: any): boolean
	return Util.isFiniteNumber(value) and value >= 0
end

function Util.isInteger(value: any): boolean
	return Util.isFiniteNumber(value) and math.floor(value) == value
end

function Util.isShortString(value: any, maxLen: number, pattern: string?): boolean
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

Util.ID_PATTERN = "^[%w_%-%.:]+$"

function Util.isId(value: any, maxLen: number?): boolean
	return Util.isShortString(value, maxLen or 64, Util.ID_PATTERN)
end

function Util.frozenCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	if table.isfrozen(value) then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = Util.frozenCopy(v)
	end
	return table.freeze(out)
end

local http: any = false
local function httpService(): any
	if http == false then
		local ok, service = pcall(function(): any
			return (game :: any):GetService("HttpService")
		end)
		http = if ok then service else nil
	end
	return http
end

local function hex(n: number): string
	local out = {}
	for i = 1, n do
		out[i] = string.format("%x", math.random(0, 15))
	end
	return table.concat(out)
end

function Util.newUid(): string
	local service = httpService()
	if service ~= nil then
		return service:GenerateGUID(false)
	end
	return string.upper(`{hex(8)}-{hex(4)}-4{hex(3)}-{hex(4)}-{hex(12)}`)
end

return table.freeze(Util)
