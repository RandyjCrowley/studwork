--!strict
--[[
	Minimal semver (pure). Versions are "MAJOR.MINOR.PATCH" (an optional "-pre" suffix is ignored
	for comparison). Ranges: "*", "x.y.z" (exact), "^x.y.z", "~x.y.z", ">=x.y.z".
]]

local Semver = {}

function Semver.parse(s: any): { number }?
	if type(s) ~= "string" then
		return nil
	end
	local a, b, c = string.match(s, "^(%d+)%.(%d+)%.(%d+)")
	if a == nil then
		return nil
	end
	local rest = string.sub(s, #(a :: string) + #(b :: string) + #(c :: string) + 3)
	if rest ~= "" and string.match(rest, "^%-[%w%.%-]+$") == nil then
		return nil
	end
	return {
		tonumber(a :: string) :: number,
		tonumber(b :: string) :: number,
		tonumber(c :: string) :: number,
	}
end

function Semver.isVersion(s: any): boolean
	return Semver.parse(s) ~= nil
end

local function compare(a: { number }, b: { number }): number
	for i = 1, 3 do
		if a[i] ~= b[i] then
			return if a[i] < b[i] then -1 else 1
		end
	end
	return 0
end

local function splitRange(range: string): (string, string)
	local op, rest = string.match(range, "^(%^)(.+)$")
	if op then
		return op, rest :: string
	end
	op, rest = string.match(range, "^(~)(.+)$")
	if op then
		return op, rest :: string
	end
	op, rest = string.match(range, "^(>=)(.+)$")
	if op then
		return op, rest :: string
	end
	return "=", range
end

function Semver.isRange(range: any): boolean
	if range == "*" then
		return true
	end
	if type(range) ~= "string" then
		return false
	end
	local _, v = splitRange(range)
	return Semver.parse(v) ~= nil
end

function Semver.satisfies(version: string, range: string): boolean
	if range == "*" then
		return true
	end
	local v = Semver.parse(version)
	local op, rv = splitRange(range)
	local r = Semver.parse(rv)
	if v == nil or r == nil then
		return false
	end
	local cmp = compare(v, r)
	if op == "=" then
		return cmp == 0
	elseif op == ">=" then
		return cmp >= 0
	elseif op == "~" then
		return cmp >= 0 and v[1] == r[1] and v[2] == r[2]
	else -- ^
		if cmp < 0 then
			return false
		end
		if r[1] > 0 then
			return v[1] == r[1]
		end
		return v[1] == 0 and v[2] == r[2]
	end
end

return Semver
