--!strict
--[[
	Server parts of the economy kit's modules for the framework loader (loadServer(ref) -> part).
	core-v1.3.0 Phase 1: Economy, Upgrades, Rebirth and Offline are REAL StudWork modules
	(module-api.md §3-§8); each call builds a fresh part (<Module>.new()), so two runtimes in one
	process (tests, the multi-server sim) never share module state. The framework's default loader
	finds this file in the kit layout (ServerScriptService.Kits.Economy.ModuleServers).

	isReal(ref) -> boolean: whether `ref`'s part came from here (the compat adapter,
	packages/kits/compat/adapters/Economy.luau, adapts only this kit's own parts; Phase 2 deletes
	it with compat).
]]

local ModuleServers = {}

local PARTS: { [string]: () -> any } = {
	Economy = function()
		return require(script.Parent.Economy).new()
	end,
	Upgrades = function()
		return require(script.Parent.Upgrades).new()
	end,
	Rebirth = function()
		return require(script.Parent.Rebirth).new()
	end,
	Offline = function()
		return require(script.Parent.Offline).new()
	end,
}

ModuleServers.names = table.freeze({ "Economy", "Upgrades", "Rebirth", "Offline" })

local built: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- loadServer(ref) for StudWork server boot opts; nil when the module is not part of this kit.
function ModuleServers.loadServer(ref: any): any
	local name = ref.server or ref.name
	local make = PARTS[name]
	if make == nil then
		return nil
	end
	built[ref] = true
	return make()
end

function ModuleServers.isReal(ref: any): boolean
	return built[ref] == true
end

return ModuleServers
