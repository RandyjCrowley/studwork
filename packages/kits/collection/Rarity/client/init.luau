--!strict
--[[
	Rarity client part (module-api.md §9; core-v1.3.1 R19: one folder per module, found by the client
	runtime as ReplicatedStorage.Modules.Rarity.client). Client actions:
	  StudWork.use(Rarity).actions.<name>(...)
	The actions fire this module's own Blink event (net.blink -> client/Net.luau, event Roll; core-v1.3.1
	R19), bound by the client runtime from the Net child.
	  StudWork.use(Rarity).read.<reader>(StudWork.Client.state())   pure readers of its replicated
	  slice (client/State.luau)
]]

local State = require(script.State)

return {
	actions = { "roll" },
	api = { read = State },
}
