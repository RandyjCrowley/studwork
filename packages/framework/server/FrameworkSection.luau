--!strict
--[[
	The `_framework` save section and its migrations (module-api.md §6, §17 Q7).

	Profile.Data = {
		_framework = { schemaVersion, firstJoin, lastSeen, purchases, funnel, stats, _owners },
		_versions  = { [dataKey]: sectionVersion },
		<dataKey>  = <module section>, ...
	}

	Framework migrations run on the WHOLE profile root (they're the only ones allowed to move data
	between sections). Version 1 is "a v1.2 flat PlayerData"; migration 2 splits it into sections,
	one per FINER kit module (decisions.md, "Data, sections, migrations and transactions"; v1.3.0
	to the keys the kit wrappers declare):
	  firstJoin, lastSeen, purchases, funnel, stats  -> _framework
	  currency, multipliers                          -> economy    (Economy)
	  upgrades                                       -> upgrades   (Upgrades)
	  rebirths                                       -> rebirth    (Rebirth)
	  inventory                                      -> inventory  (Inventory)
	  pity                                           -> rarity     (Rarity)
	  displayed                                      -> plot       (Plot)
	  mail                                           -> mail       (Mail)
	  streak                                         -> streak     (Streak)
	  game[gameId]                                   -> [gameId]   (the game's implicit module)
	Each field keeps its v1.2 name inside its section (economy = { currency, multipliers }, ...).
	Split sections are stored at section version 0 with no recorded owner, so the owning module's
	migration 001 receives the v1.2 shape and the first module to claim the key becomes its owner.
	This split is the v1.2 -> v1.3 save MIGRATION (live v1.2 saves keep loading through it; the
	full round trip is packages/framework/test/MigrationV12.spec.luau).
]]

local Shared = require(script.Parent.Shared)
local requireShared = require :: any -- see Shared.luau
local Freeze = requireShared(Shared.Freeze)

local FrameworkSection = {}

FrameworkSection.VERSION = 2

FrameworkSection.V12_MAP = table.freeze({
	firstJoin = "_framework",
	lastSeen = "_framework",
	purchases = "_framework",
	funnel = "_framework",
	stats = "_framework",
	currency = "economy",
	multipliers = "economy",
	upgrades = "upgrades",
	rebirths = "rebirth",
	inventory = "inventory",
	pity = "rarity",
	displayed = "plot",
	mail = "mail",
	streak = "streak",
})

function FrameworkSection.default(now: number): { [string]: any }
	return {
		schemaVersion = FrameworkSection.VERSION,
		firstJoin = now,
		lastSeen = now,
		purchases = {},
		funnel = {},
		stats = {},
		_owners = {},
	}
end

-- Is `root` a v1.2 flat PlayerData (no sections yet)?
function FrameworkSection.isV12(root: any): boolean
	return type(root) == "table" and root._framework == nil and type(root.schemaVersion) == "number"
end

-- v1.2 flat save -> sectioned save. Unknown v1.2 keys are kept under _framework.legacy so nothing
-- is ever dropped silently.
function FrameworkSection.splitV12(old: { [string]: any }, gameId: string?): { [string]: any }
	local out: { [string]: any } = {
		_framework = { schemaVersion = FrameworkSection.VERSION, _owners = {} },
		_versions = {},
	}
	local legacy: { [string]: any } = {}
	for key, value in old do
		if key == "schemaVersion" then
			continue
		elseif key == "game" then
			for gid, section in value do
				if gid == gameId then
					out[gid] = Freeze.deepCopy(section)
					out._versions[gid] = 0
				else
					legacy["game." .. tostring(gid)] = Freeze.deepCopy(section)
				end
			end
		else
			local target = FrameworkSection.V12_MAP[key]
			if target == nil then
				legacy[key] = Freeze.deepCopy(value)
			elseif target == "_framework" then
				out._framework[key] = Freeze.deepCopy(value)
			else
				out[target] = out[target] or {}
				out[target][key] = Freeze.deepCopy(value)
				out._versions[target] = 0
			end
		end
	end
	if next(legacy) ~= nil then
		out._framework.legacy = legacy
	end
	out._framework.migratedFrom = old.schemaVersion
	return out
end

-- Migrates the whole root to the current framework version. Returns (root, err?). Never mutates
-- the input.
function FrameworkSection.migrate(root: any, gameId: string?, now: number): (any, string?)
	if root == nil or (type(root) == "table" and next(root) == nil) then
		return { _framework = FrameworkSection.default(now), _versions = {} }, nil
	end
	if type(root) ~= "table" then
		return nil, "save is not a table"
	end
	local data = Freeze.deepCopy(root)
	if FrameworkSection.isV12(data) then
		local ok, out = pcall(FrameworkSection.splitV12, data, gameId)
		if not ok then
			return nil, "v1.2 save split failed: " .. tostring(out)
		end
		data = out
	end
	local fw = data._framework
	if type(fw) ~= "table" then
		return nil, "_framework section missing or not a table"
	end
	local v = fw.schemaVersion
	if type(v) ~= "number" then
		return nil, "_framework.schemaVersion missing"
	end
	if v > FrameworkSection.VERSION then
		return nil,
			`save written by a newer framework (_framework.schemaVersion {v} > {FrameworkSection.VERSION}); not loading it`
	end
	-- reconcile: fill missing framework fields
	for k, d in FrameworkSection.default(now) do
		if fw[k] == nil then
			fw[k] = d
		end
	end
	fw.schemaVersion = FrameworkSection.VERSION
	if type(data._versions) ~= "table" then
		data._versions = {}
	end
	return data, nil
end

return FrameworkSection
