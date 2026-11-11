--!strict
--[[
	Mail: the social kit's server module (core-v1.3.0 module API). See README.md.
	The logic lives in pure modules: Delivery.luau (at-least-once delivery, idempotency, the
	mailbox), Outbox.luau (the crash-safe outbox), Escrow.luau (R1 gift cap + return to sender),
	MailValidate.luau. This file wires them to ctx: ctx.data (section "mail", field `mail`, the
	v1.2 shape), ctx.data.messages (the framework's cross-server channel; no DataStore here),
	ctx.replicate (extra.mailbox), ctx.net (RequestMailClaim), ctx.console, ctx.lifecycle.

	api (PHASE1-CONTRACT, v1.2 names)
	  send(userId, kind, payload, key?) -> boolean    YIELDS. "core_" kinds are refused.
	  onReceive(kind, handler(player, payload, info) -> boolean?) -> Connection
	      false = held in the mailbox (no time limit); an error = retried with backoff, then
	      dead-lettered. At-least-once: handlers must be safe to run twice. "core_" refused.
	  pending(player) -> { MailboxEntry }      claim(player, id) -> (ok, reason?)
	txApi
	  send(tx, toUserId, kind, payload, key?) -> boolean   the outbox write (v1.2 sendInto): sent
	      after the tx commits and is saved; retried on the sender's next load until sent.
	extensions
	  registerKind(kind, claimFn(tx, player, payload, info) -> boolean?)   claimFn runs inside a
	      ctx.tx of the receiver; false holds the message (and discards that tx); an error rolls
	      the tx back and retries / dead-letters. "core_" kinds are allowed here (Inventory owns
	      core_gift).

	R1 (gifts to players who never return): a kind in config.mail.returnKinds (default
	{ "core_gift" }) sent through txApi.send is ESCROWED in the framework's shared atomic store
	(ctx.data.shared, framework Phase 2: one DataStore, UpdateAsync): a per-recipient record caps
	undelivered gifts (config.mail.giftCap, default 100, far below ProfileStore's 1000-message
	queue); over the cap the gift is refused and goes straight back to the sender (their
	mailbox, auto-claimed). A gift nobody collected within config.mail.returnAfterDays (default
	14, on the framework clock ctx.now) goes back to the sender's mailbox the same way, checked
	when the sender loads. Exactly one side wins (Escrow.luau).

	R3: on leave, outbox entries already saved are sent once more (best effort).
	R6: live admin console `mail dead <userId>` / `mail redeliver <userId> <id>` /
	`mail claim <userId> <id>` (ServerConfig.Mail.admins; the server console and Studio pass).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Delivery = require(script.Delivery)
local Escrow = require(script.Escrow)
local Gifts = require(script.Gifts)
local MailValidate = require(script.MailValidate)
local Outbox = require(script.Outbox)

local DAY = 86400
local FULL_CACHE_SECONDS = 60 -- a recipient whose escrow was full refuses new gifts this long

local Mail = {}

local ctx: any = nil
local delivery: any = nil
local outbox: any = nil
local escrow: any = nil
local leaving: { [any]: boolean } = {}
local sweeping: { [any]: boolean } = {}
local fullUntil: { [number]: number } = {}
local HOLD = table.freeze({})

local function encode(value: any): string
	return HttpService:JSONEncode(value)
end

-- the framework clock (ctx.now, Phase 2): tests advance it to reach the 14-day return
local function now(): number
	return ctx.now()
end

local function settings(): any
	local cfg = if ctx then ctx.config.mail else nil
	return if type(cfg) == "table" then cfg else {}
end

local function returnAfter(): number
	local days = settings().returnAfterDays
	return (if type(days) == "number" and days >= 0 then days else 14) * DAY
end

local function giftCap(): number
	local cap = settings().giftCap
	return if type(cap) == "number" and cap >= 1 then cap else 100
end

local function isReturnKind(kind: string): boolean
	local kinds = settings().returnKinds
	return type(kinds) == "table" and table.find(kinds, kind) ~= nil
end

local function isActive(player: any): boolean
	return ctx ~= nil and not leaving[player] and ctx.data.isLoaded(player)
end

local function mailOf(player: any): any
	if ctx == nil or not ctx.data.isLoaded(player) then
		return nil
	end
	local section = ctx.data.get(player)
	return if section then section.mail else nil
end

local function ensure(section: any): any
	if type(section.mail) ~= "table" then
		section.mail = { seen = {}, attempts = {}, dead = {} }
	end
	return section.mail
end

local function updateMail(player: any, fn: (mail: any) -> ()): boolean
	if ctx == nil or not ctx.data.isLoaded(player) then
		return false
	end
	local ok, result = pcall(ctx.data.update, player, function(section: any)
		fn(ensure(section))
	end)
	if not ok then
		ctx.log.warn("update failed: " .. tostring(result))
	end
	return ok and result == true
end

local function pushMailbox(player: any, held: boolean)
	local list = delivery.pending(player)
	ctx.replicate.set(player, "mailbox", list)
	if held then
		local n = #list
		pcall(ctx.net.feedback, player, "toast", `Mailbox: {n} item{if n == 1 then "" else "s"} waiting`)
	end
end

--------------------------------------------------------------------------------
-- Delivery (receiver side) and the outbox (sender side)
--------------------------------------------------------------------------------

delivery = Delivery.new({
	now = now,
	delay = function(seconds: number, fn: () -> ())
		task.delay(seconds, fn)
	end,
	isActive = isActive,
	getMail = mailOf,
	update = updateMail,
	analytics = function(player: any, name: string, value: number)
		ctx.analytics.custom(player, name, value)
	end,
	warn = function(message: string)
		if ctx then
			ctx.log.warn(message)
		end
	end,
	config = settings,
	onBoxChanged = pushMailbox,
	-- R1: who owns an escrowed gift? (the store is shared by every server)
	take = function(player: any, msg: any): string
		if escrow == nil then
			return "untracked"
		end
		return escrow.take(player.UserId, msg.id)
	end,
	consumed = function(player: any, msg: any)
		if escrow ~= nil then
			local userId = player.UserId
			task.spawn(function()
				for try = 1, 4 do
					if escrow.release(userId, msg.id) then
						return
					end
					task.wait(2 ^ try) -- a record left behind is pruned by a later reserve
				end
			end)
		end
	end,
})

local function storeSend(entry: any): boolean
	local message: { [string]: any } = {
		id = entry.key,
		kind = entry.kind,
		payload = entry.payload,
		sentAt = entry.at,
	}
	if entry.t then
		message.t = true
		message.from = entry.from
	end
	local sent = ctx.data.messages.send(entry.toUserId, message)
	if sent then
		ctx.data.messages.nudge(entry.toUserId)
	end
	return sent == true
end

-- A gift that comes back to its sender (refused by the cap, or not collected in time): held in
-- the sender's own mailbox under a new id, in ONE update with the removal of its outbox / sent
-- entry, then claimed at once (Inventory's core_gift handler puts the copy back).
local function handBack(player: any, entry: any, why: string): boolean
	local id = Gifts.backId(entry.key, why)
	local committed = updateMail(player, function(mail: any)
		Gifts.handBackInto(mail, entry, why, now())
	end)
	if not committed then
		return false
	end
	pushMailbox(player, false)
	pcall(
		ctx.net.feedback,
		player,
		"toast",
		if why == "full"
			then "Their mailbox is full: your gift came back"
			else "An unopened gift came back to you"
	)
	pcall(ctx.analytics.custom, player, if why == "full" then "MailGiftRefused" else "MailGiftReturned", 1)
	task.spawn(function()
		local ok, reason = delivery.claim(player, id)
		if not ok and reason ~= "still_held" then
			ctx.log.warn(`returned gift {id} stays in the mailbox: {tostring(reason)}`)
		end
	end)
	return true
end

outbox = Outbox.new({
	now = now,
	delay = function(seconds: number, fn: () -> ())
		task.delay(seconds, fn)
	end,
	isActive = isActive,
	getOutbox = function(player: any): any
		local mail = mailOf(player)
		return if mail then mail.outbox else nil
	end,
	save = function(player: any): boolean
		return ctx.data.saveAsync(player) == true
	end,
	send = storeSend,
	remove = function(player: any, key: string): boolean
		return updateMail(player, function(mail: any)
			Gifts.recordSent(mail, key) -- R1: an escrowed gift is remembered in `sent`
		end)
	end,
	backoff = function(attempt: number): number
		return Delivery.backoff(attempt, settings())
	end,
	warn = function(message: string)
		if ctx then
			ctx.log.warn(message)
		end
	end,
	-- R1 a: an escrowed gift reserves its slot in the recipient's record before it is sent
	prepare = function(player: any, entry: any): string
		local verdict = Gifts.prepare(escrow, entry, giftCap(), now() - 2 * returnAfter())
		if verdict == "full" then
			fullUntil[entry.toUserId] = now() + FULL_CACHE_SECONDS
			return if handBack(player, entry, "full") then "done" else "retry"
		end
		return verdict
	end,
})

-- R1 b: sender side. Every `sent` entry older than returnAfter is reclaimed from the
-- recipient's escrow record: won -> back to the sender's mailbox; the recipient took it ->
-- forgotten. A store error leaves it for the next sweep. YIELDS.
local function sweep(player: any)
	if escrow == nil or sweeping[player] or not isActive(player) then
		return
	end
	local list = Gifts.due(mailOf(player), now(), returnAfter())
	if #list == 0 then
		return
	end
	sweeping[player] = true
	for _, item in list do
		if not isActive(player) then
			break
		end
		local e = item.entry
		local verdict = Gifts.reclaim(escrow, item.key, e)
		if verdict == "return" then
			handBack(player, { key = item.key, kind = e.kind, payload = e.payload, at = e.at }, "returned")
		elseif verdict == "forget" then
			updateMail(player, function(m: any)
				if type(m.sent) == "table" then
					m.sent[item.key] = nil
				end
			end)
		end
	end
	sweeping[player] = nil
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

-- The outbox write behind txApi.send and the adapter's v1.2 sendInto. `mail` is the tx's
-- working copy of the section's `mail` field.
local function writeOutbox(
	mail: any,
	after: (fn: () -> ()) -> (),
	player: any,
	toUserId: any,
	kind: any,
	payload: any,
	key: any
): boolean
	local k = if key == nil then "mail-" .. HttpService:GenerateGUID(false) else key
	local tracked = escrow ~= nil and type(kind) == "string" and isReturnKind(kind)
	if tracked and type(toUserId) == "number" and (fullUntil[toUserId] or 0) > now() then
		ctx.log.warn(`send to {toUserId} refused: undelivered gift cap ({giftCap()}) reached`)
		return false -- refused before anything moves: the caller's tx is discarded, the item stays
	end
	local shim = { data = { mail = mail }, after = after }
	local ok, reason = Outbox.writeInto(shim, toUserId, kind, payload, k, now(), encode, function()
		task.spawn(outbox.flush, player)
	end)
	if not ok then
		ctx.log.warn(`txApi.send rejected: {reason}`)
		return false
	end
	if tracked then
		local entry = shim.data.mail.outbox[k]
		entry.t = true
		entry.from = player.UserId
	end
	return true
end

local function sendNow(userId: number, kind: string, payload: { [string]: any }, key: string?): boolean
	local ok, reason = MailValidate.message(userId, kind, payload, encode)
	if not ok then
		ctx.log.warn(`send rejected: {reason}`)
		return false
	end
	if key ~= nil and not MailValidate.key(key) then
		ctx.log.warn("send rejected: bad key")
		return false
	end
	return storeSend({
		toUserId = userId,
		kind = kind,
		payload = payload,
		key = key or HttpService:GenerateGUID(false),
		at = now(),
	})
end

local function onReceiveRaw(kind: string, handler: any): any
	assert(MailValidate.kind(kind), "Mail.onReceive: invalid kind")
	assert(type(handler) == "function", "Mail.onReceive: handler must be a function")
	local disconnect = delivery.register(kind, handler)
	local connection: any = { Connected = true }
	function connection.Disconnect(self: any)
		if self.Connected then
			self.Connected = false
			disconnect()
		end
	end
	return connection
end

--------------------------------------------------------------------------------
-- Console (R6: live, admins only)
--------------------------------------------------------------------------------

local function isAdmin(player: any): boolean
	if player == nil or ctx.isStudio then
		return true -- the server console / command bar, or Studio
	end
	local admins = ctx.serverConfig and ctx.serverConfig.admins
	return type(admins) == "table" and table.find(admins, player.UserId) ~= nil
end

local function target(userIdArg: any): any
	local userId = tonumber(userIdArg)
	if userId then
		return Players:GetPlayerByUserId(userId)
	end
	return nil
end

local function describe(player: any): string
	local mail = mailOf(player)
	local held = delivery.pending(player)
	local lines = { `{player.Name}: {#held} held` }
	for _, entry in held do
		table.insert(lines, `  held {entry.id} {entry.kind} heldAt={entry.heldAt}`)
	end
	for _, letter in (if mail and type(mail.dead) == "table" then mail.dead else {}) do
		table.insert(
			lines,
			`  dead {letter.id} {letter.kind} ({letter.attempts}x at {letter.at}) {letter.error}`
		)
	end
	local unsent = 0
	for _ in (if mail and type(mail.outbox) == "table" then mail.outbox else {}) do
		unsent += 1
	end
	table.insert(lines, `  outbox: {unsent} unsent`)
	return table.concat(lines, "\n")
end

local function registerConsole()
	ctx.console.register("dead", function(player: any, userIdArg: any): string
		if not isAdmin(player) then
			return "admins only"
		end
		local p = target(userIdArg)
		if p == nil or not ctx.data.isLoaded(p) then
			return "usage: mail dead <userId> (the player must be in this server)"
		end
		return describe(p)
	end, "mail dead <userId>: list held mail and dead letters (admins)")
	ctx.console.register("redeliver", function(player: any, userIdArg: any, id: any): string
		if not isAdmin(player) then
			return "admins only"
		end
		local p = target(userIdArg)
		if p == nil or type(id) ~= "string" then
			return "usage: mail redeliver <userId> <id>"
		end
		local ok, reason = delivery.replay(p, id)
		if not ok then
			return "refused: " .. tostring(reason)
		end
		local claimed, why = delivery.claim(p, id)
		if claimed then
			return `redelivered {id}`
		end
		return `{id} is back in the mailbox ({tostring(why)}); the player can claim it`
	end, "mail redeliver <userId> <id>: move a dead letter back and deliver it (admins)")
	ctx.console.register("claim", function(player: any, userIdArg: any, id: any): string
		if not isAdmin(player) then
			return "admins only"
		end
		local p = target(userIdArg)
		if p == nil or type(id) ~= "string" then
			return "usage: mail claim <userId> <id>"
		end
		local ok, reason = delivery.claim(p, id)
		return if ok then "claimed " .. id else "refused: " .. tostring(reason)
	end, "mail claim <userId> <id>: claim a held message for a player (admins)")
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Mail.init(context: any)
	ctx = context
	escrow = Escrow.new(ctx.data.shared) -- R1: always on (framework shared store)
	ctx.data.messages.onReceive(function(player: any, payload: any, processed: () -> ())
		task.spawn(delivery.deliver, player, payload, processed) -- deliver may yield (escrow)
	end)
	registerConsole()
end

function Mail.start(_context: any)
	ctx.data.onLoaded(function(player: any)
		leaving[player] = nil
		ctx.replicate.set(player, "mailbox", delivery.pending(player))
		outbox.markLoaded(player)
		task.spawn(outbox.flush, player) -- leftovers from an earlier session (yields)
		task.spawn(sweep, player)
	end)
	ctx.lifecycle.onPlayerRemoving(function(player: any)
		leaving[player] = true
		-- R3: one more best-effort send of what is already durable (no yield here)
		local saved = outbox.savedEntries(player)
		delivery.forget(player)
		outbox.forget(player)
		sweeping[player] = nil
		if #saved > 0 then
			task.spawn(function()
				for _, entry in saved do
					local e = entry :: any
					if
						not e.t
						or escrow == nil
						or escrow.reserve(e.toUserId, e.key, e.at, giftCap()) == "ok"
					then
						pcall(storeSend, e)
					end
				end
			end)
		end
	end)
	ctx.lifecycle.onShutdown(function()
		delivery.stop()
	end)
	local interval = settings().sweepSeconds
	ctx.lifecycle.onTick(if type(interval) == "number" and interval > 0 then interval else 3600, function()
		if escrow == nil then
			return
		end
		for _, player in Players:GetPlayers() do
			if isActive(player) then
				task.spawn(sweep, player)
			end
		end
	end)
	ctx.net.handle("RequestMailClaim", function(player: any, messageId: any)
		if not MailValidate.key(messageId) then
			return
		end
		local ok, reason = delivery.claim(player, messageId)
		if not ok and reason == "still_held" then
			ctx.net.feedback(player, "toast", "No room yet: free some space and try again")
		elseif not ok and reason == "error" then
			ctx.net.feedback(player, "toast", "Couldn't claim that right now")
		end
	end)
end

--------------------------------------------------------------------------------
-- Surfaces
--------------------------------------------------------------------------------

Mail.api = {
	send = function(userId: number, kind: string, payload: { [string]: any }, key: string?): boolean
		if MailValidate.isReserved(kind) then
			ctx.log.warn(`send rejected: kind '{kind}' is reserved`)
			return false
		end
		return sendNow(userId, kind, payload, key)
	end,
	onReceive = function(kind: string, handler: any): any
		if MailValidate.isReserved(kind) then
			error(`[Mail] onReceive: kind '{kind}' is reserved; use extensions.registerKind`, 2)
		end
		return onReceiveRaw(kind, handler)
	end,
	pending = function(player: any): { any }
		return delivery.pending(player)
	end,
	claim = function(player: any, messageId: string): (boolean, string?)
		return delivery.claim(player, messageId)
	end,
}

Mail.txApi = {
	send = function(
		tx: any,
		toUserId: number,
		kind: string,
		payload: { [string]: any },
		key: string?
	): boolean
		return writeOutbox(ensure(ctx.section(tx)), tx.after, tx.player, toUserId, kind, payload, key)
	end,
}

Mail.extensions = {
	registerKind = function(kind: string, claimFn: (any, any, any, any) -> boolean?)
		assert(type(claimFn) == "function", "Mail.registerKind(kind, claimFn): claimFn must be a function")
		onReceiveRaw(kind, function(player: any, payload: any, info: any): boolean
			local held = false
			local ok, committed = pcall(ctx.tx, player, function(tx: any)
				if claimFn(tx, player, payload, info) == false then
					held = true
					error(HOLD, 0) -- discard this tx
				end
			end)
			if held then
				return false
			end
			if not ok then
				error(committed, 0)
			end
			if committed ~= true then
				error(`[Mail] {kind}: claim tx did not commit (player not loaded)`, 0)
			end
			return true
		end)
	end,
}

-- v1.2 surface for the compat adapter only (packages/kits/compat/adapters/Social.luau; Phase 2
-- deletes it): bridged Inventory still calls send / onReceive with "core_" kinds and sendInto
-- with a v1.2 tx { player, data (flat view), after }.
Mail._compat = table.freeze({
	send = function(userId: number, kind: string, payload: { [string]: any }, key: string?): boolean
		return sendNow(userId, kind, payload, key)
	end,
	onReceive = onReceiveRaw,
	sendInto = function(tx12: any, toUserId: number, kind: string, payload: any, key: string): boolean
		local data = tx12.data
		if type(data.mail) ~= "table" then
			data.mail = { seen = {}, attempts = {}, dead = {} }
		end
		return writeOutbox(data.mail, tx12.after, tx12.player, toUserId, kind, payload, key)
	end,
	sweep = sweep,
})

return Mail
