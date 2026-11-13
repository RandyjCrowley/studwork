--!strict
-- Pure promotion validation and private-save cleanup. Never return input text in error reasons.
local Rules = {}

export type Receipt = { token: string, capped: boolean }
export type Save = { redeemed: { [string]: boolean }, pending: { [string]: Receipt }, sequence: number }
export type Result =
	"ok"
	| "invalid"
	| "expired"
	| "not_yet"
	| "already_used"
	| "limit_reached"
	| "not_eligible"
	| "try_later"

Rules.SAFE_INTEGER = 9007199254740991
Rules.DEFAULTS = {
	definitions = {},
	maxLength = 64,
	maxDefinitions = 256,
	maxRewards = 16,
	maxRequirements = 16,
	maxGlobalUses = 10000,
	failureLimit = 5,
	failureWindowSeconds = 300,
	lockoutSeconds = 300,
	rate = { rate = 1, burst = 3 },
	sharedOpsPerMinute = 120,
	live = { enabled = false, key = "player_codes", refreshSeconds = 60, maxEntries = 256 },
	maxNewPlayerSeconds = 86400,
}

function Rules.finite(v: any): boolean
	return type(v) == "number" and v == v and math.abs(v) < math.huge
end
function Rules.integer(v: any, minimum: number, maximum: number): boolean
	return Rules.finite(v) and v % 1 == 0 and v >= minimum and v <= maximum
end
function Rules.id(v: any): boolean
	return type(v) == "string" and #v > 0 and #v <= 24 and string.match(v, "^[%w_]+$") ~= nil
end
function Rules.normalize(raw: any, maxLength: number?): string?
	local maximum = maxLength or Rules.DEFAULTS.maxLength
	if type(raw) ~= "string" or #raw > maximum or string.find(raw, "%c") ~= nil then
		return nil
	end
	local normalized = string.upper((string.gsub(raw, "^%s*(.-)%s*$", "%1")))
	if #normalized == 0 then
		return nil
	end
	return normalized
end
function Rules.hash(raw: string): string
	local h = 2166136261
	for i = 1, #raw do
		h = bit32.bxor(h, string.byte(raw, i))
		h = bit32.band(h * 403 + bit32.lshift(h, 24), 0xffffffff)
	end
	return string.format("%08x", h)
end

local function text(v: any, maximum: number): boolean
	return type(v) == "string" and #v > 0 and #v <= maximum and string.find(v, "%c") == nil
end
local function list(v: any, maximum: number): boolean
	if type(v) ~= "table" or getmetatable(v) ~= nil or #v > maximum then
		return false
	end
	local count = 0
	for k in v do
		if not Rules.integer(k, 1, maximum) then
			return false
		end
		count += 1
	end
	return count == #v
end
local function fields(v: any, allowed: { [string]: boolean }): boolean
	for k in v do
		if not allowed[k] then
			return false
		end
	end
	return true
end
local function json(v: any, depth: number, seen: { [any]: boolean }): boolean
	if depth > 8 then
		return false
	end
	local kind = type(v)
	if kind == "boolean" then
		return true
	end
	if kind == "number" then
		return Rules.finite(v)
	end
	if kind == "string" then
		return #v <= 1024 and string.find(v, "%c") == nil
	end
	if kind ~= "table" or getmetatable(v) ~= nil or seen[v] then
		return false
	end
	seen[v] = true
	local n = 0
	for k, child in v do
		n += 1
		if n > 64 or not (text(k, 64) or Rules.integer(k, 1, 64)) or not json(child, depth + 1, seen) then
			seen[v] = nil
			return false
		end
	end
	seen[v] = nil
	return true
end
local function reward(v: any): boolean
	if type(v) ~= "table" or not text(v.kind, 32) or not json(v, 0, {}) then
		return false
	end
	if v.kind == "currency" then
		return fields(v, { kind = true, amount = true, currency = true })
			and Rules.finite(v.amount)
			and v.amount > 0
			and (v.currency == nil or text(v.currency, 64))
	elseif v.kind == "item" then
		return fields(v, { kind = true, itemId = true, count = true })
			and text(v.itemId, 64)
			and (v.count == nil or Rules.integer(v.count, 1, 10000))
	elseif v.kind == "roll" then
		return fields(v, { kind = true, tableId = true }) and text(v.tableId, 64)
	end
	return true
end
local function requirement(v: any, config: any): boolean
	if type(v) ~= "table" or not text(v.kind, 32) or not json(v, 0, {}) then
		return false
	end
	if v.kind == "rebirth" then
		return fields(v, { kind = true, count = true }) and Rules.integer(v.count, 0, Rules.SAFE_INTEGER)
	elseif v.kind == "item" then
		return fields(v, { kind = true, itemId = true }) and text(v.itemId, 64)
	elseif v.kind == "group" then
		return fields(v, { kind = true, groupId = true }) and Rules.integer(v.groupId, 1, Rules.SAFE_INTEGER)
	elseif v.kind == "newPlayer" then
		return fields(v, { kind = true, maxAgeSeconds = true })
			and Rules.finite(v.maxAgeSeconds)
			and v.maxAgeSeconds >= 0
			and v.maxAgeSeconds <= config.maxNewPlayerSeconds
	end
	return true
end
function Rules.validateDefinition(def: any, config: any?): (boolean, string?)
	local c = config or Rules.DEFAULTS
	if type(def) ~= "table" or getmetatable(def) ~= nil then
		return false, "definition"
	end
	if
		not fields(def, {
			id = true,
			code = true,
			rewards = true,
			startsAt = true,
			expiresAt = true,
			maxUses = true,
			oncePerPlayer = true,
			requires = true,
			testOnly = true,
		})
	then
		return false, "field"
	end
	if not Rules.id(def.id) or Rules.normalize(def.code, c.maxLength) == nil then
		return false, "identity"
	end
	if def.oncePerPlayer ~= nil and def.oncePerPlayer ~= true then
		return false, "once_only"
	end
	if def.testOnly ~= nil and type(def.testOnly) ~= "boolean" then
		return false, "test_only"
	end
	if def.maxUses ~= nil and not Rules.integer(def.maxUses, 1, c.maxGlobalUses) then
		return false, "limit"
	end
	if
		(def.startsAt ~= nil and not Rules.finite(def.startsAt))
		or (def.expiresAt ~= nil and not Rules.finite(def.expiresAt))
	then
		return false, "time"
	end
	if def.startsAt ~= nil and def.expiresAt ~= nil and def.expiresAt <= def.startsAt then
		return false, "time"
	end
	if not list(def.rewards, c.maxRewards) or #def.rewards == 0 then
		return false, "rewards"
	end
	for _, r in def.rewards do
		if not reward(r) then
			return false, "reward"
		end
	end
	if def.requires ~= nil then
		if not list(def.requires, c.maxRequirements) then
			return false, "requirements"
		end
		for _, r in def.requires do
			if not requirement(r, c) then
				return false, "requirement"
			end
		end
	end
	return true, nil
end
function Rules.validateCatalog(definitions: any, config: any?): (boolean, string?)
	local c = config or Rules.DEFAULTS
	if not list(definitions, c.maxDefinitions) then
		return false, "catalog"
	end
	local ids: { [string]: boolean } = {}
	local codes: { [string]: boolean } = {}
	for _, def in definitions do
		local ok, reason = Rules.validateDefinition(def, c)
		if not ok then
			return false, reason
		end
		local normalized = Rules.normalize(def.code, c.maxLength) :: string
		if ids[def.id] or codes[normalized] then
			return false, "duplicate"
		end
		ids[def.id], codes[normalized] = true, true
	end
	return true, nil
end
function Rules.sanitize(section: any): Save
	local raw = if type(section) == "table" then section else {}
	local clean: Save = { redeemed = {}, pending = {}, sequence = 0 }
	if Rules.integer(raw.sequence, 0, Rules.SAFE_INTEGER) then
		clean.sequence = raw.sequence
	end
	if type(raw.redeemed) == "table" then
		for id, used in raw.redeemed do
			if Rules.id(id) and used == true then
				clean.redeemed[id] = true
			end
		end
	end
	if type(raw.pending) == "table" then
		for id, receipt in raw.pending do
			if
				Rules.id(id)
				and type(receipt) == "table"
				and text(receipt.token, 96)
				and type(receipt.capped) == "boolean"
			then
				clean.pending[id] = { token = receipt.token, capped = receipt.capped }
				clean.redeemed[id] = true -- recovery markers survive catalog removal and malformed old sets
			end
		end
	end
	return clean
end
return Rules
