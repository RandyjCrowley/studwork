--!strict
--[[
	Pure versioned-migration runner, per save section (module-api.md §6). Same contract as v1.2's
	server/Data/Migrate.luau, plus `fromFolder` for a module's `migrations/` folder.

	Migration list shape: { [toVersion]: fn(old) -> new }. Migration N turns version N-1 into N.
	Migrate.run(data, from, to, migrations) -> (data, status, applied, err)
	  "ok"    every migration from+1..to ran in order (missing numbers are skipped)
	  "newer" from > to: written by newer code; returned untouched, never saved over
	  "error" a migration errored or returned a non-table; the caller must not save
]]

local Migrate = {}

export type MigrationFn = (old: any) -> any
export type Status = "ok" | "newer" | "error"

local function isInteger(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n % 1 == 0
end

function Migrate.run(
	data: any,
	fromVersion: number,
	toVersion: number,
	migrations: { [number]: MigrationFn }?
): (any, Status, { number }, string?)
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

function Migrate.readVersion(value: any, fallback: number): number
	if isInteger(value) and value >= 0 then
		return value
	end
	return fallback
end

-- Turns a module's `data.migrations` into { [toVersion]: fn }. Accepts a plain table (already in
-- that shape) or a folder Instance of ModuleScripts named "NNN_description" (NNN = toVersion),
-- each returning fn(old) -> new. `req` is the require to use (injected for tests).
function Migrate.fromFolder(source: any, req: ((any) -> any)?): ({ [number]: MigrationFn }, { string })
	local errors: { string } = {}
	local out: { [number]: MigrationFn } = {}
	if source == nil then
		return out, errors
	end
	if type(source) == "table" and getmetatable(source) == nil then
		for k, fn in source do
			if not isInteger(k) or k < 1 then
				table.insert(errors, `migrations key {tostring(k)} must be an integer toVersion >= 1`)
			elseif type(fn) ~= "function" then
				table.insert(errors, `migrations[{k}] must be a function(old) -> new`)
			else
				out[k] = fn
			end
		end
		return out, errors
	end
	local okList, children = pcall(function()
		return source:GetChildren()
	end)
	if not okList then
		table.insert(errors, "migrations must be a table { [toVersion] = fn } or a folder of NNN_*.luau")
		return out, errors
	end
	local doRequire = req or require
	for _, child in children do
		local name = tostring(child.Name)
		local num = string.match(name, "^(%d+)_")
		if num == nil then
			table.insert(errors, `migrations/{name}: file name must start with NNN_ (the toVersion)`)
			continue
		end
		local version = tonumber(num) :: number
		if out[version] ~= nil then
			table.insert(errors, `migrations/{name}: two migrations for version {version}`)
			continue
		end
		local ok, fn = pcall(doRequire, child)
		if not ok then
			table.insert(errors, `migrations/{name}: require failed: {tostring(fn)}`)
		elseif type(fn) ~= "function" then
			table.insert(errors, `migrations/{name}: must return a function(old) -> new`)
		else
			out[version] = fn
		end
	end
	return out, errors
end

return Migrate
