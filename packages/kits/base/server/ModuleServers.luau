--!strict
--[[
	Server parts of the base kit's modules for the framework loader (loadServer(ref) -> impl).
	core-v1.3.0 Phase 0 step 5 thin wrappers: each impl only exposes the UNCHANGED v1.2 service
	table as `api`, with no init/start, because the v1.2 packages/core facade (Core.start) still
	owns these services' lifecycle in this step. Requires are lazy so loading this file never
	boots or requires a service. Phase 1 replaces these with real server/init.luau parts.
]]

local ModuleServers = {}

local LOADERS: { [string]: () -> any } = {
	Plot = function()
		return { api = require(script.Parent.Plot) }
	end,
}

ModuleServers.names = table.freeze({ "Plot" })

-- loadServer(ref) for StudWork server boot opts; nil when the module is not part of this kit.
function ModuleServers.loadServer(ref: any): any
	local loader = LOADERS[ref.server or ref.name]
	return if loader then loader() else nil
end

return ModuleServers
