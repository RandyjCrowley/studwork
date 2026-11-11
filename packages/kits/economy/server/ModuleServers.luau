--!strict
--[[
	Server parts of the economy kit's modules for the framework loader (loadServer(ref) -> impl).
	core-v1.3.0 step 4b-IIa: each part is built by the COMPAT BRIDGE (packages/kits/compat/
	Bridge.luau; deleted in Phase 2): the UNCHANGED v1.2 service runs behind the module's
	defineModule wrapper, with a real init(ctx)/start(ctx) that runs the v1.2 service's
	init/start on a v1.2-shaped ctx built from the framework, its v1.2 public functions as `api`
	(+ `signals`), and its purchase operations as `purchaseOps` (Economy.grant,
	Inventory.addItem, Rarity.roll). The framework's default loader finds this file in the Phase 0
	kit layout (ServerScriptService.Kits.<Kit>.ModuleServers). Service requires are lazy, so
	loading this file never boots or requires a service. Phase 1 replaces this file with real
	server/init.luau parts.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local ModuleServers = {}

local SERVICES: { [string]: () -> any } = {
	Economy = function()
		return require(script.Parent.Economy)
	end,
	Upgrades = function()
		return require(script.Parent.Upgrades)
	end,
	Rebirth = function()
		return require(script.Parent.Rebirth)
	end,
	Offline = function()
		return require(script.Parent.Offline)
	end,
}

ModuleServers.names = table.freeze({ "Economy", "Upgrades", "Rebirth", "Offline" })

-- loadServer(ref) for StudWork server boot opts; nil when the module is not part of this kit.
function ModuleServers.loadServer(ref: any): any
	local name = ref.server or ref.name
	local load = SERVICES[name]
	if load == nil then
		return nil
	end
	local Bridge = (require :: any)(ServerScriptService:WaitForChild("Compat"):WaitForChild("Bridge"))
	return Bridge.serverPart(name, load)
end

return ModuleServers
