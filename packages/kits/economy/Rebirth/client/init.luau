--!strict
--[[
	Rebirth client part (module-api.md §9; core-v1.3.1 R19: one folder per module, found by the client
	runtime as ReplicatedStorage.Modules.Rebirth.client). Client actions:
	  StudWork.use(Rebirth).actions.<name>(...)
	Transitional (core-v1.3.1 Phase 1): the actions fire the framework Blink file's request events
	(`net = "framework"`, the content of the deleted kit ModuleClients); the module's own
	net.blink replaces them in Phase 2.
]]

return {
	net = "framework",
	actions = {
		rebirth = "RequestRebirth",
	},
}
