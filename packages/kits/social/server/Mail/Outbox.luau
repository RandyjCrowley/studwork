--!strict
--[[
	Pure mail outbox flusher (v1.2, Mail.sendInto). No Roblox globals: every effect is injected,
	so Outbox.spec.luau drives it with fakes.

	An outbox entry (PlayerData.mail.outbox[key] = { toUserId, kind, payload, key, at }) is written
	by Mail.sendInto in the SAME Data.update as its cause (Inventory.sendGift removes the item).
	flush(player) then, for the SENDER:
	  1. if any entry was written this session and is not known to be saved yet: deps.save(player)
	     (Data.saveAsync). The message must never leave before the update that created it is
	     durable, or a crash would restore the item AND deliver it (duplicate). Entries present at
	     load (markLoaded) are already durable.
	  2. deps.send(entry) for every entry, oldest first (MessageAsync with id = key, so a resend
	     is a duplicate the receiver drops); on success deps.remove(player, key) (Data.update).
	  3. any failure (save, send) -> retry the whole flush after backoff while the sender is
	     online; attempts reset after a fully successful flush. Offline -> nothing happens; the
	     entries stay saved and are flushed on the next load (Data.onLoaded).
	A crash between send and the save of the removal re-sends on next load: same key, receiver
	dedupes (mail.seen / mail.box), so the copy is never delivered twice.
	One flush runs per player at a time; a flush requested meanwhile runs right after it.
]]

local MailValidate = require(script.Parent.MailValidate)

local Outbox = {}

export type Entry = {
	toUserId: number,
	kind: string,
	payload: { [string]: any },
	key: string,
	at: number,
}

export type Deps = {
	now: () -> number,
	delay: (seconds: number, fn: () -> ()) -> (),
	isActive: (player: any) -> boolean, -- online and profile loaded
	getOutbox: (player: any) -> { [string]: Entry }?, -- live (read only)
	save: (player: any) -> boolean, -- persist the profile now (may yield)
	send: (entry: Entry) -> boolean, -- MessageAsync to entry.toUserId (may yield)
	remove: (player: any, key: string) -> boolean, -- delete outbox[key] in one Data.update
	backoff: (attempt: number) -> number, -- seconds before retry n
	warn: (message: string) -> (),
}

type Session = {
	player: any,
	running: boolean,
	again: boolean,
	attempt: number,
	timer: boolean, -- a retry is scheduled
	confirmed: { [string]: boolean }, -- keys known to be in a successful save
}

-- Entries sorted oldest first (tie: key).
function Outbox.sorted(outbox: { [string]: Entry }?): { Entry }
	local list = {}
	if type(outbox) == "table" then
		for _, entry in outbox do
			table.insert(list, entry)
		end
	end
	table.sort(list, function(a, b)
		if a.at == b.at then
			return a.key < b.key
		end
		return a.at < b.at
	end)
	return list
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

-- Mail.sendInto: validates like Mail.send (+ required key), writes tx.data.mail.outbox[key] and
-- queues onCommit (the flush) with tx.after. Returns false and writes nothing when invalid or
-- when the key is already in the outbox.
function Outbox.writeInto(
	tx: any,
	toUserId: any,
	kind: any,
	payload: any,
	key: any,
	now: number,
	encode: (value: any) -> string,
	onCommit: () -> ()
): (boolean, string?)
	local ok, reason = MailValidate.message(toUserId, kind, payload, encode)
	if not ok then
		return false, reason
	end
	if not MailValidate.key(key) then
		return false, "bad key"
	end
	local mail = tx.data.mail
	if type(mail) ~= "table" then
		mail = { seen = {}, attempts = {}, dead = {} }
		tx.data.mail = mail
	end
	local outbox = if type(mail.outbox) == "table" then mail.outbox else {}
	if outbox[key] ~= nil then
		return false, "duplicate key"
	end
	outbox[key] = {
		toUserId = toUserId,
		kind = kind,
		payload = deepCopy(payload),
		key = key,
		at = now,
	}
	mail.outbox = outbox
	tx.after(onCommit)
	return true, nil
end

function Outbox.new(deps: Deps)
	local self = {}
	local sessions: { [any]: Session } = {}

	local function sessionFor(player: any): Session
		local s = sessions[player]
		if s == nil then
			s = {
				player = player,
				running = false,
				again = false,
				attempt = 0,
				timer = false,
				confirmed = {},
			}
			sessions[player] = s
		end
		return s
	end

	local function alive(s: Session): boolean
		return sessions[s.player] == s and deps.isActive(s.player)
	end

	-- One pass. Returns true when every entry was sent (or there was nothing to send).
	local function pass(s: Session): boolean
		local list = Outbox.sorted(deps.getOutbox(s.player))
		if #list == 0 then
			return true
		end
		local unsaved = false
		for _, entry in list do
			if not s.confirmed[entry.key] then
				unsaved = true
			end
		end
		if unsaved then
			local ok, saved = pcall(deps.save, s.player)
			if not (ok and saved == true) then
				return false
			end
			for _, entry in list do
				s.confirmed[entry.key] = true
			end
		end
		local allSent = true
		for _, entry in list do
			if not alive(s) then
				return false
			end
			local ok, sent = pcall(deps.send, entry)
			if ok and sent == true then
				local removed = deps.remove(s.player, entry.key)
				if not removed then
					allSent = false -- sent but still listed: the resend is a duplicate (same key)
				end
			else
				allSent = false
			end
		end
		return allSent
	end

	local flush: (player: any) -> ()

	function flush(player: any)
		if not deps.isActive(player) then
			return
		end
		local s = sessionFor(player)
		if s.running then
			s.again = true
			return
		end
		s.running = true
		local ok = true
		repeat
			s.again = false
			local passOk, result = pcall(pass, s)
			ok = passOk and result == true
			if not passOk then
				deps.warn("[Core.Mail] outbox flush failed: " .. tostring(result))
			end
		until not s.again or not alive(s)
		s.running = false
		if not alive(s) then
			return
		end
		if ok then
			s.attempt = 0
			return
		end
		s.attempt += 1
		if not s.timer then
			s.timer = true
			deps.delay(deps.backoff(s.attempt), function()
				s.timer = false
				if alive(s) then
					flush(player)
				end
			end)
		end
	end

	self.flush = flush

	-- Data loaded: everything in the outbox came from the store, so it is already durable.
	function self.markLoaded(player: any)
		local s = sessionFor(player)
		for _, entry in Outbox.sorted(deps.getOutbox(player)) do
			s.confirmed[entry.key] = true
		end
	end

	-- Player left / server shutting down: stop retrying (entries stay saved for the next load).
	function self.forget(player: any)
		sessions[player] = nil
	end

	function self.attempts(player: any): number
		local s = sessions[player]
		return if s then s.attempt else 0
	end

	return self
end

return Outbox
