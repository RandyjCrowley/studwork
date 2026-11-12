--!strict
--[[
	The per-recipient ledger entry (docs/framework/kits/notifications.md, "Scheduled sends"). Pure
	functions on one entry, run inside an atomic sorted-map `update` (so they may run more than once and
	never touch anything but their argument). The entry:

	  { d = UTC day of the last counted send, c = sends counted that day, l = last send time,
	    t = { [templateKey] = last send time }, q = { [key] = dueAt } (waiting entries),
	    r = { by = server id, untilAt }? (a live reservation: one send in flight) }

	A send is counted (`commit`) only after Open Cloud accepted it; a `reserve` holds the recipient
	while the request is in flight so two servers don't send to one player at once.
]]

local Ledger = {}

export type Entry = {
	d: number,
	c: number,
	l: number,
	t: { [string]: number },
	q: { [string]: number },
	r: { by: string, untilAt: number }?,
}

export type Rules = { perDay: number, minGapSeconds: number, cooldownSeconds: number }

local DAY = 86400
Ledger.DAY = DAY
Ledger.MIN_EXPIRY = 60
Ledger.BASE_EXPIRY = 2 * DAY
Ledger.MAX_EXPIRY = 3888000 -- MemoryStore's longest expiry

local function num(v: any): number
	return if type(v) == "number" and v == v then v else 0
end

local function copyNumbers(v: any): { [string]: number }
	local out: { [string]: number } = {}
	if type(v) == "table" then
		for k, x in v do
			if type(k) == "string" and type(x) == "number" and x == x then
				out[k] = x
			end
		end
	end
	return out
end

-- A clean copy of whatever the map held (nil = a recipient never seen).
function Ledger.normalize(old: any): Entry
	local e: Entry = { d = 0, c = 0, l = 0, t = {}, q = {}, r = nil }
	if type(old) ~= "table" then
		return e
	end
	e.d, e.c, e.l = num(old.d), num(old.c), num(old.l)
	e.t = copyNumbers(old.t)
	e.q = copyNumbers(old.q)
	local r = old.r
	if type(r) == "table" and type(r.by) == "string" and type(r.untilAt) == "number" then
		e.r = { by = r.by, untilAt = r.untilAt }
	end
	return e
end

function Ledger.waiting(e: Entry): number
	local n = 0
	for _ in e.q do
		n += 1
	end
	return n
end

-- Waiting keys older than the stale window are gone from the due list (it expired them); forget them.
function Ledger.prune(e: Entry, now: number, staleSeconds: number)
	for key, at in e.q do
		if at + staleSeconds < now then
			e.q[key] = nil
		end
	end
	local r = e.r
	if r ~= nil and r.untilAt <= now then
		e.r = nil
	end
end

-- Records a waiting key. Refuses "too_many" when the recipient already has `maxPerPlayer` OTHER keys.
function Ledger.schedule(
	old: Entry,
	key: string,
	at: number,
	now: number,
	maxPerPlayer: number,
	staleSeconds: number
): (Entry?, string?)
	local e = Ledger.normalize(old)
	Ledger.prune(e, now, staleSeconds)
	if e.q[key] == nil and Ledger.waiting(e) >= maxPerPlayer then
		return nil, "too_many"
	end
	e.q[key] = at
	return e, nil
end

-- Forgets a waiting key. Second result: whether it was there.
function Ledger.cancel(old: Entry, key: string): (Entry, boolean)
	local e = Ledger.normalize(old)
	local had = e.q[key] ~= nil
	e.q[key] = nil
	return e, had
end

-- May a send of `templateKey` go to this recipient now? (true) or (false, nextAt, reason): the time it
-- becomes allowed and "rate_limited" (day count, gap or another server's reservation) or "cooldown".
function Ledger.check(
	e: Entry,
	templateKey: string,
	rules: Rules,
	now: number,
	me: string
): (boolean, number?, string?)
	local nextAt: number? = nil
	local reason: string? = nil
	local function block(at: number, why: string)
		if nextAt == nil or at > nextAt then
			nextAt = at
		end
		if why == "rate_limited" or reason == nil then
			reason = why
		end
	end
	local today = now // DAY
	if e.d == today and e.c >= rules.perDay then
		block((today + 1) * DAY, "rate_limited")
	end
	if e.l > 0 and e.l + rules.minGapSeconds > now then
		block(e.l + rules.minGapSeconds, "rate_limited")
	end
	local last = e.t[templateKey]
	if last ~= nil and last + rules.cooldownSeconds > now then
		block(last + rules.cooldownSeconds, "cooldown")
	end
	local r = e.r
	if r ~= nil and r.by ~= me and r.untilAt > now then
		block(r.untilAt, "rate_limited")
	end
	if nextAt ~= nil then
		return false, nextAt, reason
	end
	return true, nil, nil
end

function Ledger.reserve(old: Entry, me: string, now: number, leaseSeconds: number): Entry
	local e = Ledger.normalize(old)
	e.r = { by = me, untilAt = now + leaseSeconds }
	return e
end

-- Counts an accepted send. Clears this server's reservation and the waiting key it served.
function Ledger.commit(old: Entry, key: string?, templateKey: string, now: number): Entry
	local e = Ledger.normalize(old)
	local today = now // DAY
	if e.d ~= today then
		e.d, e.c = today, 0
	end
	e.c += 1
	e.l = now
	e.t[templateKey] = now
	e.r = nil
	if key ~= nil then
		e.q[key] = nil
	end
	return e
end

-- Gives the reservation back (only if it is `me`'s). `dropKey`: also forget the waiting key.
function Ledger.release(old: Entry, me: string, key: string?, dropKey: boolean): Entry
	local e = Ledger.normalize(old)
	local r = e.r
	if r ~= nil and r.by == me then
		e.r = nil
	end
	if dropKey and key ~= nil then
		e.q[key] = nil
	end
	return e
end

-- Seconds the entry must live: at least two days (the day count and gap), the longest template
-- cooldown (`holdSeconds`) and every waiting entry's time plus the stale window.
function Ledger.expiry(
	e: Entry,
	extraAt: number?,
	now: number,
	staleSeconds: number,
	holdSeconds: number
): number
	local need = math.max(Ledger.BASE_EXPIRY, holdSeconds)
	for _, at in e.q do
		need = math.max(need, at + staleSeconds - now)
	end
	if extraAt ~= nil then
		need = math.max(need, extraAt + staleSeconds - now)
	end
	return math.clamp(math.ceil(need), Ledger.MIN_EXPIRY, Ledger.MAX_EXPIRY)
end

return Ledger
