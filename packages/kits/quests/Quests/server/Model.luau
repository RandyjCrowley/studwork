--!strict
--[[
	Quests: the section rules (pure; no ctx, no yielding). The server part runs these on the
	working copy inside its own transactions, and on the frozen view for readers.
	docs/framework/kits/quests.md: "Periods, the deal and rerolls", "Claims", "Save data".

	env (built per call by the server part):
	  defs        { [questId]: Quest }   frozen, validated config entries
	  cfg         config.Quests
	  userId      number
	  now         number                 the module clock (framework clock + Studio timeshift)
	  period      { daily: number, weekly: number }   current period ids
	  window      (eventId) -> number?   the current event window key, nil while inactive
	  unlocked    (def, section) -> boolean           requires met
	  chains      { [chainId]: { questId } }
	  chainOf     { [questId]: chainId }
	  order       { [kind]: { questId } }   configured ids per kind, sorted
	  chainOrder  { chainId }               sorted

	  Model.target(o) / Model.objDone(o, v) / Model.complete(def, n) / Model.values(def, n)
	  Model.current(s, def, env, create) -> (entry?, slotKind?, setId?, slotIndex?)
	  Model.instances(s, env) -> { Instance }      board order: daily, weekly, chains, oneTime, repeatable, event
	  Model.pool(s, env, kind) -> { questId }      the eligible pool (not retired, requires met), sorted
	  Model.prune(s, env)                          config pruning (load tx)
	  Model.normalize(s, env, out)                 deals, event windows to waiting, pins
	  Model.findClaim(s, def, env) -> (target?, reason?)
	  Model.state(s, def, env) -> (status, entry?, extra)
	  Model.pushWaiting(s, entry, env)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Quests"):WaitForChild("shared")
local Deal = require(Shared:WaitForChild("Deal"))

local SLOT_KEY: { [string]: string } = { daily = "day", weekly = "week" }
local SLOT_KINDS = { "daily", "weekly" }
local PROG_KINDS = { "oneTime", "repeatable", "event" }
local VALUE_MAX = 1e9

local Model = {}

Model.SLOT_KEY = SLOT_KEY
Model.SLOT_KINDS = SLOT_KINDS

function Model.target(o: any): number
	if o.kind == "ack" then
		return 1
	end
	return o.target
end

function Model.isRank(o: any): boolean
	return o.kind == "threshold" and o.source == "leaderboardRank"
end

function Model.objDone(o: any, v: number): boolean
	if o.kind == "ack" then
		return v >= 1
	end
	if Model.isRank(o) then
		return v >= 1 and v <= o.target -- nil rank is stored as 0: not ranked = not done
	end
	return v >= o.target
end

function Model.complete(def: any, n: { number }): boolean
	for i, o in def.objectives do
		if not Model.objDone(o, n[i] or 0) then
			return false
		end
	end
	return true
end

-- a value read from a source, as stored: an integer 0..1e9
function Model.clampValue(v: any): number
	if type(v) ~= "number" or v ~= v or v <= 0 then
		return 0
	end
	return math.min(VALUE_MAX, math.floor(v))
end

-- objective values cut or padded to the quest's objective count (a fresh table)
function Model.values(def: any, n: any): { number }
	local out: { number } = {}
	for i = 1, #def.objectives do
		local v = if type(n) == "table" then n[i] else nil
		out[i] = if type(v) == "number" then v else 0
	end
	return out
end

function Model.zeros(def: any): { number }
	return Model.values(def, nil)
end

-- the first chain step not claimed (retired steps are skipped); nil when it is locked or the chain is done
function Model.chainStep(s: any, env: any, chainId: string?): string?
	local steps = if chainId then env.chains[chainId] else nil
	if steps == nil then
		return nil
	end
	for _, step in steps do
		local def = env.defs[step]
		if def == nil or def.retired or s.done[step] ~= nil then
			continue
		end
		return if env.unlocked(def, s) then step else nil
	end
	return nil
end

-- s.prog[id] for the current period/window `key` (nil = no key: chain, oneTime). A saved entry with
-- a smaller key belongs to an ended period: a fresh one replaces it (written only when `create`).
-- Keys only move forward: a saved key AHEAD of `key` stays current.
local function progEntry(s: any, def: any, key: number?, create: boolean): any
	local id = def.id
	local e = s.prog[id]
	if e ~= nil and key ~= nil and (type(e.p) ~= "number" or e.p < key) then
		e = nil
	end
	if e == nil then
		local fresh = { n = Model.zeros(def), s = 0, p = key }
		if create then
			s.prog[id] = fresh
		end
		return fresh
	end
	if create and #e.n ~= #def.objectives then
		e.n = Model.values(def, e.n)
	end
	return e
end

-- The quest's current instance: a slot of the saved set (whatever its period: callers check), or
-- the prog entry while the quest is active. nil when it has none (not dealt, locked, not granted,
-- claimed for good, outside its event window, retired).
function Model.current(s: any, def: any, env: any, create: boolean): (any, string?, number?, number?)
	local kind = def.kind
	local slotKey = SLOT_KEY[kind]
	if slotKey ~= nil then
		local set = s[slotKey]
		for i, slot in set.slots do
			if slot.q == def.id then
				return slot, kind, set.id, i
			end
		end
		return nil
	end
	if kind == "chain" then
		if s.done[def.id] ~= nil or Model.chainStep(s, env, env.chainOf[def.id]) ~= def.id then
			return nil
		end
		return progEntry(s, def, nil, create)
	end
	if def.retired then
		return nil
	end
	if kind == "event" then
		local key = env.window(def.event)
		if key == nil then
			return nil
		end
		return progEntry(s, def, key, create)
	end
	-- oneTime, repeatable
	if kind == "oneTime" and s.done[def.id] ~= nil then
		return nil
	end
	if not env.unlocked(def, s) then
		return nil
	end
	if def.offer == "grant" and s.granted[def.id] ~= true then
		return nil
	end
	if kind == "repeatable" then
		return progEntry(s, def, env.period[def.period], create)
	end
	return progEntry(s, def, nil, create)
end

export type Instance = {
	def: any,
	entry: any,
	slotKind: string?,
	setId: number?,
	slot: number?,
}

-- Every current instance in board order (read-only: entries may be virtual fresh ones).
function Model.instances(s: any, env: any): { Instance }
	local out: { Instance } = {}
	for _, kind in SLOT_KINDS do
		local set = s[SLOT_KEY[kind]]
		for i, slot in set.slots do
			local def = env.defs[slot.q]
			if def ~= nil and def.kind == kind then
				table.insert(out, { def = def, entry = slot, slotKind = kind, setId = set.id, slot = i })
			end
		end
	end
	for _, chainId in env.chainOrder do
		local step = Model.chainStep(s, env, chainId)
		if step ~= nil then
			local def = env.defs[step]
			table.insert(out, { def = def, entry = progEntry(s, def, nil, false) })
		end
	end
	for _, kind in PROG_KINDS do
		for _, id in env.order[kind] do
			local def = env.defs[id]
			local entry = Model.current(s, def, env, false)
			if entry ~= nil then
				table.insert(out, { def = def, entry = entry })
			end
		end
	end
	return out
end

function Model.pool(s: any, env: any, kind: string): { string }
	local out: { string } = {}
	for _, id in env.order[kind] do
		local def = env.defs[id]
		if not def.retired and env.unlocked(def, s) then
			table.insert(out, id)
		end
	end
	return out
end

local function weights(env: any): { [string]: number }
	if env.weights == nil then
		local w: { [string]: number } = {}
		for id, def in env.defs do
			w[id] = def.weight
		end
		env.weights = w
	end
	return env.weights
end

function Model.pushWaiting(s: any, entry: any, env: any)
	table.insert(s.waiting, entry)
	while #s.waiting > env.cfg.waitingMax do
		table.remove(s.waiting, 1) -- oldest dropped first
	end
end

-- A reroll / refill candidate list: the pool snapshotted at the deal (`seen` false entries) that
-- is still configured with this kind and not retired, minus the ids in other slots.
local function snapshotCandidates(set: any, env: any, kind: string): { string }
	local taken: { [string]: boolean } = {}
	for _, slot in set.slots do
		taken[slot.q] = true
	end
	local out: { string } = {}
	for id, shown in set.seen do
		local def = env.defs[id]
		if shown == false and not taken[id] and def ~= nil and def.kind == kind and not def.retired then
			table.insert(out, id)
		end
	end
	table.sort(out)
	return out
end
Model.snapshotCandidates = snapshotCandidates

-- Config pruning, the player's first tx on load (after the config-free sanitize).
function Model.prune(s: any, env: any)
	local defs = env.defs
	for _, kind in SLOT_KINDS do
		local set = s[SLOT_KEY[kind]]
		local current = set.id >= env.period[kind]
		for id in set.seen do
			local def = defs[id]
			if def == nil or def.kind ~= kind then
				set.seen[id] = nil
			end
		end
		for i = #set.slots, 1, -1 do
			local slot = set.slots[i]
			local def = defs[slot.q]
			if def ~= nil and def.kind == kind then
				slot.n = Model.values(def, slot.n)
			elseif slot.s >= 2 then
				-- a claimed slot whose quest was removed stays as a hidden placeholder until the
				-- period ends, so a removal can't hand out a second claim in that slot
				continue
			elseif not current then
				table.remove(set.slots, i) -- the next deal replaces this set anyway
			else
				local candidates = snapshotCandidates(set, env, kind)
				local seed = Deal.seed(env.userId, kind, set.id, env.cfg.poolVersion, i, slot.r)
				local id = Deal.pick(candidates, weights(env), seed)
				if id == nil then
					table.remove(set.slots, i)
				else
					set.seen[id] = true
					set.slots[i] = { q = id, n = Model.zeros(defs[id]), s = 0, r = slot.r }
				end
			end
		end
	end
	for id, e in s.prog do
		local def = defs[id]
		local keyed = def ~= nil and (def.kind == "repeatable" or def.kind == "event")
		local keyless = def ~= nil and (def.kind == "chain" or def.kind == "oneTime")
		if
			def == nil
			or not (keyed or keyless)
			or (keyed and type(e.p) ~= "number")
			or (keyless and (e.p ~= nil or e.k ~= nil))
		then
			s.prog[id] = nil -- removed, or a changed kind (the entry's shape tells the group apart)
		else
			e.n = Model.values(def, e.n)
		end
	end
	local waiting = {}
	for _, w in s.waiting do
		local def = defs[w.q]
		if def ~= nil and def.kind == w.k then
			table.insert(waiting, w)
		end
	end
	while #waiting > env.cfg.waitingMax do
		table.remove(waiting, 1)
	end
	s.waiting = waiting
	local pins = {}
	for _, id in s.pins do
		if defs[id] ~= nil and #pins < env.cfg.pinMax then
			table.insert(pins, id)
		end
	end
	s.pins = pins
	for id in s.granted do
		local def = defs[id]
		if def == nil or def.offer ~= "grant" or (def.kind ~= "oneTime" and def.kind ~= "repeatable") then
			s.granted[id] = nil
		end
	end
end

export type Out = {
	rotated: { { kind: string, periodId: number } },
	completed: { string },
	structural: boolean,
}

-- Deals (a period id larger than the saved one), ended event windows to waiting, stale pins.
function Model.normalize(s: any, env: any, out: Out)
	local defs = env.defs
	for _, kind in SLOT_KINDS do
		local key = SLOT_KEY[kind]
		local set = s[key]
		local cur = env.period[kind]
		if cur > set.id then
			local pool = Model.pool(s, env, kind)
			local ids = Deal.deal({
				userId = env.userId,
				kind = kind,
				periodId = cur,
				poolVersion = env.cfg.poolVersion,
				pool = pool,
				weights = weights(env),
				count = env.cfg[kind].count,
			})
			if #ids > 0 or #set.slots > 0 then
				for _, slot in set.slots do
					local def = defs[slot.q]
					if slot.s == 1 and def ~= nil and def.kind == kind then
						Model.pushWaiting(s, { q = slot.q, k = kind, p = set.id }, env)
					end
				end
				local seen: { [string]: boolean } = {}
				for _, id in pool do
					seen[id] = false
				end
				local slots = {}
				for _, id in ids do
					seen[id] = true
					table.insert(slots, { q = id, n = Model.zeros(defs[id]), s = 0, r = 0 })
				end
				s[key] = { id = cur, slots = slots, seen = seen }
				out.structural = true
				if #ids > 0 then
					table.insert(out.rotated, { kind = kind, periodId = cur })
				end
			end
		end
	end
	for _, id in env.order.event do
		local e = s.prog[id]
		if e ~= nil and e.s == 1 and type(e.p) == "number" then
			local key = env.window(defs[id].event)
			if key == nil or key > e.p then
				-- complete but unclaimed when its window ended: claimable from waiting; the
				-- window itself stays consumed (s = 2) so a server still inside it can't reopen it
				Model.pushWaiting(s, { q = id, k = "event", p = e.p }, env)
				e.s = 2
				out.structural = true
			end
		end
	end
	if #s.pins > 0 then
		local pins = {}
		for _, id in s.pins do
			local def = defs[id]
			if def ~= nil and Model.current(s, def, env, false) ~= nil and #pins < env.cfg.pinMax then
				table.insert(pins, id)
			end
		end
		if #pins ~= #s.pins then
			s.pins = pins
			out.structural = true
		end
	end
end

export type ClaimTarget = { where: string, entry: any, index: number? }

-- The instance a claim takes: the current one when complete and unclaimed, else `waiting` oldest
-- first. Reasons otherwise: not_active, not_complete, claimed, cap_reached.
function Model.findClaim(s: any, def: any, env: any): (ClaimTarget?, string?)
	local entry = Model.current(s, def, env, true)
	local capped = entry ~= nil and def.kind == "repeatable" and (entry.k or 0) >= def.cap
	if entry ~= nil and entry.s == 1 and not capped then
		return { where = if SLOT_KEY[def.kind] then "slot" else "prog", entry = entry }
	end
	for i, w in s.waiting do
		if w.q == def.id then
			return { where = "waiting", entry = w, index = i }
		end
	end
	if entry == nil then
		if (def.kind == "oneTime" or def.kind == "chain") and s.done[def.id] ~= nil then
			return nil, "claimed"
		end
		return nil, "not_active"
	end
	if capped then
		return nil, "cap_reached"
	end
	if entry.s == 2 then
		return nil, "claimed"
	end
	return nil, "not_complete"
end

-- A quest's status for `state`: locked | available | active | complete | claimed | inactive.
function Model.state(s: any, def: any, env: any): (string, any)
	local kind = def.kind
	local entry, slotKind = Model.current(s, def, env, false)
	if entry ~= nil then
		if entry.s == 2 or (kind == "repeatable" and (entry.k or 0) >= def.cap) then
			return "claimed", entry
		end
		return if entry.s == 1 then "complete" else "active", entry
	end
	if slotKind == nil and SLOT_KEY[kind] ~= nil then
		return if env.unlocked(def, s) then "inactive" else "locked", nil
	end
	if (kind == "oneTime" or kind == "chain") and s.done[def.id] ~= nil then
		return "claimed", nil
	end
	if kind == "event" or def.retired then
		return "inactive", nil
	end
	if not env.unlocked(def, s) then
		return "locked", nil
	end
	if kind == "chain" then
		return "locked", nil -- an earlier step isn't claimed yet
	end
	if def.offer == "grant" and s.granted[def.id] ~= true then
		return "available", nil
	end
	return "inactive", nil
end

return table.freeze(Model)
