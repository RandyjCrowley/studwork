--!strict
--[[
	Server parts of the engagement kit's modules for the framework loader (loadServer(ref) -> impl).
	core-v1.3.0 Phase 1: every module of this kit is REAL (Streak): loadServer returns its
	server part (init / start / api / txApi / extensions), (a real module). The framework's
	default loader finds this file in the kit layout (ServerScriptService.Kits.<Kit>.ModuleServers).
	Requires are lazy, so loading this file never boots a module.
]]

local ModuleServers = {}

local PARTS: { [string]: () -> any } = {
	Streak = function()
		return require(script.Parent.Streak)
	end,
}

ModuleServers.names = table.freeze({ "Streak" })

-- loadServer(ref) for StudWork server boot opts; nil when the module is not part of this kit.
function ModuleServers.loadServer(ref: any): any
	local load = PARTS[ref.server or ref.name]
	if load == nil then
		return nil
	end
	return load()
end

return ModuleServers
