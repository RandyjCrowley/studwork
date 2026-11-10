--!strict
--[[
	Core.Mail. OWNED BY AGENT A (core/a-data). Public API: Types.MailAPI.

	send(userId, kind, payload) -> boolean
	  Validates (MailValidate: kind ^[%w_-]{1,32}$, payload = JSON-safe table <= 1000 bytes) and
	  calls ProfileStore:MessageAsync("Player_" .. userId, { kind, payload, sentAt }) on the same
	  store Data uses (real or Mock). YIELDS (DataStore write). Works for offline users and players
	  in other servers: the message is queued inside their profile.
	  Delivery timing (ProfileStore behaviour): the owning server is pinged over MessagingService
	  and picks the message up on that profile's next save; for a player in THIS server Mail also
	  calls profile:Save() so it arrives within one save round-trip. Offline -> on their next load.
	onReceive(kind, handler) -> Connection
	  handler(player, payload) runs (task.spawn) for every message of that kind while the player
	  is online. A message is marked processed only when at least one handler exists for its kind;
	  otherwise ProfileStore keeps it queued and re-delivers it next session (queue cap 1000).
	  Delivery is at-least-once across server crashes: handlers should be idempotent
	  (e.g. include an id in the payload).
]]

local HttpService = game:GetService("HttpService")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local Internal = require(script.Parent:WaitForChild("Data"):WaitForChild("Internal"))
local MailValidate = require(script.MailValidate)

local STORE_WAIT = 20 -- seconds send() waits for Data to choose its store

local Mail = {}

local handlers: { [string]: { (Player, { [string]: any }) -> () } } = {}

local function encode(value: any): string
	return HttpService:JSONEncode(value)
end

local function deliver(player: Player, message: any): boolean
	if
		type(message) ~= "table"
		or not MailValidate.kind(message.kind)
		or type(message.payload) ~= "table"
	then
		return true -- malformed: consume so it doesn't clog the queue
	end
	local list = handlers[message.kind]
	if list == nil or #list == 0 then
		return false
	end
	for _, handler in table.clone(list) do
		task.spawn(handler, player, message.payload)
	end
	return true
end

function Mail.init(_context: any)
	Internal.deliver = deliver
end

function Mail.start() end

function Mail.send(userId: number, kind: string, payload: { [string]: any }): boolean
	local ok, reason = MailValidate.message(userId, kind, payload, encode)
	if not ok then
		warn(`[Core.Mail] send rejected: {reason}`)
		return false
	end
	local store = Internal.waitStore(STORE_WAIT)
	if store == nil then
		return false
	end
	local sent, result = pcall(function()
		return store:MessageAsync("Player_" .. tostring(userId), {
			kind = kind,
			payload = payload,
			sentAt = os.time(),
		})
	end)
	if not sent or result ~= true then
		return false
	end
	local nudge = Internal.nudgeSave
	if nudge then
		nudge(userId)
	end
	return true
end

function Mail.onReceive(
	kind: string,
	handler: (player: Player, payload: { [string]: any }) -> ()
): Types.Connection
	assert(MailValidate.kind(kind), "Mail.onReceive: invalid kind")
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
