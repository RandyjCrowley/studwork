--!strict
--[[
	Pure Mail message validation. No Roblox globals.
	encode is injected (HttpService:JSONEncode in production) so size is measured on the wire form.
]]

local MailValidate = {}

MailValidate.MAX_KIND_LENGTH = 32
MailValidate.MAX_PAYLOAD_BYTES = 1000 -- JSON bytes; profiles keep up to 1000 queued messages
MailValidate.MAX_DEPTH = 4
MailValidate.MAX_KEY_LENGTH = 64
MailValidate.KEY_PATTERN = "^[%w_%-%.:]+$" -- same as shared Validate.ID_PATTERN

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function checkValue(v: any, depth: number): boolean
	local t = type(v)
	if t == "string" or t == "boolean" then
		return true
	elseif t == "number" then
		return isFinite(v)
	elseif t == "table" then
		if depth >= MailValidate.MAX_DEPTH then
			return false
		end
		for k, child in v do
			if type(k) ~= "string" and not (type(k) == "number" and k % 1 == 0) then
				return false
			end
			if not checkValue(child, depth + 1) then
				return false
			end
		end
		return true
	end
	return false
end

function MailValidate.kind(kind: any): boolean
	return type(kind) == "string"
		and #kind >= 1
		and #kind <= MailValidate.MAX_KIND_LENGTH
		and string.match(kind, "^[%w_%-]+$") ~= nil
end

-- Kinds starting with "core_" belong to core (core_gift); games can't send or receive them.
MailValidate.RESERVED_PREFIX = "core_"

function MailValidate.isReserved(kind: any): boolean
	return type(kind) == "string"
		and string.sub(kind, 1, #MailValidate.RESERVED_PREFIX) == MailValidate.RESERVED_PREFIX
end

function MailValidate.userId(userId: any): boolean
	return isFinite(userId) and userId > 0 and userId % 1 == 0
end

-- Idempotency key: short id string (Validate.isId rules).
function MailValidate.key(key: any): boolean
	return type(key) == "string"
		and #key >= 1
		and #key <= MailValidate.MAX_KEY_LENGTH
		and string.match(key, MailValidate.KEY_PATTERN) ~= nil
end

-- Returns (ok, reason?).
function MailValidate.message(
	userId: any,
	kind: any,
	payload: any,
	encode: (value: any) -> string
): (boolean, string?)
	if not MailValidate.userId(userId) then
		return false, "bad userId"
	end
	if not MailValidate.kind(kind) then
		return false, "bad kind"
	end
	if type(payload) ~= "table" or not checkValue(payload, 1) then
		return false, "bad payload"
	end
	local ok, encoded = pcall(encode, payload)
	if not ok or type(encoded) ~= "string" then
		return false, "payload not JSON-encodable"
	end
	if #encoded > MailValidate.MAX_PAYLOAD_BYTES then
		return false, "payload too large"
	end
	return true, nil
end

return MailValidate
