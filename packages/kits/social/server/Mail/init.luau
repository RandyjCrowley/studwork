--!strict
--[[
	Core.Mail. Public API: Types.MailAPI (+ ctx-only Context.MailInternal.sendInto). See README.md.
	Logic lives in pure modules: Delivery.luau (delivery + mailbox), Outbox.luau (sendInto flush),
	MailValidate.luau. This file only wires them to Data/ProfileStore/Net/Replication/Console.

	send(userId, kind, payload, key?) -> boolean
	  Validates (MailValidate: kind ^[%w_-]{1,32}$, payload = JSON-safe table <= 1000 bytes,
	  key = short id string, default a new GUID) and calls
	  ProfileStore:MessageAsync("Player_" .. userId, { id, kind, payload, sentAt }) on the same
	  store Data uses (real or Mock). YIELDS (DataStore write). Works offline / cross-server.
	onReceive(kind, handler) -> Connection
	  handler(player, payload, info) runs synchronously (pcall) per message. `false` = held in the
	  mailbox (N1); error = failure (retries with backoff, dead letters). At-least-once with
	  idempotency by id: the state machine lives in Delivery.luau. HANDLERS MUST BE SAFE TO RUN TWICE.
	pending(player) / claim(player, id): the mailbox (ReplicatedState.mailbox, RequestMailClaim).
	sendInto(tx, toUserId, kind, payload, key): ctx-only outbox write (Outbox.luau).
	Kinds starting with "core_" are reserved: the public facade's send/onReceive refuse them.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = ReplicatedStorage:WaitForChild("Core")
local Types = require(Core:WaitForChild("Types"))
local Validate = require(Core:WaitForChild("Validate"))
-- v1.2 Data<->Mail bridge, now in packages/kits/compat (COMPAT; Phase 1 agent C moves Mail
-- onto ctx.data.messages and Phase 2 deletes it)
local Internal =
	require(game:GetService("ServerScriptService"):WaitForChild("Compat"):WaitForChild("MailInternal"))
local MailValidate = require(script.MailValidate)
local Delivery = require(script.Delivery)
local Outbox = require(script.Outbox)

local STORE_WAIT = 20 -- seconds send() waits for Data to choose its store

local Mail = {}

type Handler = (Player, { [string]: any }, Types.MailInfo) -> boolean?

local ctx: any = nil
local delivery: any = nil
local outbox: any = nil

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
	config = function(): any
		return if ctx then ctx.config.mail else nil
	end,
	onBoxChanged = function(player: any, held: boolean)
		local list = delivery.pending(player)
		ctx.setReplicated(player, "mailbox", list)
		if held then
			local n = #list
			ctx.net.feedback(player, "toast", `Mailbox: {n} item{if n == 1 then "" else "s"} waiting`)
		end
	end,
})

local function storeSend(entry: Outbox.Entry): boolean
	local store = Internal.waitStore(STORE_WAIT)
	if store == nil then
		return false
	end
	local ok, result = pcall(function()
		return store:MessageAsync("Player_" .. tostring(entry.toUserId), {
			id = entry.key,
			kind = entry.kind,
			payload = entry.payload,
			sentAt = entry.at,
		})
	end)
	if not ok or result ~= true then
		return false
	end
	local nudge = Internal.nudgeSave
	if nudge then
		nudge(entry.toUserId)
	end
	return true
end

outbox = Outbox.new({
	now = os.time,
	delay = function(seconds: number, fn: () -> ())
		task.delay(seconds, fn)
	end,
	isActive = function(player: any): boolean
		return ctx ~= nil and player.Parent == Players and ctx.services.Data.isLoaded(player)
	end,
	getOutbox = function(player: any): any
		local data = ctx.services.Data.get(player)
		return data and data.mail and data.mail.outbox
	end,
	save = function(player: any): boolean
		return ctx.services.Data.saveAsync(player) == true
	end,
	send = storeSend,
	remove = function(player: any, key: string): boolean
		local ok, result = pcall(ctx.services.Data.update, player, function(data: Types.PlayerData)
			local box = data.mail.outbox
			if box then
				box[key] = nil
			end
		end)
		return ok and result == true
	end,
	backoff = function(attempt: number): number
		return Delivery.backoff(attempt, if ctx then ctx.config.mail else nil)
	end,
	warn = warn,
})

local function findPlayer(userIdArg: any): Player?
	local userId = tonumber(userIdArg)
	if userId then
		return Players:GetPlayerByUserId(userId)
	end
	return Players:GetPlayers()[1]
end

local function registerConsole()
	ctx.console.register("mailbox", "mailbox [userId]: list held mail (mailbox)", function(userIdArg: any)
		local player = findPlayer(userIdArg)
		if player == nil then
			return "no player"
		end
		local lines = { `{player.Name}: {#Mail.pending(player)} held` }
		for _, entry in Mail.pending(player) do
			table.insert(lines, `  {entry.id} {entry.kind} heldAt={entry.heldAt}`)
		end
		local data = ctx.services.Data.get(player)
		local dead = data and data.mail and data.mail.dead or {}
		for _, letter in dead do
			table.insert(lines, `  dead: {letter.id} {letter.kind} ({letter.attempts}x) {letter.error}`)
		end
		return table.concat(lines, "\n")
	end)
	ctx.console.register(
		"mailclaim",
		"mailclaim <userId> <id>: claim a held message",
		function(u: any, id: any)
			local player = findPlayer(u)
			if player == nil or type(id) ~= "string" then
				return "usage: mailclaim <userId> <id>"
			end
			local ok, reason = Mail.claim(player, id)
			return if ok then "claimed " .. id else "refused: " .. tostring(reason)
		end
	)
	ctx.console.register(
		"mailreplay",
		"mailreplay <userId> <id>: move a dead letter back into the mailbox",
		function(u: any, id: any)
			local player = findPlayer(u)
			if player == nil or type(id) ~= "string" then
				return "usage: mailreplay <userId> <id>"
			end
			local ok, reason = delivery.replay(player, id)
			return if ok then "replayed " .. id .. " into the mailbox" else "refused: " .. tostring(reason)
		end
	)
end

function Mail.init(context: any)
	ctx = context
	Internal.deliver = delivery.deliver
end

function Mail.start()
	ctx.services.Data.onLoaded(function(player: Player, _data: Types.PlayerData)
		ctx.setReplicated(player, "mailbox", Mail.pending(player))
		outbox.markLoaded(player)
		outbox.flush(player) -- leftovers from an earlier session (yields)
	end)
	ctx.net.handle("RequestMailClaim", function(player: Player, messageId: any)
		if not MailValidate.key(messageId) then
			return
		end
		local ok, reason = Mail.claim(player, messageId)
		if not ok and reason == "still_held" then
			ctx.net.feedback(player, "toast", "No room yet: free some space and try again")
		elseif not ok and reason == "error" then
			ctx.net.feedback(player, "toast", "Couldn't claim that right now")
		end
	end)
	if ctx.isStudio then
		registerConsole()
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		delivery.forget(player)
		outbox.forget(player)
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

-- v1.2 (N1): the mailbox, oldest heldAt first (copies).
function Mail.pending(player: Player): { Types.MailboxEntry }
	return delivery.pending(player)
end

-- v1.2 (N1): re-run the handlers of a held message. Pushes ReplicatedState.mailbox on success.
function Mail.claim(player: Player, messageId: string): (boolean, string?)
	return delivery.claim(player, messageId)
end

-- ctx-only (Context.MailInternal): queue a message in tx.player's outbox; sent after commit
-- (once the update is saved) and on the sender's next load until MessageAsync succeeds.
function Mail.sendInto(
	tx: any,
	toUserId: number,
	kind: string,
	payload: { [string]: any },
	key: string
): boolean
	local player = tx.player
	local ok, reason = Outbox.writeInto(tx, toUserId, kind, payload, key, os.time(), encode, function()
		task.spawn(outbox.flush, player)
	end)
	if not ok then
		warn(`[Core.Mail] sendInto rejected: {reason}`)
	end
	return ok
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

-- Public facade overrides (shared/init.luau publicTable): "core_" kinds are reserved for core.
-- Core services call ctx.services.Mail directly and may use them (Inventory: core_gift).
Mail.facade = {
	send = function(userId: number, kind: string, payload: { [string]: any }, key: string?): boolean
		if MailValidate.isReserved(kind) then
			warn(`[Core.Mail] send rejected: kind '{kind}' is reserved for core`)
			return false
		end
		return Mail.send(userId, kind, payload, key)
	end,
	onReceive = function(kind: string, handler: Handler): Types.Connection
		if MailValidate.isReserved(kind) then
			error(`[Core.Mail] onReceive: kind '{kind}' is reserved for core`, 2)
		end
		return Mail.onReceive(kind, handler)
	end,
}

return Mail
