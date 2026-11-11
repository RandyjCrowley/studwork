--!strict
--[[
	Client parts of the economy kit's modules for the framework client loader (loadClient(ref)).
	core-v1.3.0 step 4b-IIa (Phase 0 kit layout; Phase 1 replaces this with each module's real
	client/init.luau): the v1.2 client actions of these modules, as module actions on the client
	(module-api.md §9): StudWork.use(<Module>).actions.<name>(...) fires the named event of the
	framework Blink file (shared/net/framework.blink), whose server handler is the v1.2 service's.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModuleClients = {}

-- module -> { action = framework Blink client event }
ModuleClients.ACTIONS = table.freeze({
	Upgrades = { upgrade = "RequestUpgrade" },
	Rebirth = { rebirth = "RequestRebirth" },
})

function ModuleClients.loadClient(ref: any): any
	local actions = ModuleClients.ACTIONS[ref.client or ref.name]
	if actions == nil then
		return nil
	end
	local net = (require :: any)(
		ReplicatedStorage:WaitForChild("FrameworkClient"):WaitForChild("Net"):WaitForChild("Generated")
	)
	return { net = net, actions = actions }
end

return ModuleClients
