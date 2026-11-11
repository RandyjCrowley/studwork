--!strict
--[[
	COMPAT ADAPTER for the Social kit (Friends, Mail). Owned by Phase 1 agent C; DELETED IN PHASE 2
	with the rest of packages/kits/compat.

	Friends and Mail are real: the compat bridge calls this once per module and uses the result as
	`services.<Module>` for the still-bridged v1.2 services and the sim's
	Bridge.compatServices(rt). Only the v1.2 names still called are returned (see
	(internal build report, not public), "Filling your adapter"):
	  Friends: onCoPlay, friendsInServer (sim CoPlay spec)
	  Mail: send, onReceive, pending, claim, sendInto (bridged Inventory: core_gift onReceive +
	  sendGift's outbox write; the sim specs: pending / claim)
	Signals: the real module's api.signals are mirrored into the v1.2 signal table the runtime's
	compat options provide (the sim's `server.signals.<Name>` history), when there is one.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local function kitChild(...: string): any
	local node: any = ServerScriptService:WaitForChild("Kits"):WaitForChild("Social")
	for _, name in { ... } do
		node = node:WaitForChild(name)
	end
	return (require :: any)(node)
end

-- Mirrors every signal of a real module into the runtime's v1.2 signal table (sim only).
local function mirrorSignals(rt: any, api: any)
	local compat = rt and rt.compat
	if type(compat) ~= "table" or type(compat.signals) ~= "function" or api == nil then
		return
	end
	local target = compat.signals()
	local signals = api.signals
	if type(target) ~= "table" or type(signals) ~= "table" then
		return
	end
	kitChild("SignalTable").watch(signals, function(name: string, signal: any)
		signal:Connect(function(...: any)
			target[name]:Fire(...)
		end)
	end)
end

return function(name: string, rt: any, api: any, _txApi: any, _extensions: any): any
	mirrorSignals(rt, api)
	if name == "Friends" then
		return {
			onCoPlay = api.onCoPlay,
			friendsInServer = api.friendsInServer,
		}
	elseif name == "Mail" then
		-- send / onReceive allow "core_" kinds here (the v1.2 internal surface Inventory used);
		-- sendInto takes a v1.2 tx { player, data (flat view), after }.
		local internal = kitChild("Mail")._compat
		return {
			send = internal.send,
			onReceive = internal.onReceive,
			pending = api.pending,
			claim = api.claim,
			sendInto = internal.sendInto,
		}
	end
	return nil
end
