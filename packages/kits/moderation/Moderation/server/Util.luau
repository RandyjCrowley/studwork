--!strict
--[[
	Moderation helpers (pure; no engine, no ctx). Exposed to specs as Server.Util.

	  Util.cutChars(s, maxChars) -> string    at most maxChars UTF-8 characters, never a split character
	  Util.cutBytes(s, maxBytes) -> string    at most maxBytes bytes, never a split character
	  Util.isTransient(err) -> boolean        a BanAsync / UnbanAsync error worth retrying (design B8):
	                                          "failure for UserId", or a timeout / HTTP word
	  Util.isCount(v) -> boolean              an integer >= 1 (a duration in seconds, a user id)
	  Util.json(t, maxBytes) -> string        a flat { [string]: string | number | boolean } as JSON,
	                                          keys sorted, fields that don't fit dropped (never cut)
	  Util.day(ts) -> number                  the UTC day index of unix seconds ts
]]

local Util = {}

function Util.cutBytes(s: string, maxBytes: number): string
	if #s <= maxBytes then
		return s
	end
	local cut = string.sub(s, 1, math.max(0, maxBytes))
	-- a UTF-8 character is at most 4 bytes: drop a trailing partial one
	for _ = 1, 4 do
		if utf8.len(cut) ~= nil then
			return cut
		end
		cut = string.sub(cut, 1, #cut - 1)
	end
	return if utf8.len(cut) ~= nil then cut else ""
end

function Util.cutChars(s: string, maxChars: number): string
	local len = utf8.len(s)
	if len == nil then
		return Util.cutBytes(s, maxChars)
	end
	if len <= maxChars then
		return s
	end
	local stop = utf8.offset(s, maxChars + 1)
	return string.sub(s, 1, (stop or (#s + 1)) - 1)
end

local TRANSIENT = { "failure for userid", "timeout", "timed out", "timedout", "http" }

function Util.isTransient(err: any): boolean
	local msg = string.lower(tostring(err))
	for _, word in TRANSIENT do
		if string.find(msg, word, 1, true) ~= nil then
			return true
		end
	end
	return false
end

function Util.isCount(v: any): boolean
	return type(v) == "number" and v == v and v >= 1 and v < 2 ^ 53 and v % 1 == 0
end

local function quote(s: string): string
	local out = string.gsub(s, '[%c"\\]', function(c: string): string
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. out .. '"'
end

local function scalar(v: any): string?
	if type(v) == "string" then
		return quote(v)
	elseif type(v) == "boolean" then
		return if v then "true" else "false"
	elseif type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
		if v % 1 == 0 and math.abs(v) < 2 ^ 53 then
			return string.format("%d", v)
		end
		return string.format("%.6g", v)
	end
	return nil
end

function Util.json(t: any, maxBytes: number): string
	if type(t) ~= "table" then
		return "{}"
	end
	local keys: { string } = {}
	for k in t do
		if type(k) == "string" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	local parts: { string } = {}
	local size = 2
	for _, k in keys do
		local value = scalar(t[k])
		if value ~= nil then
			local field = quote(k) .. ":" .. value
			local extra = #field + (if #parts > 0 then 1 else 0)
			if size + extra <= maxBytes then
				table.insert(parts, field)
				size += extra
			end
		end
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

function Util.day(ts: number): number
	return ts // 86400
end

return Util
