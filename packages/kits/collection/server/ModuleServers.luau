--!strict
--[[
	Server parts of the collection kit's modules for the framework loader (loadServer(ref) -> impl).
	core-v1.3.0 Phase 1: Items, Inventory and Rarity are REAL modules on the module API
	(module-api.md §3-§9): each loadServer call builds a fresh part (<Module>.new()), so every
	runtime (each sim server, each test harness) has its own state. The framework's default loader
	finds this file in the kit layout (ServerScriptService.Kits.<Kit>.ModuleServers). Requires are
	lazy, so loading this file never builds a part.
]]

local ModuleServers = {}

local PARTS: { [string]: () -> any } = {
	Items = function()
		return require(script.Parent.Items)
	end,
	Inventory = function()
		return require(script.Parent.Inventory)
	end,
	Rarity = function()
		return require(script.Parent.Rarity)
	end,
}

ModuleServers.names = table.freeze({ "Items", "Inventory", "Rarity" })

-- loadServer(ref) for StudWork server boot opts; nil when the module is not part of this kit.
function ModuleServers.loadServer(ref: any): any
	local name = ref.server or ref.name
	local load = PARTS[name]
	if load == nil then
		return nil
	end
	return load().new()
end

return ModuleServers
