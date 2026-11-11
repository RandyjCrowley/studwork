--!strict
--[[
	Pure Mail delivery state machine (M3, v1.2 mailbox N1). No Roblox globals: every effect is
	injected, so Delivery.spec.luau drives it with fakes.

	Guarantees (at-least-once, idempotent by message id):
	  - id already in mail.seen or mail.box -> duplicate: processed(), handlers do not run.
	  - same id already in flight        -> waits for the first copy; consumed with it.
	  - no handler for the kind          -> pending (not consumed, no attempt counted); delivered
	                                        when a handler for that kind registers.
	  - every handler ok (no error, not false) -> one update: seen[id] = now, attempts[id] = nil,
	                                        seen pruned to MAX_SEEN (oldest first) -> processed().
	  - a handler returned false (held)  -> one update: box[id] = { id, kind, payload, sentAt,
	                                        heldAt }, attempts[id] = nil -> processed(). No attempt
	                                        counted. Box already at mailboxCap -> nothing written,
	                                        NOT processed (stays queued in ProfileStore, offered
	                                        again next session), one warning.
	  - a handler threw                  -> attempts[id] += 1 (persisted); retry after backoff while
	                                        the player's session lasts; after maxAttempts ->
	                                        dead letter (bounded MAX_DEAD), analytics, processed().
	  - session ended (leave/shutdown)   -> stop; processed() is never called for that message, so
	                                        ProfileStore re-delivers it next session.
	Mailbox: pending(player) (copies, oldest heldAt first), claim(player, id) (re-runs handlers),
	replay(player, id) (dead letter -> mailbox, console tool). deps.onBoxChanged(player, held) runs
	after every committed box change. Tuning comes from deps.config() (config.Mail.mail).

	core-v1.3.0 (R1 / R7):
	  - a TRACKED message (raw.t == true: a gift kind sent through the escrow, Escrow.luau) first
	    asks deps.take(player, msg) who owns it (may yield): "returned" = the sender took it back
	    after returnAfter -> recorded as seen and consumed WITHOUT running the handlers; "error"
	    = the store is unreachable -> retried after backoff (left queued if the player leaves);
	    "mine" / "untracked" -> delivered as usual. deps.consumed(player, msg) runs once a tracked
	    message is consumed (ok, held, dead-lettered, returned or duplicate) to free its escrow
	    record.
	  - seen keeps every id younger than SEEN_TTL up to MAX_SEEN (2x ProfileStore's 1000-message
	    queue), and always the newest QUEUE_LIMIT ids, so any copy that can still be re-delivered
	    from the queue is recognised (R7).
]]

local MailValidate = require(script.Parent.MailValidate)

local Delivery = {}

-- Defaults (reliability rails; GameConfig.mail overrides them).
Delivery.MAX_ATTEMPTS = 10 -- handler ERRORS before a message is dead-lettered
Delivery.BACKOFF_BASE = 30 -- seconds before the first retry
Delivery.BACKOFF_FACTOR = 2 -- each retry waits FACTOR times longer
Delivery.BACKOFF_MAX = 900 -- seconds, cap for a single wait
Delivery.MAILBOX_CAP = 500 -- held messages per player (review R1: keeps gifts out of ProfileStore's 1000-message queue, which drops the oldest)
Delivery.QUEUE_LIMIT = 1000 -- ProfileStore MAX_MESSAGE_QUEUE: messages a store keeps per player
Delivery.MAX_SEEN = 2 * Delivery.QUEUE_LIMIT -- remembered processed ids per player (R7; was 500)
Delivery.SEEN_TTL = 60 * 86400 -- seconds a processed id is remembered beyond QUEUE_LIMIT (R7)
Delivery.MAX_DEAD = 100 -- kept dead letters per player (R6; was 25)
Delivery.MAX_ERROR_LENGTH = 200

export type Info = { id: string, kind: string, sentAt: number, attempt: number }
export type Handler = (player: any, payload: { [string]: any }, info: Info) -> boolean?

export type Settings = {
	maxAttempts: number,
	base: number,
	factor: number,
	max: number,
	mailboxCap: number,
}

export type Deps = {
	now: () -> number, -- unix seconds
	delay: (seconds: number, fn: () -> ()) -> (),
	isActive: (player: any) -> boolean, -- online and profile loaded
	getMail: (player: any) -> any, -- current MailState (read only) or nil
	update: (player: any, fn: (mail: any) -> ()) -> boolean, -- mutate MailState, commit
	analytics: (player: any, name: string, value: number) -> (),
	warn: (message: string) -> (),
	config: (() -> any)?, -- config.Mail.mail (or nil)
	onBoxChanged: ((player: any, held: boolean) -> ())?, -- after a committed box change
	take: ((player: any, msg: any) -> string)?, -- tracked message owner (may yield), see header
	consumed: ((player: any, msg: any) -> ())?, -- a tracked message was consumed
}

type Message = {
	id: string,
	kind: string,
	payload: { [string]: any },
	sentAt: number,
	tracked: boolean, -- escrowed gift (R1)
	from: number?, -- sender userId (tracked messages)
	waiters: { () -> () }, -- processed callbacks (several copies of the same id)
}

type Session = {
	player: any,
	inFlight: { [string]: Message },
	pending: { [string]: Message }, -- waiting for a handler
}

local function positive(v: any, default: number): number
	if type(v) == "number" and v == v and v > 0 and v ~= math.huge then
		return v
	end
	return default
end

-- Resolved tuning from a GameConfig.mail table (invalid/missing fields -> defaults).
function Delivery.settings(config: any): Settings
	local cfg = if type(config) == "table" then config else {}
	local backoff = if type(cfg.backoff) == "table" then cfg.backoff else {}
	return {
		maxAttempts = math.floor(positive(cfg.maxAttempts, Delivery.MAX_ATTEMPTS)),
		base = positive(backoff.base, Delivery.BACKOFF_BASE),
		factor = positive(backoff.factor, Delivery.BACKOFF_FACTOR),
		max = positive(backoff.max, Delivery.BACKOFF_MAX),
		mailboxCap = math.floor(positive(cfg.mailboxCap, Delivery.MAILBOX_CAP)),
	}
end

-- Wait before retry `attempt`: min(max, base * factor^(attempt-1)).
function Delivery.backoff(attempt: number, config: any?): number
	local st = Delivery.settings(config)
	return math.min(st.max, st.base * st.factor ^ math.max(0, attempt - 1))
end

function Delivery.boxCount(mail: any): number
	local n = 0
	if type(mail) == "table" and type(mail.box) == "table" then
		for _ in mail.box do
			n += 1
		end
	end
	return n
end

-- Copies of the mailbox entries, oldest heldAt first (tie: id).
function Delivery.listBox(mail: any): { any }
	local list = {}
	if type(mail) == "table" and type(mail.box) == "table" then
		for _, entry in mail.box do
			table.insert(list, table.clone(entry))
		end
	end
	table.sort(list, function(a: any, b: any): boolean
		if a.heldAt == b.heldAt then
			return a.id < b.id
		end
		return a.heldAt < b.heldAt
	end)
	return list
end

-- Removes the oldest entries of `seen` until at most `max` remain. With `now` and `ttl`, also
-- removes entries older than `ttl` seconds, but never below the newest `keep` ids (R7).
function Delivery.pruneSeen(
	seen: { [string]: number },
	max: number,
	now: number?,
	ttl: number?,
	keep: number?
)
	local list = {}
	for id, at in seen do
		table.insert(list, { id = id, at = at })
	end
	local floor = math.min(keep or max, max)
	local expiring = now ~= nil and ttl ~= nil and #list > floor
	if #list <= max and not expiring then
		return
	end
	table.sort(list, function(a, b)
		if a.at == b.at then
			return a.id < b.id
		end
		return a.at < b.at
	end)
	local drop = math.max(0, #list - max)
	if expiring then
		local cutoff = (now :: number) - (ttl :: number)
		local i = drop + 1
		while i <= #list - floor and (tonumber(list[i].at) or 0) < cutoff do
			drop = i
			i += 1
		end
	end
	for i = 1, drop do
		seen[list[i].id] = nil
	end
end

local function pruneSeenNow(seen: { [string]: number }, now: number)
	Delivery.pruneSeen(seen, Delivery.MAX_SEEN, now, Delivery.SEEN_TTL, Delivery.QUEUE_LIMIT)
end

-- Deterministic text of a JSON-safe value (keys sorted), for legacy ids (review N6).
local function canonical(value: any, depth: number?): string
	local d = depth or 0
	local t = type(value)
	if t ~= "table" then
		return t .. ":" .. tostring(value)
	end
	if d > 8 then
		return "deep"
	end
	local keys = {}
	for k in value do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, k in keys do
		table.insert(parts, tostring(k) .. "=" .. canonical(value[k], d + 1))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- 32-bit FNV-1a hash of a string, as 8 hex digits.
function Delivery.hash(text: string): string
	local h = 2166136261
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		-- h * 16777619 mod 2^32, exactly: 16777619 = 2^24 + 403 (doubles lose bits past 2^53; R15)
		h = (h * 403 + bit32.lshift(h, 24)) % 4294967296
	end
	return string.format("%08x", h)
end

-- Id of a v1.0 message (no id): kind + second + payload hash, so two same-kind messages sent
-- in the same second with different payloads no longer collide (review N6). Identical copies
-- (same kind, second and payload) still share an id, which is the safe direction.
function Delivery.legacyId(kind: string, sentAt: number, payload: any): string
	return `legacy-{kind}-{math.floor(sentAt)}-{Delivery.hash(canonical(payload))}`
end

local function ensureMail(mail: any): any
	mail.seen = if type(mail.seen) == "table" then mail.seen else {}
	mail.attempts = if type(mail.attempts) == "table" then mail.attempts else {}
	mail.dead = if type(mail.dead) == "table" then mail.dead else {}
	return mail
end

local function inSet(mail: any, field: string, id: string): boolean
	return type(mail) == "table" and type(mail[field]) == "table" and mail[field][id] ~= nil
end

-- Runs every handler (pcall) until one fails. Returns "ok" | "held" | "error", error text.
local function runHandlers(list: { Handler }, player: any, payload: any, info: Info): (string, string?)
	for _, handler in table.clone(list) do
		local ok, result = pcall(handler, player, payload, table.clone(info))
		if not ok then
			return "error", tostring(result)
		elseif result == false then
			return "held", nil
		end
	end
	return "ok", nil
end

function Delivery.new(deps: Deps)
	local self = {}
	local handlers: { [string]: { Handler } } = {}
	local sessions: { [any]: Session } = {}
	local claiming: { [any]: { [string]: boolean } } = {}
	local stopped = false
	local warned: { [string]: boolean } = {}

	local function settings(): Settings
		local get = deps.config
		return Delivery.settings(if get then get() else nil)
	end

	local function warnOnce(reason: string, detail: string)
		if not warned[reason] then
			warned[reason] = true
			deps.warn(`[Core.Mail] {detail} (further '{reason}' warnings suppressed)`)
		end
	end

	local function boxChanged(player: any, held: boolean)
		local fn = deps.onBoxChanged
		if fn then
			local ok, err = pcall(function()
				fn(player, held)
			end)
			if not ok then
				deps.warn("[Core.Mail] mailbox change hook failed: " .. tostring(err))
			end
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

	local function consumed(player: any, msg: Message)
		local fn = deps.consumed
		if fn and msg.tracked then
			local ok, err = pcall(function()
				fn(player, msg)
			end)
			if not ok then
				deps.warn("[Core.Mail] consumed hook failed: " .. tostring(err))
			end
		end
	end

	local function finish(s: Session, msg: Message)
		s.inFlight[msg.id] = nil
		for _, processed in msg.waiters do
			processed()
		end
		consumed(s.player, msg)
	end

	local attempt: (s: Session, msg: Message) -> ()
	local resolve: (s: Session, msg: Message, try: number) -> ()

	local function hold(s: Session, msg: Message, mail: any)
		local st = settings()
		if Delivery.boxCount(mail) >= st.mailboxCap then
			-- Not processed: ProfileStore keeps it queued and offers it again next session.
			s.inFlight[msg.id] = nil
			warnOnce("mailbox_full", `mailbox full ({st.mailboxCap}): '{msg.kind}' {msg.id} left queued`)
			return
		end
		local committed = deps.update(s.player, function(m: any)
			ensureMail(m)
			local box = if type(m.box) == "table" then m.box else {}
			box[msg.id] = {
				id = msg.id,
				kind = msg.kind,
				payload = msg.payload,
				sentAt = msg.sentAt,
				heldAt = deps.now(),
			}
			m.box = box
			m.attempts[msg.id] = nil
		end)
		if committed then
			finish(s, msg)
			boxChanged(s.player, true)
		else
			s.inFlight[msg.id] = nil -- couldn't record: leave it queued
		end
	end

	function attempt(s: Session, msg: Message)
		if not alive(s) then
			s.inFlight[msg.id] = nil
			return -- abandoned: re-delivered next session
		end
		local mail = deps.getMail(s.player)
		if inSet(mail, "seen", msg.id) or inSet(mail, "box", msg.id) then
			finish(s, msg) -- processed or held meanwhile (e.g. by a copy)
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
		local outcome, failure = runHandlers(list, s.player, msg.payload, info)
		if not alive(s) then
			s.inFlight[msg.id] = nil
			return -- player left while a handler yielded
		end
		if outcome == "ok" then
			local committed = deps.update(s.player, function(m: any)
				ensureMail(m)
				m.seen[msg.id] = deps.now()
				m.attempts[msg.id] = nil
				pruneSeenNow(m.seen, deps.now())
			end)
			if committed then
				finish(s, msg)
			else
				s.inFlight[msg.id] = nil -- couldn't record: leave it queued
			end
			return
		elseif outcome == "held" then
			hold(s, msg, deps.getMail(s.player))
			return
		end
		local st = settings()
		local count = info.attempt
		local err = string.sub(failure or "error", 1, Delivery.MAX_ERROR_LENGTH)
		deps.warn(`[Core.Mail] '{msg.kind}' {msg.id} attempt {count} failed: {err}`)
		if count >= st.maxAttempts then
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
		deps.delay(Delivery.backoff(count, if deps.config then deps.config() else nil), function()
			attempt(s, msg)
		end)
	end

	-- Tracked (escrowed) message: who owns it? (R1) Yields in deps.take.
	function resolve(s: Session, msg: Message, try: number)
		local take = deps.take :: (any, any) -> string
		local ok, owner = pcall(take, s.player, msg)
		if not alive(s) then
			s.inFlight[msg.id] = nil
			return -- left meanwhile: re-delivered next session
		end
		if not ok or owner == "error" then
			deps.warn(`[Core.Mail] escrow lookup for {msg.id} failed (try {try}): {tostring(owner)}`)
			deps.delay(Delivery.backoff(try, if deps.config then deps.config() else nil), function()
				if alive(s) and s.inFlight[msg.id] == msg then
					resolve(s, msg, try + 1)
				end
			end)
			return
		end
		if owner == "returned" then
			-- the sender took it back after returnAfter: drop this copy without running handlers
			local committed = deps.update(s.player, function(m: any)
				ensureMail(m)
				m.seen[msg.id] = deps.now()
				m.attempts[msg.id] = nil
				pruneSeenNow(m.seen, deps.now())
			end)
			if committed then
				finish(s, msg)
			else
				s.inFlight[msg.id] = nil
			end
			return
		end
		attempt(s, msg)
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
			id = Delivery.legacyId(raw.kind, sentAt, raw.payload)
		end
		if not MailValidate.key(id) then
			return nil
		end
		return {
			id = id,
			kind = raw.kind,
			payload = raw.payload,
			sentAt = sentAt,
			tracked = raw.t == true,
			from = if type(raw.from) == "number" then raw.from else nil,
			waiters = {},
		}
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
		if inSet(mail, "seen", msg.id) or inSet(mail, "box", msg.id) then
			processed() -- duplicate (already processed, or waiting in the mailbox)
			consumed(player, msg)
			return
		end
		local existing = s.inFlight[msg.id] or s.pending[msg.id]
		if existing then
			table.insert(existing.waiters, processed) -- same key twice: consumed together
			return
		end
		table.insert(msg.waiters, processed)
		s.inFlight[msg.id] = msg
		if msg.tracked and deps.take then
			resolve(s, msg, 1)
		else
			attempt(s, msg)
		end
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

	-- The player's mailbox (copies), oldest first. {} when not loaded.
	function self.pending(player: any): { any }
		if not deps.isActive(player) then
			return {}
		end
		return Delivery.listBox(deps.getMail(player))
	end

	-- Re-runs the handlers of a held message. (true) = delivered and removed from the box.
	function self.claim(player: any, id: any): (boolean, string?)
		if type(id) ~= "string" then
			return false, "not_found"
		end
		local locks = claiming[player]
		if locks and locks[id] then
			return false, "busy"
		end
		if stopped or not deps.isActive(player) then
			return false, "not_loaded"
		end
		local mail = deps.getMail(player)
		local entry = if type(mail) == "table" and type(mail.box) == "table" then mail.box[id] else nil
		if entry == nil then
			return false, "not_found"
		end
		local list = handlers[entry.kind]
		if list == nil or #list == 0 then
			return false, "no_handler"
		end
		local lockTable: { [string]: boolean } = locks or {}
		claiming[player] = lockTable
		lockTable[id] = true
		local previous = if type(mail.attempts) == "table" then tonumber(mail.attempts[id]) or 0 else 0
		local info: Info = { id = id, kind = entry.kind, sentAt = entry.sentAt, attempt = previous + 1 }
		local outcome, failure = runHandlers(list, player, entry.payload, info)
		lockTable[id] = nil
		if stopped or not deps.isActive(player) then
			return false, "not_loaded"
		end
		if outcome == "held" then
			return false, "still_held"
		elseif outcome == "error" then
			local err = string.sub(failure or "error", 1, Delivery.MAX_ERROR_LENGTH)
			deps.warn(`[Core.Mail] claim '{entry.kind}' {id} attempt {info.attempt} failed: {err}`)
			deps.update(player, function(m: any)
				ensureMail(m)
				if type(m.box) == "table" and m.box[id] ~= nil then
					m.attempts[id] = info.attempt
				end
			end)
			return false, "error" -- stays in the box: a held message is never dead-lettered
		end
		local committed = deps.update(player, function(m: any)
			ensureMail(m)
			if type(m.box) == "table" then
				m.box[id] = nil
			end
			m.seen[id] = deps.now()
			m.attempts[id] = nil
			pruneSeenNow(m.seen, deps.now())
		end)
		if not committed then
			return false, "error"
		end
		boxChanged(player, false)
		return true, nil
	end

	-- Console tool: moves a dead letter back into the mailbox (ignores mailboxCap).
	function self.replay(player: any, id: any): (boolean, string?)
		if stopped or not deps.isActive(player) then
			return false, "not_loaded"
		end
		local mail = deps.getMail(player)
		local found = false
		if type(mail) == "table" and type(mail.dead) == "table" then
			for _, letter in mail.dead do
				if letter.id == id then
					found = true
				end
			end
		end
		if not found or type(id) ~= "string" then
			return false, "not_found"
		end
		if inSet(mail, "box", id) then
			return false, "already_held"
		end
		local committed = deps.update(player, function(m: any)
			ensureMail(m)
			for i = #m.dead, 1, -1 do
				local letter = m.dead[i]
				if letter.id == id then
					table.remove(m.dead, i)
					local box = if type(m.box) == "table" then m.box else {}
					box[id] = {
						id = id,
						kind = letter.kind,
						payload = letter.payload,
						sentAt = letter.at,
						heldAt = deps.now(),
					}
					m.box = box
					m.attempts[id] = nil
					break
				end
			end
		end)
		if not committed then
			return false, "error"
		end
		boxChanged(player, true)
		return true, nil
	end

	-- Player left: stop retries, drop pending (ProfileStore keeps the messages queued).
	function self.forget(player: any)
		sessions[player] = nil
		claiming[player] = nil
	end

	-- Server shutting down: nothing more is processed.
	function self.stop()
		stopped = true
		table.clear(sessions)
	end

	return self
end

return Delivery
