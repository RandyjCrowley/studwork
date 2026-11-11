--!strict
--[[
	Plot client part (module-api.md §9; v1.3.1 R19: one folder per module, found by the client
	runtime as ReplicatedStorage.Modules.Plot.client). Client actions:
	  StudWork.use(Plot).actions.display(uid, slotId?)   fires Plot's own Blink event Display
	  StudWork.use(Plot).actions.clearDisplay(uid)       fires Plot's own Blink event ClearDisplay
	(net.blink -> client/Net.luau, bound by the runtime as the part's `net`; `true` = look the event
	up by the PascalCase action name).
	  StudWork.use(Plot).read.<reader>(StudWork.Client.state())   pure readers of its replicated
	  slice (client/State.luau)
]]

local State = require(script.State)

return {
	actions = {
		display = true,
		clearDisplay = true,
	},
	api = { read = State },
}
