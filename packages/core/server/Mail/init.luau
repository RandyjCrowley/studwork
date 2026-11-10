--!strict
--[[
	Core.Mail. OWNED BY AGENT A (core/a-data). Public API: Types.MailAPI.

	PHASE 0 STUB: delivers only to players currently in this server. Agent A implements it with
	ProfileStore:MessageAsync (works for offline users / other servers) + profile message handler.
]]

local Players = game:GetService("Players")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Mail = {}

local handlers: { [string]: { (Player, { [string]: any }) -> () }? } = {}

function Mail.init(_context: any) end

function Mail.start() end

function Mail.send(userId: number, kind: string, payload: { [string]: any }): boolean
	local player = Players:GetPlayerByUserId(userId)
	if player == nil then
		return false
	end
	local list = handlers[kind]
	if list then
		for _, handler in list do
			task.spawn(handler, player, payload)
		end
	end
	return true
end

function Mail.onReceive(
	kind: string,
	handler: (player: Player, payload: { [string]: any }) -> ()
): Types.Connection
	local list = handlers[kind] or {}
	handlers[kind] = list
	table.insert(list, handler)
	local connection = { Connected = true }
	function connection.Disconnect(self: any)
		self.Connected = false
		local index = table.find(list, handler)
		if index then
			table.remove(list, index)
		end
	end
	return (connection :: any) :: Types.Connection
end

return Mail
