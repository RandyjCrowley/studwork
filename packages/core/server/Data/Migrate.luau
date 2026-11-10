--!strict
--[[
	Pure versioned-migration runner. OWNED BY AGENT A (core/a-data). No Roblox globals.

	Migration list shape: { [toVersion]: fn(old) -> new }. A migration for version N turns data at
	version N-1 into data at version N. It may mutate and return its input or return a new table.

	Migrate.run(data, fromVersion, toVersion, migrations) -> (data, status, appliedVersions)
	  status:
	    "ok"     every migration fromVersion+1 .. toVersion ran in order (missing entries are
	             skipped: a version bump that only adds keys needs no function, reconcile fills them)
	    "newer"  fromVersion > toVersion: the data was written by NEWER code. It is returned
	             UNTOUCHED (never downgraded); the caller must not save over it.
	    "error"  a migration errored or returned a non-table; data is the last good table and
	             appliedVersions lists what ran. The caller must not save it either.
]]

local Migrate = {}

export type MigrationFn = (old: { [string]: any }) -> { [string]: any }
export type Status = "ok" | "newer" | "error"

-- Reserved key inside PlayerData.game[gameId] that stores that table's own version.
Migrate.GAME_VERSION_KEY = "_version"

local function isInteger(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n % 1 == 0
end

function Migrate.run(
	data: { [string]: any },
	fromVersion: number,
	toVersion: number,
	migrations: { [number]: MigrationFn }?
): ({ [string]: any }, Status, { number }, string?)
	local applied: { number } = {}
	if not isInteger(fromVersion) or not isInteger(toVersion) then
		return data, "error", applied, "versions must be integers"
	end
	if fromVersion > toVersion then
		return data, "newer", applied, nil
	end
	local current = data
	for version = fromVersion + 1, toVersion do
		local fn = if migrations then migrations[version] else nil
		if fn ~= nil then
			local ok, result = pcall(fn, current)
			if not ok then
				return current, "error", applied, `migration {version} failed: {tostring(result)}`
			end
			if type(result) ~= "table" then
				return current, "error", applied, `migration {version} returned {type(result)}`
			end
			current = result
			table.insert(applied, version)
		end
	end
	return current, "ok", applied, nil
end

-- Reads a stored version number; anything invalid (nil, NaN, fractional, < 0) counts as `fallback`.
function Migrate.readVersion(value: any, fallback: number): number
	if isInteger(value) and value >= 0 then
		return value
	end
	return fallback
end

return Migrate
