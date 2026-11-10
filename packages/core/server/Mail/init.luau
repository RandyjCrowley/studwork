--!strict
--[[
	Core.Mail. OWNED BY AGENT C (core/v11-c-mail). Public API: Types.MailAPI. See README.md.

	send(userId, kind, payload, key?) -> boolean
	  Validates (MailValidate: kind ^[%w_-]{1,32}$, payload = JSON-safe table <= 1000 bytes,
	  key = short id string, default a new GUID) and calls
	  ProfileStore:MessageAsync("Player_" .. userId, { id, kind, payload, sentAt }) on the same
	  store Data uses (real or Mock). YIELDS (DataStore write). Works offline / cross-server.
	onReceive(kind, handler) -> Connection
	  handler(player, payload, info) runs synchronously (pcall) per message. Failure = error or
	  `false`. At-least-once with idempotency by id, retries with backoff, dead letters: the state
	  machine lives in Delivery.luau. HANDLERS MUST BE SAFE TO RUN TWICE.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = ReplicatedStorage:WaitForChild("Core")
local Types = require(Core:WaitForChild("Types"))
local Validate = require(Core:WaitForChild("Validate"))
local Internal = require(script.Parent:WaitForChild("Data"):WaitForChild("Internal"))
local MailValidate = require(script.MailValidate)
local Delivery = require(script.Delivery)

local STORE_WAIT = 20 -- seconds send() waits for Data to choose its store

local Mail = {}

type Handler = (Player, { [string]: any }, Types.MailInfo) -> boolean?

local ctx: any = nil
local delivery: any = nil

local function encode(value: any): string
	return HttpService:JSONEncode(value)
end

-- Created at require time (deps read ctx lazily) so onReceive works before Mail.init.
delivery = Delivery.new({
	now = os.time,
	delay = function(seconds: number, fn: () -> ())
		task.delay(seconds, fn)
	end,
	isActive = function(player: any): boolean
		return ctx ~= nil and player.Parent == Players and ctx.services.Data.isLoaded(player)
	end,
	getMail = function(player: any): any
		local data = ctx.services.Data.get(player)
		return data and data.mail
	end,
	update = function(player: any, fn: (mail: any) -> ()): boolean
		local ok, result = pcall(ctx.services.Data.update, player, function(data: Types.PlayerData)
			fn(data.mail)
		end)
		return ok and result == true
	end,
	analytics = function(player: any, name: string, value: number)
		ctx.services.Analytics.custom(player, name, value)
	end,
	warn = warn,
})

function Mail.init(context: any)
	ctx = context
	Internal.deliver = delivery.deliver
end

function Mail.start()
	Players.PlayerRemoving:Connect(function(player: Player)
		delivery.forget(player)
	end)
	game:BindToClose(function()
		delivery.stop()
	end)
end

function Mail.send(userId: number, kind: string, payload: { [string]: any }, key: string?): boolean
	local ok, reason = MailValidate.message(userId, kind, payload, encode)
	if not ok then
		warn(`[Core.Mail] send rejected: {reason}`)
		return false
	end
	if key ~= nil and not (Validate.isId(key, MailValidate.MAX_KEY_LENGTH) and MailValidate.key(key)) then
		warn("[Core.Mail] send rejected: bad key")
		return false
	end
	local store = Internal.waitStore(STORE_WAIT)
	if store == nil then
		return false
	end
	local sent, result = pcall(function()
		return store:MessageAsync("Player_" .. tostring(userId), {
			id = key or HttpService:GenerateGUID(false),
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

-- v1.2 (N1) CONTRACT STUBS (core-contract-v1.2): agent A implements (Types.MailAPI comments).
function Mail.pending(_player: Player): { Types.MailboxEntry }
	return {}
end

function Mail.claim(_player: Player, _messageId: string): (boolean, string?)
	return false, "not_found"
end

-- ctx-only (Context.MailInternal). Contract stub: agent A implements.
function Mail.sendInto(
	_tx: any,
	_toUserId: number,
	_kind: string,
	_payload: { [string]: any },
	_key: string
): boolean
	error("[Core.Mail] sendInto is not implemented yet (core-contract-v1.2 stub)", 2)
end

function Mail.onReceive(kind: string, handler: Handler): Types.Connection
	assert(MailValidate.kind(kind), "Mail.onReceive: invalid kind")
	assert(type(handler) == "function", "Mail.onReceive: handler must be a function")
	local disconnect = delivery.register(kind, handler)
	local connection = { Connected = true }
	function connection.Disconnect(self: any)
		if self.Connected then
			self.Connected = false
			disconnect()
		end
	end
	return (connection :: any) :: Types.Connection
end

return Mail
