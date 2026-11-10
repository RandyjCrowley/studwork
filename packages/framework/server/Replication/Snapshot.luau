--!strict
--[[
	Pure helpers for Replication (zero dependencies, tested under Lune).

	Snapshot.copy(value) -> wire-safe deep copy
		Data mutates PlayerData IN PLACE, while charm-sync diffs by reference (`old == new` means
		"unchanged"). So every DataChanged we hand charm-sync a FRESH deep copy; the previous copy
		stays untouched as its "last synced" value and the diff walks both trees.
		The copy is also sanitised for RemoteEvent serialisation:
		  * numbers: NaN / +-inf -> 0
		  * keys: only string keys, or a dense 1..n array; other numeric keys become strings,
		    mixed tables keep only string keys (numeric ones are stringified)
		  * values: only boolean / number / string / table survive (functions, Instances,
		    userdata, Vector3 etc. are dropped - PlayerData never holds them)
		  * depth capped at MAX_DEPTH (cycles cannot blow the stack)

	Snapshot.build(data, extra, shared, opts?) -> ReplicatedState-shaped table (already sanitised).
]]

local MAX_DEPTH = 16

local Snapshot = {}

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

local function isDenseArray(t: { [any]: any }): boolean
	local n = #t
	if n == 0 then
		return false
	end
	local count = 0
	for _ in t do
		count += 1
	end
	return count == n
end

local function copyValue(value: any, depth: number): any
	local kind = type(value)
	if kind == "number" then
		return if isFinite(value) then value else 0
	elseif kind == "string" or kind == "boolean" then
		return value
	elseif kind ~= "table" or depth > MAX_DEPTH then
		return nil
	end
	if isDenseArray(value) then
		local list: { any } = {}
		local complete = true
		for index, item in ipairs(value) do
			local copied = copyValue(item, depth + 1)
			if copied == nil then
				-- a hole would turn the array sparse; fall back to string keys below
				complete = false
				break
			end
			list[index] = copied
		end
		if complete then
			return list
		end
	end
	local out: { [string]: any } = {}
	for key, item in value do
		local keyType = type(key)
		local wireKey: string? = nil
		if keyType == "string" then
			wireKey = key
		elseif keyType == "number" and isFinite(key) then
			wireKey = tostring(key)
		end
		if wireKey ~= nil then
			local copied = copyValue(item, depth + 1)
			if copied ~= nil then
				out[wireKey] = copied
			end
		end
	end
	return out
end

function Snapshot.copy(value: any): any
	return copyValue(value, 1)
end

local function bool(value: any, default: boolean): boolean
	if type(value) == "boolean" then
		return value
	end
	return default
end

local function num(value: any, default: number): number
	if type(value) == "number" and isFinite(value) then
		return value
	end
	return default
end

-- extra: per-player keys from Replication.set; shared: keys from Replication.setAll.
-- Per-player values win over shared ones for the same key.
-- opts (M2, both optional):
--   dataCopy  = an already sanitised data copy (SectionCache.build) used instead of copying `data`
--   sanitized = true when table values in extra/shared were already passed through Snapshot.copy
--               (Replication copies them once in set/setAll), so they are reused by reference
export type BuildOptions = { dataCopy: any?, sanitized: boolean? }

function Snapshot.build(
	data: any,
	extra: { [string]: any }?,
	shared: { [string]: any }?,
	opts: BuildOptions?
): { [string]: any }
	local e: { [string]: any } = extra or {}
	local s: { [string]: any } = shared or {}
	local function pick(key: string): any
		local v = e[key]
		if v == nil then
			v = s[key]
		end
		return v
	end
	local o: BuildOptions = opts or {}
	local function tableOf(value: any): any
		if type(value) ~= "table" then
			return nil
		end
		return if o.sanitized then value else Snapshot.copy(value)
	end
	local dataCopy = nil
	if data ~= nil then
		dataCopy = if o.dataCopy ~= nil then o.dataCopy else Snapshot.copy(data)
	end
	return {
		loaded = data ~= nil,
		data = dataCopy,
		ratePerSec = num(pick("ratePerSec"), 0),
		multiplier = num(pick("multiplier"), 1),
		paidRandomRestricted = bool(pick("paidRandomRestricted"), true),
		activeEvents = tableOf(pick("activeEvents")) or {},
		plotName = if type(pick("plotName")) == "string" then pick("plotName") else nil,
		odds = tableOf(pick("odds")),
		mailbox = tableOf(pick("mailbox")), -- v1.2 (N1)
	}
end

-- Extra keys services may push (Types.ReplicatedState minus loaded/data).
Snapshot.EXTRA_KEYS = {
	ratePerSec = true,
	multiplier = true,
	paidRandomRestricted = true,
	activeEvents = true,
	plotName = true,
	odds = true,
	mailbox = true, -- v1.2 (N1): Mail.pending(player)
}

return Snapshot
