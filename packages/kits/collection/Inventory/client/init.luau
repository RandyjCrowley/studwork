--!strict
--[[
	Inventory client part (module-api.md §9; core-v1.3.1 R19: one folder per module, found by the client
	runtime as ReplicatedStorage.Modules.Inventory.client). Client actions:
	  StudWork.use(Inventory).actions.<name>(...)
	The actions fire this module's own Blink event (net.blink -> client/Net.luau, event Gift; core-v1.3.1
	R19), bound by the client runtime from the Net child.
	  StudWork.use(Inventory).read.<reader>(StudWork.Client.state())   pure readers of its replicated
	  slice (client/State.luau)
]]

local State = require(script.State)

return {
	actions = { "gift" },
	api = { read = State },
}
