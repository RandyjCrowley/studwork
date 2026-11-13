--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Rules = require(
	ReplicatedStorage:WaitForChild("Modules")
		:WaitForChild("Codes")
		:WaitForChild("shared")
		:WaitForChild("Rules")
)
local Catalog = {}
function Catalog.copy(raw: any): any
	if type(raw) ~= "table" then
		return raw
	end
	local out = {}
	for k, value in raw do
		out[k] = Catalog.copy(value)
	end
	return table.freeze(out)
end
local function bounded(raw: any, depth: number, seen: any, budget: any): boolean
	budget.nodes += 1
	if depth > 12 or budget.nodes > 20000 then
		return false
	end
	if type(raw) == "string" then
		budget.bytes += #raw
	elseif type(raw) == "table" then
		if seen[raw] or getmetatable(raw) ~= nil then
			return false
		end
		seen[raw] = true
		for k, value in raw do
			if not bounded(k, depth + 1, seen, budget) or not bounded(value, depth + 1, seen, budget) then
				return false
			end
		end
		seen[raw] = nil
	elseif type(raw) == "number" then
		if not Rules.finite(raw) then
			return false
		end
		budget.bytes += 24
	elseif type(raw) == "boolean" then
		budget.bytes += 5
	else
		return false
	end
	return budget.bytes <= 90000
end
function Catalog.live(raw: any, config: any, warn: () -> ()): (boolean, any, any)
	if raw == nil then
		return true, {}, {}
	end
	if type(raw) ~= "table" or not bounded(raw, 0, {}, { bytes = 0, nodes = 0 }) then
		return false, nil, nil
	end
	for k in raw do
		if k ~= "definitions" and k ~= "disabled" then
			return false, nil, nil
		end
	end
	local defs, disabled = raw.definitions or {}, raw.disabled or {}
	if
		type(defs) ~= "table"
		or #defs > config.live.maxEntries
		or type(disabled) ~= "table"
		or #disabled > config.maxDefinitions
	then
		return false, nil, nil
	end
	local out, off = {}, {}
	local seenIds, seenCodes = {}, {}
	local entries = 0
	for i, def in defs do
		entries += 1
		if not Rules.integer(i, 1, #defs) or entries > config.live.maxEntries then
			return false, nil, nil
		end
		if Rules.validateDefinition(def, config) then
			local normalized = Rules.normalize(def.code, config.maxLength)
			if not seenIds[def.id] and not seenCodes[normalized] then
				seenIds[def.id], seenCodes[normalized] = true, true
				table.insert(out, Catalog.copy(def))
			else
				warn()
			end
		else
			warn()
		end
	end
	if entries ~= #defs then
		return false, nil, nil
	end
	entries = 0
	for i, id in disabled do
		entries += 1
		if not Rules.integer(i, 1, #disabled) or not Rules.id(id) then
			return false, nil, nil
		end
		off[id] = true
	end
	if entries ~= #disabled then
		return false, nil, nil
	end
	return true, out, off
end
-- Merge by permanent id; reject conflicting normalized strings without exposing their text.
function Catalog.merge(base: any, live: any, disabled: any, config: any): (any, any, any)
	local byId, byCode, retained = {}, {}, {}
	for id, def in base do
		byId[id] = def
		retained[id] = true
	end
	for _, def in live do
		byId[def.id] = def
		retained[def.id] = true
	end
	local count = 0
	for id, def in byId do
		count += 1
		assert(count <= config.maxDefinitions, "promotion catalog exceeds limit")
		local normalized = Rules.normalize(def.code, config.maxLength) :: string
		assert(byCode[normalized] == nil, "duplicate promotion identity")
		byCode[normalized] = if disabled[id] then false else def
	end
	for id in disabled do
		retained[id] = true
	end
	return byId, byCode, retained
end
return Catalog
