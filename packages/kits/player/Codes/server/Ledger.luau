--!strict
-- Retry-safe durable counter transforms. Pending slots never expire.
local Ledger = {}
local MAX = 10000
local function integer(v: any, maximum: number): boolean
	return type(v) == "number" and v == v and v >= 0 and v <= maximum and v % 1 == 0
end
function Ledger.valid(raw: any): boolean
	if
		type(raw) ~= "table"
		or raw.version ~= 1
		or not integer(raw.limit, MAX)
		or not integer(raw.used, MAX)
		or type(raw.reserved) ~= "table"
	then
		return false
	end
	local n = 0
	for token, value in raw.reserved do
		if type(token) ~= "string" or #token == 0 or #token > 96 or value ~= true then
			return false
		end
		n += 1
		if n > MAX then
			return false
		end
	end
	return if raw.limit == 0 then raw.used == 0 and n == 0 else raw.used + n <= raw.limit
end
function Ledger.count(raw: any): number
	local n = raw.used
	for _ in raw.reserved do
		n += 1
	end
	return n
end
function Ledger.reserve(old: any, limit: number, token: string): any
	local raw = old
	if raw == nil then
		raw = { version = 1, limit = limit, used = 0, reserved = {} }
	end
	assert(Ledger.valid(raw), "invalid promotion ledger")
	if
		raw.limit ~= limit
		or limit == 0
		or token == ""
		or raw.reserved[token]
		or Ledger.count(raw) >= limit
	then
		return raw
	end
	local reserved = table.clone(raw.reserved)
	reserved[token] = true
	return { version = 1, limit = raw.limit, used = raw.used, reserved = reserved }
end
function Ledger.finish(old: any, token: string, granted: boolean): any
	assert(Ledger.valid(old), "invalid promotion ledger")
	assert(old.limit > 0, "invalid capped promotion ledger")
	if old.reserved[token] ~= true then
		return old
	end
	local reserved = table.clone(old.reserved)
	reserved[token] = nil
	return {
		version = 1,
		limit = old.limit,
		used = old.used + (if granted then 1 else 0),
		reserved = reserved,
	}
end
return Ledger
