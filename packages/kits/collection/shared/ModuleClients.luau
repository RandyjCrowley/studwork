--!strict
--[[
	Client parts of the collection kit's modules for the framework client loader (loadClient(ref)).
	core-v1.3.0 step 4b-IIa (Phase 0 kit layout; Phase 1 replaces this with each module's real
	client/init.luau): the v1.2 client actions of these modules, as module actions on the client
	(module-api.md §9): StudWork.use(<Module>).actions.<name>(...) fires the named event of the
	framework Blink file (shared/net/framework.blink), whose server handler is the v1.2 service's.
]]

local ModuleClients = {}

-- module -> { action = framework Blink client event }
ModuleClients.ACTIONS = table.freeze({
	Inventory = { gift = "RequestGift" },
	Rarity = { roll = "RequestRoll" },
})

function ModuleClients.loadClient(ref: any): any
	local actions = ModuleClients.ACTIONS[ref.client or ref.name]
	if actions == nil then
		return nil
	end
	-- "framework": the framework client resolves its own Blink file (kits never require it)
	return { net = "framework", actions = actions }
end

return ModuleClients
