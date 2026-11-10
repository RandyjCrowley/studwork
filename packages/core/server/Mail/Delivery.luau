--!strict
--[[
	Pure Mail delivery state machine (M3). OWNED BY AGENT C (core/v11-c-mail). No Roblox globals:
	every effect is injected, so Delivery.spec.luau drives it with fakes.

	Guarantees (at-least-once, idempotent by message id):
	  - id already in mail.seen          -> duplicate: processed(), handlers do not run.
	  - same id already in flight        -> waits for the first copy; consumed with it.
	  - no handler for the kind          -> pending (not consumed, no attempt counted); delivered
	                                        when a handler for that kind registers.
	  - every handler ok (no error, not false) -> one update: seen[id] = now, attempts[id] = nil,
	                                        seen pruned to MAX_SEEN (oldest first) -> processed().
	  - any handler failed               -> attempts[id] += 1 (persisted); retry after backoff while
	                                        the player's session lasts; after MAX_ATTEMPTS ->
	                                        dead letter (bounded MAX_DEAD), analytics, processed().
	  - session ended (leave/shutdown)   -> stop; processed() is never called for that message, so
	                                        ProfileStore re-delivers it next session.
]]

local MailValidate = require(script.Parent.MailValidate)

local Delivery = {}

Delivery.MAX_ATTEMPTS = 5 -- delivery attempts before a message is dead-lettered
Delivery.BACKOFF_BASE = 2 -- seconds before the first retry
Delivery.BACKOFF_FACTOR = 2 -- each retry waits FACTOR times longer
Delivery.BACKOFF_MAX = 60 -- seconds, cap for a single wait
Delivery.MAX_SEEN = 500 -- remembered processed ids per player
Delivery.MAX_DEAD = 25 -- kept dead letters per player
Delivery.MAX_ERROR_LENGTH = 200

export type Info = { id: string, kind: string, sentAt: number, attempt: number }
export type Handler = (player: any, payload: { [string]: any }, info: Info) -> boolean?

export type Deps = {
	now: () -> number, -- unix seconds
	delay: (seconds: number, fn: () -> ()) -> (),
	isActive: (player: any) -> boolean, -- online and profile loaded
	getMail: (player: any) -> any, -- current MailState (read only) or nil
	update: (player: any, fn: (mail: any) -> ()) -> boolean, -- mutate MailState, commit
	analytics: (player: any, name: string, value: number) -> (),
	warn: (message: string) -> (),
}

type Message = {
	id: string,
	kind: string,
	payload: { [string]: any },
	sentAt: number,
	waiters: { () -> () }, -- processed callbacks (several copies of the same id)
}

type Session = {
	player: any,
	inFlight: { [string]: Message },
	pending: { [string]: Message }, -- waiting for a handler
}

function Delivery.backoff(attempt: number): number
	return math.min(
		Delivery.BACKOFF_MAX,
		Delivery.BACKOFF_BASE * Delivery.BACKOFF_FACTOR ^ math.max(0, attempt - 1)
	)
end

-- Removes the oldest entries of `seen` until at most `max` remain.
function Delivery.pruneSeen(seen: { [string]: number }, max: number)
	local list = {}
	for id, at in seen do
		table.insert(list, { id = id, at = at })
	end
	if #list <= max then
		return
	end
	table.sort(list, function(a, b)
		if a.at == b.at then
			return a.id < b.id
		end
		return a.at < b.at
	end)
	for i = 1, #list - max do
		seen[list[i].id] = nil
	end
end

local function ensureMail(mail: any): any
	mail.seen = if type(mail.seen) == "table" then mail.seen else {}
	mail.attempts = if type(mail.attempts) == "table" then mail.attempts else {}
	mail.dead = if type(mail.dead) == "table" then mail.dead else {}
	return mail
end

function Delivery.new(deps: Deps)
	local self = {}
	local handlers: { [string]: { Handler } } = {}
	local sessions: { [any]: Session } = {}
	local stopped = false
	local warned: { [string]: boolean } = {}

	local function warnOnce(reason: string, detail: string)
		if not warned[reason] then
			warned[reason] = true
			deps.warn(`[Core.Mail] {detail} (further '{reason}' warnings suppressed)`)
		end
	end

	local function sessionFor(player: any): Session
		local s = sessions[player]
		if s == nil then
			s = { player = player, inFlight = {}, pending = {} }
			sessions[player] = s
		end
		return s
	end

	local function alive(s: Session): boolean
		return not stopped and sessions[s.player] == s and deps.isActive(s.player)
	end

	local function finish(s: Session, msg: Message)
		s.inFlight[msg.id] = nil
		for _, processed in msg.waiters do
			processed()
		end
	end

	local attempt: (s: Session, msg: Message) -> ()

	function attempt(s: Session, msg: Message)
		if not alive(s) then
			s.inFlight[msg.id] = nil
			return -- abandoned: re-delivered next session
		end
		local mail = deps.getMail(s.player)
		if type(mail) == "table" and type(mail.seen) == "table" and mail.seen[msg.id] ~= nil then
			finish(s, msg) -- processed meanwhile (e.g. by a copy)
			return
		end
		local list = handlers[msg.kind]
		if list == nil or #list == 0 then
			s.inFlight[msg.id] = nil
			s.pending[msg.id] = msg
			return
		end
		local previous = if type(mail) == "table" and type(mail.attempts) == "table"
			then tonumber(mail.attempts[msg.id]) or 0
			else 0
		local info: Info = { id = msg.id, kind = msg.kind, sentAt = msg.sentAt, attempt = previous + 1 }
		local failure: string? = nil
		for _, handler in table.clone(list) do
			local ok, result = pcall(handler, s.player, msg.payload, table.clone(info))
			if not ok then
				failure = tostring(result)
			elseif result == false then
				failure = "handler returned false"
			end
			if failure then
				break
			end
		end
		if not alive(s) then
			s.inFlight[msg.id] = nil
			return -- player left while a handler yielded
		end
		if failure == nil then
			local committed = deps.update(s.player, function(m: any)
				ensureMail(m)
				m.seen[msg.id] = deps.now()
				m.attempts[msg.id] = nil
				Delivery.pruneSeen(m.seen, Delivery.MAX_SEEN)
			end)
			if committed then
				finish(s, msg)
			else
				s.inFlight[msg.id] = nil -- couldn't record: leave it queued
			end
			return
		end
		local count = info.attempt
		local err = string.sub(failure, 1, Delivery.MAX_ERROR_LENGTH)
		deps.warn(`[Core.Mail] '{msg.kind}' {msg.id} attempt {count} failed: {err}`)
		if count >= Delivery.MAX_ATTEMPTS then
			local committed = deps.update(s.player, function(m: any)
				ensureMail(m)
				m.attempts[msg.id] = nil
				table.insert(m.dead, {
					id = msg.id,
					kind = msg.kind,
					payload = msg.payload,
					attempts = count,
					error = err,
					at = deps.now(),
				})
				while #m.dead > Delivery.MAX_DEAD do
					table.remove(m.dead, 1)
				end
			end)
			if not committed then
				s.inFlight[msg.id] = nil
				return
			end
			pcall(deps.analytics, s.player, "MailDeadLetter", count)
			finish(s, msg)
			return
		end
		local committed = deps.update(s.player, function(m: any)
			ensureMail(m)
			m.attempts[msg.id] = count
		end)
		if not committed then
			s.inFlight[msg.id] = nil
			return
		end
		deps.delay(Delivery.backoff(count), function()
			attempt(s, msg)
		end)
	end

	-- Normalises a raw ProfileStore message. Returns nil when malformed.
	local function parse(raw: any): Message?
		if type(raw) ~= "table" or not MailValidate.kind(raw.kind) or type(raw.payload) ~= "table" then
			return nil
		end
		local sentAt = if type(raw.sentAt) == "number" and raw.sentAt == raw.sentAt then raw.sentAt else 0
		local id = raw.id
		if id == nil then
			-- v1.0 message without an id: deterministic id so retries/dedupe still work.
			id = `legacy-{raw.kind}-{math.floor(sentAt)}`
		end
		if not MailValidate.key(id) then
			return nil
		end
		return { id = id, kind = raw.kind, payload = raw.payload, sentAt = sentAt, waiters = {} }
	end

	function self.deliver(player: any, raw: any, processed: () -> ())
		if stopped then
			return
		end
		local msg = parse(raw)
		if msg == nil then
			warnOnce("malformed", "malformed message consumed")
			processed()
			return
		end
		if not deps.isActive(player) then
			return -- player already left: stays queued for the next session (review N10)
		end
		local s = sessionFor(player)
		local mail = deps.getMail(player)
		if type(mail) == "table" and type(mail.seen) == "table" and mail.seen[msg.id] ~= nil then
			processed() -- duplicate
			return
		end
		local existing = s.inFlight[msg.id] or s.pending[msg.id]
		if existing then
			table.insert(existing.waiters, processed) -- same key twice: consumed together
			return
		end
		table.insert(msg.waiters, processed)
		s.inFlight[msg.id] = msg
		attempt(s, msg)
	end

	function self.register(kind: string, handler: Handler): () -> ()
		local list = handlers[kind] or {}
		handlers[kind] = list
		table.insert(list, handler)
		for _, s in table.clone(sessions) do
			for id, msg in table.clone(s.pending) do
				if msg.kind == kind and s.pending[id] == msg then
					s.pending[id] = nil
					s.inFlight[id] = msg
					attempt(s, msg)
				end
			end
		end
		return function()
			local index = table.find(list, handler)
			if index then
				table.remove(list, index)
			end
		end
	end

	-- Player left: stop retries, drop pending (ProfileStore keeps the messages queued).
	function self.forget(player: any)
		sessions[player] = nil
	end

	-- Server shutting down: nothing more is processed.
	function self.stop()
		stopped = true
		table.clear(sessions)
	end

	return self
end

return Delivery
