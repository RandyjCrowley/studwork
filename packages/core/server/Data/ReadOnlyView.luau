--!strict
--[[
	Read-only view of a player's data for the public Core.Data.get / getGame in Studio (review N8).
	Pure (no Roblox globals). LEAD-OWNED.

	Why: core's replication copies a PlayerData section again only when its section version moves
	(a committed Data.update). A game that writes in place through Data.get (against the rules)
	changes the saved data but the client never sees it. In Studio the facade hands out frozen
	copies instead, so such a write fails loudly at the line that makes it
	("attempt to modify a readonly table").

	build(cache, data, versionOf) -> frozen deep copy of `data`. Each top-level table section is
	copied again only when versionOf(section) changed since the last build for this cache, so
	repeated reads are cheap; scalars are copied every time. Live servers never use this (the
	facade returns the live table, as before).
]]

local ReadOnlyView = {}

export type Cache = { sections: { [string]: { version: number, view: any } } }

function ReadOnlyView.new(): Cache
	return { sections = {} }
end

-- Deep copy with every table frozen.
function ReadOnlyView.freezeCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = ReadOnlyView.freezeCopy(v)
	end
	return table.freeze(out)
end

function ReadOnlyView.build(cache: Cache, data: any, versionOf: (section: string) -> number): any
	if type(data) ~= "table" then
		return data
	end
	local root = {}
	local seen: { [string]: boolean } = {}
	for key, value in data do
		if type(value) == "table" and type(key) == "string" then
			seen[key] = true
			local version = versionOf(key)
			local hit = cache.sections[key]
			if hit == nil or hit.version ~= version then
				hit = { version = version, view = ReadOnlyView.freezeCopy(value) }
				cache.sections[key] = hit
			end
			root[key] = hit.view
		else
			root[key] = ReadOnlyView.freezeCopy(value)
		end
	end
	for key in cache.sections do
		if not seen[key] then
			cache.sections[key] = nil
		end
	end
	return table.freeze(root)
end

return ReadOnlyView
