--!strict
--[[
	Inventory client part (module-api.md §9; core-v1.3.1 R19: one folder per module, found by the client
	runtime as ReplicatedStorage.Modules.Inventory.client). Client actions:
	  StudWork.use(Inventory).actions.<name>(...)
	Transitional (core-v1.3.1 Phase 1): the actions fire the framework Blink file's request events
	(`net = "framework"`, the content of the deleted kit ModuleClients); the module's own
	net.blink replaces them in Phase 2.
	  StudWork.use(Inventory).read.<reader>(StudWork.Client.state())   pure readers of its replicated
	  slice (client/State.luau)
]]

local State = require(script.State)

return {
	net = "framework",
	actions = {
		gift = "RequestGift",
	},
	api = { read = State },
}
