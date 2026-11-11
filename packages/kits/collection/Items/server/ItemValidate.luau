--!strict
--[[
	Pure validation for ItemDefs (zero Roblox dependencies; tested under Lune).

	validateDef(def, rank?) -> err?
	validateBatch(defs, isTaken, rank?) -> (ok, err?)
		Checks every def in `defs` and rejects ids that are taken (isTaken(id) == true) or repeated
		inside the batch. Nothing is registered by this module (there is no item registration
		after boot in v1.3.0).

	v1.3.0: the base ItemDef is { id, name, rarity, model, icon, tags, source, keepOnRebirth }
	(module-api.md §12); income is Economy's namespaced field (item.economy.incomePerSec). Items runs
	these checks at boot on GameConfig.items, on top of the framework's base-field schema.

	Rules per def:
		id            non-empty string <= 64 chars matching Validate.ID_PATTERN (saved forever)
		name          non-empty string <= 100 chars
		rarity        nil or a tier of the active list (`rank`; default the standard7 preset)
		incomePerSec  v1.2 top-level field: no longer part of the base def (the framework rejects
		              it unless a module declares that namespace); still type-checked when present
		tags          nil or an array of non-empty strings
		model, icon, source   nil or string
		keepOnRebirth nil or boolean
]]

local Tiers = require(
	game:GetService("ReplicatedStorage")
		:WaitForChild("Modules")
		:WaitForChild("Rarity")
		:WaitForChild("shared")
		:WaitForChild("Tiers")
)
local Validate = require(script.Parent.Util)

local STANDARD = Tiers.rankMap(Tiers.PRESETS.standard7)

local ItemValidate = {}

ItemValidate.MAX_ID_LENGTH = 64
ItemValidate.MAX_NAME_LENGTH = 100

local function isArrayOfStrings(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local n = 0
	for key, entry in value do
		if type(key) ~= "number" or type(entry) ~= "string" or entry == "" then
			return false
		end
		n += 1
	end
	return n == #value
end

local function optionalString(value: any): boolean
	return value == nil or type(value) == "string"
end

-- Validates one def; returns an error message (without the "[Core.Items]" prefix) or nil.
-- `rank` = the active tier list's rank map (Tiers.rankMap); nil = the standard7 preset; false =
-- don't check `rarity` (Items: the tier list is Rarity's config, Rarity checks it).
function ItemValidate.validateDef(def: any, rank: any): string?
	local tiers: { [string]: number }? = if rank == false then nil else (rank or STANDARD)
	if type(def) ~= "table" then
		return "item def must be a table, got " .. type(def)
	end
	local id = def.id
	if not Validate.isShortString(id, ItemValidate.MAX_ID_LENGTH, Validate.ID_PATTERN) then
		return "invalid item id " .. tostring(id) .. " (1..64 chars of letters, digits, _ - . :)"
	end
	local label = "item '" .. id .. "'"
	if not Validate.isShortString(def.name, ItemValidate.MAX_NAME_LENGTH) then
		return label .. ": name must be a non-empty string <= 100 chars"
	end
	if
		def.rarity ~= nil and (type(def.rarity) ~= "string" or (tiers ~= nil and tiers[def.rarity] == nil))
	then
		return label .. ": unknown rarity " .. tostring(def.rarity)
	end
	if def.incomePerSec ~= nil and not Validate.isNonNegativeNumber(def.incomePerSec) then
		return label .. ": incomePerSec must be a finite number >= 0, got " .. tostring(def.incomePerSec)
	end
	if def.tags ~= nil and not isArrayOfStrings(def.tags) then
		return label .. ": tags must be an array of non-empty strings"
	end
	if not (optionalString(def.model) and optionalString(def.icon) and optionalString(def.source)) then
		return label .. ": model, icon and source must be strings when set"
	end
	if def.keepOnRebirth ~= nil and type(def.keepOnRebirth) ~= "boolean" then
		return label .. ": keepOnRebirth must be a boolean when set"
	end
	return nil
end

function ItemValidate.validateBatch(
	defs: any,
	isTaken: (id: string) -> boolean,
	rank: any
): (boolean, string?)
	if type(defs) ~= "table" then
		return false, "register expects an array of item defs, got " .. type(defs)
	end
	local seen: { [string]: boolean } = {}
	for i, def in defs do
		if type(i) ~= "number" then
			return false, "register expects an array of item defs (found key " .. tostring(i) .. ")"
		end
		local err = ItemValidate.validateDef(def, rank)
		if err then
			return false, err
		end
		local id: string = def.id
		if isTaken(id) or seen[id] then
			return false, "duplicate item id '" .. id .. "'"
		end
		seen[id] = true
	end
	return true, nil
end

return ItemValidate
