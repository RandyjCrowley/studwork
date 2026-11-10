--!strict
--[[
	Pure session luck registry for Core.Rarity (zero requires; luck sanitiser injected).

	LuckRegistry.new(sanitize) -> Registry
		:set(key, luck, tableId?)  tableId nil = every table. Stores sanitize(luck).
		:get(key, tableId?) -> number  per-table value wins over the all-table value; 1 if unset.
		:getTableOnly(key, tableId) -> number  the per-table value only (1 if unset); review R5.
		:clear(key)                forget everything for key (PlayerRemoving).
		:has(key) -> boolean       anything stored for key.
	Keys are Players in production (any value in tests).
]]

type Entry = { all: number?, tables: { [string]: number } }

export type Registry = {
	set: (self: Registry, key: any, luck: any, tableId: string?) -> (),
	get: (self: Registry, key: any, tableId: string?) -> number,
	getTableOnly: (self: Registry, key: any, tableId: string) -> number,
	clear: (self: Registry, key: any) -> (),
	has: (self: Registry, key: any) -> boolean,
}

local LuckRegistry = {}

function LuckRegistry.new(sanitize: (luck: any) -> number): Registry
	local entries: { [any]: Entry } = {}
	local registry = {}

	function registry.set(_self: Registry, key: any, luck: any, tableId: string?)
		local entry = entries[key]
		if entry == nil then
			entry = { all = nil, tables = {} }
			entries[key] = entry
		end
		local value = sanitize(luck)
		if tableId == nil then
			entry.all = value
		else
			entry.tables[tableId] = value
		end
	end

	function registry.get(_self: Registry, key: any, tableId: string?): number
		local entry = entries[key]
		if entry == nil then
			return 1
		end
		if tableId ~= nil then
			local v = entry.tables[tableId]
			if v ~= nil then
				return v
			end
		end
		return entry.all or 1
	end

	function registry.getTableOnly(_self: Registry, key: any, tableId: string): number
		local entry = entries[key]
		return if entry then (entry.tables[tableId] or 1) else 1
	end

	function registry.clear(_self: Registry, key: any)
		entries[key] = nil
	end

	function registry.has(_self: Registry, key: any): boolean
		return entries[key] ~= nil
	end

	return (registry :: any) :: Registry
end

return LuckRegistry
