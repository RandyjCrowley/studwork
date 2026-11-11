--!strict
--[[
	Pure gift escrow (known issue R1). No Roblox globals: the shared store is injected, so
	Escrow.spec.luau and GiftSoak.spec.luau drive it with an in-memory store.

	One record per RECIPIENT in a shared, durable, atomic store (requested framework primitive
	`ctx.data.shared.update(key, fn) -> (ok, value)`, DataStore UpdateAsync semantics):

	  key   "r:<recipientUserId>"
	  value { [giftKey]: { s = "p" | "c" | "r", at = sentAt } }
	        p = pending (in the recipient's ProfileStore queue, nobody took it yet)
	        c = claimed by the recipient (its server read the message; the recipient owns it)
	        r = returned (the sender took it back after returnAfter; the recipient must drop it)

	Every tracked gift is in the record from reserve() (before the message is sent) until the
	recipient's server has consumed the message (release()). So:
	  - the record size bounds how many tracked gifts sit in the recipient's queue: reserve()
	    refuses at `cap`, which keeps them far below ProfileStore's 1000-message queue limit
	    (R1 a: the sender keeps the item);
	  - exactly ONE side wins a pending gift, decided by an atomic transition out of "p":
	    the recipient (take: p -> c) or the sender after returnAfter (reclaim: p -> r). Both
	    transitions are idempotent for the side that won, so a crash between the transition and
	    the follow-up commit just repeats it (R1 b: return to sender, never duplicated, never lost).

	reserve(to, key, at, cap, staleBefore?) -> "ok" | "full" | "error"   (sender, before sending;
	                           "c" records older than staleBefore are dropped first: a release
	                           that failed must not hold a slot forever)
	take(to, key)              -> "mine" | "returned" | "untracked" | "error"   (recipient)
	reclaim(to, key)           -> "mine" | "claimed" | "error"  (sender, after returnAfter)
	release(to, key)           -> boolean                        (recipient, message consumed)
	count(value)               -> number of records (pure helper)
]]

local Escrow = {}

Escrow.PENDING = "p"
Escrow.CLAIMED = "c"
Escrow.RETURNED = "r"

export type Store = {
	-- Atomic read-modify-write of one key. fn gets the current value (nil when absent) and
	-- returns the new value (nil deletes). May yield. Returns (ok, newValue).
	update: (key: string, fn: (old: any) -> any) -> (boolean, any),
}

local function recordKey(toUserId: number): string
	return "r:" .. tostring(toUserId)
end
Escrow.recordKey = recordKey

function Escrow.count(value: any): number
	local n = 0
	if type(value) == "table" then
		for _ in value do
			n += 1
		end
	end
	return n
end

local function copy(value: any): { [string]: any }
	local out = {}
	if type(value) == "table" then
		for k, v in value do
			if type(k) == "string" and type(v) == "table" then
				out[k] = { s = v.s, at = v.at }
			end
		end
	end
	return out
end

local function run(store: Store, key: string, fn: (old: any) -> any): boolean
	local ok, result = pcall(store.update, key, fn)
	return ok and result == true
end

function Escrow.new(store: Store)
	local self = {}

	function self.reserve(
		toUserId: number,
		key: string,
		at: number,
		cap: number,
		staleBefore: number?
	): string
		local outcome = "error"
		local ok = run(store, recordKey(toUserId), function(old: any): any
			local value = copy(old)
			if staleBefore ~= nil then
				for k, entry in value do
					-- only CLAIMED records: a "c" whose message is still queued is just delivered
					-- as untracked later (the sender already forgot it); "r" must stay until the
					-- recipient drops its copy, or that copy would be delivered too
					if entry.s == Escrow.CLAIMED and k ~= key and (tonumber(entry.at) or 0) < staleBefore then
						value[k] = nil
					end
				end
			end
			if value[key] ~= nil then
				outcome = "ok" -- idempotent: a retried flush keeps its reservation (any state)
				return value
			end
			if Escrow.count(value) >= cap then
				outcome = "full"
				return value
			end
			value[key] = { s = Escrow.PENDING, at = at }
			outcome = "ok"
			return value
		end)
		return if ok then outcome else "error"
	end

	function self.take(toUserId: number, key: string): string
		local outcome = "error"
		local ok = run(store, recordKey(toUserId), function(old: any): any
			local value = copy(old)
			local entry = value[key]
			if entry == nil then
				outcome = "untracked"
			elseif entry.s == Escrow.RETURNED then
				outcome = "returned"
			else
				entry.s = Escrow.CLAIMED
				outcome = "mine"
			end
			return value
		end)
		return if ok then outcome else "error"
	end

	function self.reclaim(toUserId: number, key: string): string
		local outcome = "error"
		local ok = run(store, recordKey(toUserId), function(old: any): any
			local value = copy(old)
			local entry = value[key]
			if entry == nil or entry.s == Escrow.CLAIMED then
				-- consumed and released by the recipient, or claimed: the recipient owns it
				outcome = "claimed"
			else
				entry.s = Escrow.RETURNED
				outcome = "mine"
			end
			return value
		end)
		return if ok then outcome else "error"
	end

	function self.release(toUserId: number, key: string): boolean
		return run(store, recordKey(toUserId), function(old: any): any
			local value = copy(old)
			value[key] = nil
			return if next(value) == nil then nil else value
		end)
	end

	return self
end

-- In-memory Store (tests, the soak spec). `failEvery` (optional) makes every Nth update fail
-- without writing, to exercise the retry paths.
function Escrow.memoryStore(failEvery: number?): Store & { values: { [string]: any }, calls: number }
	local s: any = { values = {}, calls = 0 }
	function s.update(key: string, fn: (old: any) -> any): (boolean, any)
		s.calls += 1
		if failEvery and failEvery > 0 and s.calls % failEvery == 0 then
			error("memoryStore: injected failure", 0)
		end
		local new = fn(s.values[key])
		s.values[key] = new
		return true, new
	end
	return s
end

return Escrow
