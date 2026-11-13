--!strict
--[[
	Quests: the server part (docs/framework/kits/quests.md). A part factory: Server.new() builds a
	fresh part per runtime (the framework loader calls it), so each harness or server keeps its own
	state.

	  api: progress, claim, reroll, active, state, def, grant, pin, signals
	       (Progressed, Completed, Claimed, Rotated)
	  extensions (init only): registerSource(name, spec), registerReward(handler, fn)
	  actions (net.blink): claimQuest, rerollQuest, pinQuest, ackQuest
	  console: quests state [userId] (Studio or admins); quests progress <key> <amount> [userId],
	           quests complete <questId> [userId], quests timeshift <seconds> (Studio only)

	How it fits together:
	  - The save section is changed only inside Quests' own transactions (questTx): the load tx
	    (config pruning + the deal), the fold, claim, reroll, grant, pin and the rotation tick.
	    Each one folds this player's pending progress first; the section rules are ./Model.luau.
	  - `progress` (and the sources, and `ackQuest`) only add to memory (`pend` deltas, `vals`
	    absolute value-source reads) against an index over the player's active quests, rebuilt
	    from the committed section after every Quests commit. It never opens a tx, so it is safe
	    inside any game tx or reward handler. A completing increment flags the player: the 1 s
	    tick folds flagged players (one tx each); everyone else folds every `foldSeconds` on their
	    own phase, on leave and on shutdown.
	  - A refused claim/reroll/grant/pin sets the reason in an upvalue and calls tx.retryLater()
	    (nothing written, nothing logged); pending progress taken into a discarded tx goes back to
	    memory. Only a custom reward handler can raise: that claim runs through pcall(ctx.tx).
	  - Replication: extra.board after a commit that changed it; extra.prog (live values incl.
	    pending) at most every `replicateSeconds`; extra.questOdds once at start.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Shared = Modules:WaitForChild("Quests"):WaitForChild("shared")
local Period = require(Shared:WaitForChild("Period"))
local Deal = require(Shared:WaitForChild("Deal"))
local QuestTypes = require(Shared:WaitForChild("Types"))
local Validate = require(Shared:WaitForChild("Validate"))
local SignalTable = require(script.SignalTable)
local Model = require(script.Model)

local function kit(name: string): any
	return require(Modules:WaitForChild(name):WaitForChild("module")) :: any
end

local Economy = kit("Economy")
local Items = kit("Items")
local Inventory = kit("Inventory")
local Rarity = kit("Rarity")
local Rebirth = kit("Rebirth")
local Streak = kit("Streak")
local Leaderboards = kit("Leaderboards")

-- optional modules by name (Validate's `enabled` map, built-in sources' `needs`)
local OPTIONAL: { [string]: any } = {
	Economy = Economy,
	Items = Items,
	Inventory = Inventory,
	Rarity = Rarity,
	Rebirth = Rebirth,
	Streak = Streak,
	Leaderboards = Leaderboards,
}

-- the dependency signals the built-in sources read (kit-contract.md)
local SOURCE_SIGNALS: { [string]: { string } } = {
	Economy = { "CurrencyChanged" },
	Inventory = { "ItemAdded", "ItemRemoved" },
	Rebirth = { "Rebirthed" },
	Streak = { "StreakAdvanced" },
	Leaderboards = { "BoardRefreshed" },
}

-- the value source each module's signals re-read (polled instead when a signal can't be reached)
local VALUE_SOURCE_OF: { [string]: string } = {
	Economy = "currency",
	Inventory = "itemOwned",
	Rebirth = "rebirths",
	Streak = "streakDay",
	Leaderboards = "leaderboardRank",
}

local SIGNAL_NAMES = { "Progressed", "Completed", "Claimed", "Rotated" }
local REWARD_PREFIX = "Quests:"
local SLOT_KEY = Model.SLOT_KEY

local EMPTY: { any } = table.freeze({})

local function deepFreeze(v: any): any
	if type(v) ~= "table" or table.isfrozen(v) then
		return v
	end
	for _, child in v do
		deepFreeze(child)
	end
	return table.freeze(v)
end

local function startsWith(s: any, prefix: string): boolean
	return type(s) == "string" and string.sub(s, 1, #prefix) == prefix
end

type TxOpts = {
	prune: boolean?,
	normalize: boolean?,
	protected: string?, -- the quest id: a custom reward handler may raise
}

local function userIdOf(player: any): any
	return player.UserId
end

local Server = {}

function Server.new(): any
	local ctx: any = nil
	local cfg: any = nil
	local defs: { [string]: QuestTypes.Quest } = {}
	local ackKeys: { [string]: boolean } = {}
	local sources: { [string]: QuestTypes.SourceSpec } = {}
	local rewards: { [string]: QuestTypes.RewardFn } = {}
	local players: { [any]: boolean } = {} -- loaded on this server
	local clockShift = 0 -- `quests timeshift` (Studio only, in memory, this server)
	local initDone = false
	local signals: any = SignalTable.new()
	local part: any = {}

	-- static facts from the config (built in init)
	local order: { [string]: { string } } = {}
	local chainOf: { [string]: string } = {}
	local chainOrder: { string } = {}
	local hasQuests = false
	local needsRequires = false -- a quest's `requires` reads rebirths or items: re-index on their signals
	local scheduled: { [string]: boolean } = {} -- event ids with a schedule

	-- runtime state
	local mem: { [any]: any } = {}
	local windows: { [string]: number } = {} -- eventId -> window key (from EventStarted)
	local rotateQueue: { any } = {}
	local rotateSet: { [any]: boolean } = {}
	local lastDay: number? = nil
	local lastWeek: number? = nil
	local nextPoll = 0
	local primaryCurrency: string? = nil

	--------------------------------------------------------------------------
	-- Helpers
	--------------------------------------------------------------------------

	-- the module's period clock: the framework clock plus the Studio timeshift
	local function now(): number
		return ctx.now() + clockShift
	end

	local function isOn(): boolean
		if cfg == nil or cfg.flag == nil then
			return true
		end
		local ok, on = pcall(ctx.flags.isOn, cfg.flag)
		return ok and on == true
	end

	-- A live Player is an Instance (type "userdata"); spec players are userdata proxies or tables.
	local function isPlayer(player: any): boolean
		if type(player) ~= "userdata" and type(player) ~= "table" then
			return false
		end
		local ok, userId = pcall(userIdOf, player)
		return ok and type(userId) == "number"
	end

	local function needPlayer(fn: string, player: any)
		if not isPlayer(player) then
			error(`Quests.{fn}: player must be a Player`, 3)
		end
	end

	local function needString(fn: string, what: string, value: any)
		if type(value) ~= "string" then
			error(`Quests.{fn}: {what} must be a string`, 3)
		end
	end

	-- the common refusal before anything else: flag off, then not loaded
	local function refusal(player: any): string?
		if not isOn() then
			return "disabled"
		end
		if not players[player] or mem[player] == nil or not ctx.data.isLoaded(player) then
			return "not_loaded"
		end
		return nil
	end

	local function isAdmin(player: any): boolean
		if player == nil or ctx.isStudio then
			return true
		end
		local admins = ctx.serverConfig and ctx.serverConfig.admins
		return type(admins) == "table" and table.find(admins, player.UserId) ~= nil
	end

	local function findPlayer(userId: any): any
		local id = tonumber(userId)
		for p in players do
			if id == nil or p.UserId == id then
				return p
			end
		end
		return nil
	end

	local function periodOf(kind: string, t: number): number
		return Period.id(kind, t, cfg.utcOffsetHours, cfg.weekStartsOn)
	end

	-- the current period ids, recomputed only when the module clock moved (progress's hot path)
	local periodAt: number? = nil
	local periodNow: { [string]: number } = { daily = 0, weekly = 0 }
	local function currentPeriod(kind: string): number
		local t = now()
		if t ~= periodAt then
			periodAt = t
			periodNow.daily = periodOf("daily", t)
			periodNow.weekly = periodOf("weekly", t)
		end
		return periodNow[kind]
	end

	-- the current window key of an event, nil while it isn't active
	local function windowOf(eventId: string): number?
		local ok, active = pcall(ctx.events.isActive, eventId)
		if not ok or not active then
			return nil
		end
		local key = windows[eventId]
		if key ~= nil then
			return key
		end
		-- active but its start wasn't seen here: a scheduled window derives from the clock on
		-- every server; this fallback (the UTC day) is what a hand-triggered one uses anyway
		return Period.windowKey(now(), false)
	end

	local function makeEnv(player: any): any
		local t = now()
		local cache: { [string]: any } = {}
		local function ownsItem(itemId: string): boolean
			if cache.items == nil then
				local owned: { [string]: boolean } = {}
				local okList, list = pcall(function(): any
					return ctx.deps[Inventory].list(player)
				end)
				if okList and type(list) == "table" then
					for _, inst in list do
						owned[inst.itemId] = true
					end
				end
				cache.items = owned
			end
			return cache.items[itemId] == true
		end
		local function rebirths(): number
			if cache.rebirths == nil then
				local okCount, n = pcall(function(): any
					return ctx.deps[Rebirth].count(player)
				end)
				cache.rebirths = if okCount and type(n) == "number" then n else 0
			end
			return cache.rebirths
		end
		return {
			defs = defs,
			cfg = cfg,
			userId = player.UserId,
			now = t,
			period = { daily = periodOf("daily", t), weekly = periodOf("weekly", t) },
			window = windowOf,
			chains = cfg.chains,
			chainOf = chainOf,
			order = order,
			chainOrder = chainOrder,
			unlocked = function(def: any, s: any): boolean
				local req = def.requires
				if req == nil then
					return true
				end
				if req.quests ~= nil then
					for _, id in req.quests do
						if s.done[id] == nil then
							return false
						end
					end
				end
				if req.rebirths ~= nil then
					if not ctx.isEnabled(Rebirth) or rebirths() < req.rebirths then
						return false
					end
				end
				if req.items ~= nil then
					if not ctx.isEnabled(Inventory) then
						return false
					end
					for _, itemId in req.items do
						if not ownsItem(itemId) then
							return false
						end
					end
				end
				return true
			end,
		}
	end

	--------------------------------------------------------------------------
	-- Memory: pending progress and the index
	--------------------------------------------------------------------------

	local function newMem(player: any): any
		local t = now()
		local fold = cfg.foldSeconds
		return {
			player = player,
			pend = {}, -- [questId] = { [objective] = delta }   counters, add sources, acks
			vals = {}, -- [questId] = { [objective] = value }   value sources (absolute)
			pendKey = {}, -- [questId] = the instance key the pending belongs to (set id / p)
			hasPending = false,
			flagged = false,
			nextFold = t + (player.UserId % math.max(1, math.floor(fold))) + 1, -- staggered phase
			quests = {}, -- [questId] = { def, base, complete, slotKind?, key? }
			index = {}, -- counter key -> { entry }
			ackIndex = {}, -- ack key -> { entry }
			srcIndex = {}, -- source name -> { entry }
			acc = {}, -- counter key -> amount not yet spread over the key's entries (see settle)
			cap = {}, -- counter key -> the smallest amount left to a target among its live entries
			accAny = false,
			capDay = -1, -- the periods `cap` and `acc` were computed in
			capWeek = -1,
			anyDirty = false, -- live values may have changed since the last send
			nextSend = -math.huge, -- the earliest module time of the next extra.prog send
			progIds = nil, -- the last extra.progIds (frozen; reused until the set changes)
			progParts = nil, -- the last send's per-quest strings (which quests moved)
			progText = nil, -- the last extra.prog
			progLast = {}, -- the last send's values, flat (to tell which quests moved)
			progNums = {}, -- scratch
			progShape = true,
			boardSig = nil,
			stale = true,
			ready = false, -- the load tx (pruning) has committed
		}
	end

	--[[
		Counter progress is O(1) per `progress` call: while no live entry on a key can reach its
		target (`cap[key]`, the smallest amount left among the key's live entries, marked
		`e.inCap`), the amount only adds to `acc[key]`, and every `inCap` entry's live value is
		its committed base + pend + acc[key]. `settle` spreads `acc` into `pend` before anything
		reads `pend` (a live-value read, a tx, a rebuild, a period change); a call that reaches a
		cap settles and takes the exact per-entry path (clamped, completion flagged).
	]]
	local function settle(m: any)
		if not m.accAny then
			return
		end
		m.accAny = false
		local pend, cap = m.pend, m.cap
		for key, a in m.acc do
			for _, e in m.index[key] or {} do
				if e.inCap then
					local id = e.q.id
					local p = pend[id]
					if p == nil then
						p = {}
						pend[id] = p
					end
					p[e.oi] = (p[e.oi] or 0) + a
					m.pendKey[id] = e.q.key
				end
			end
			local c = cap[key]
			if c ~= nil then
				cap[key] = c - a -- every inCap entry moved by exactly a (< its amount left)
			end
		end
		table.clear(m.acc)
	end

	-- settle, then forget every cap (pend or the index is about to change outside the fast path)
	local function resetCaps(m: any)
		settle(m)
		table.clear(m.cap)
	end

	-- the cap of one counter key: marks each entry's inCap; math.huge when nothing can move
	local function capOf(m: any, list: any): number
		local cap = math.huge
		local pend = m.pend
		for _, e in list do
			local q = e.q
			e.inCap = false
			if q.complete or (q.slotKind ~= nil and q.key < periodNow[q.slotKind]) then
				continue
			end
			local p = pend[q.id]
			local left = e.target - ((q.base[e.oi] or 0) + (if p ~= nil then p[e.oi] or 0 else 0))
			if left > 0 then
				e.inCap = true
				if left < cap then
					cap = left
				end
			end
		end
		return cap
	end

	local function live(m: any, q: any, oi: number): number
		if m.accAny then
			settle(m)
		end
		local v = m.vals[q.def.id]
		if v ~= nil and v[oi] ~= nil then
			return v[oi]
		end
		local p = m.pend[q.def.id]
		return (q.base[oi] or 0) + (if p ~= nil then p[oi] or 0 else 0)
	end

	local function liveValues(m: any, q: any): { number }
		local out: { number } = {}
		for oi = 1, #q.def.objectives do
			out[oi] = live(m, q, oi)
		end
		return out
	end

	local function liveComplete(m: any, q: any): boolean
		for oi, o in q.def.objectives do
			if not Model.objDone(o, live(m, q, oi)) then
				return false
			end
		end
		return true
	end

	local function markDirty(m: any)
		m.anyDirty = true
	end

	local function sameValues(a: any, b: any): boolean
		if a == nil or b == nil or #a ~= #b then
			return false
		end
		for i = 1, #a do
			if a[i] ~= b[i] then
				return false
			end
		end
		return true
	end

	-- Rebuild the index over the player's active quests from the committed section.
	local function rebuild(player: any)
		local m = mem[player]
		if m == nil or not ctx.data.isLoaded(player) then
			return
		end
		settle(m) -- the accumulated amounts belong to the entries of the old index
		local view = ctx.data.get(player)
		local env = makeEnv(player)
		local quests, index, ackIndex, srcIndex = {}, {}, {}, {}
		for _, inst in Model.instances(view, env) do
			local def = inst.def
			local entry = inst.entry
			local q = {
				def = def,
				id = def.id,
				base = Model.values(def, entry.n),
				complete = entry.s ~= 0 or (def.kind == "repeatable" and (entry.k or 0) >= def.cap),
				slotKind = inst.slotKind,
				key = if inst.slotKind then inst.setId else entry.p,
			}
			quests[def.id] = q
			if not q.complete then
				for oi, o in def.objectives do
					local e = { q = q, oi = oi, o = o, target = Model.target(o), inCap = false }
					local map, key
					if o.kind == "counter" then
						map, key = index, o.key
						q.counters = q.counters or {}
						q.counters[oi] = e
					elseif o.kind == "ack" then
						map, key = ackIndex, o.key
					else
						map, key = srcIndex, o.source
					end
					local list = map[key]
					if list == nil then
						list = {}
						map[key] = list
					end
					table.insert(list, e)
				end
			end
		end
		m.quests, m.index, m.ackIndex, m.srcIndex = quests, index, ackIndex, srcIndex
		table.clear(m.cap)
		m.stale = false
		m.progShape = true
		-- pending of quests that are no longer tracked (or complete) is dropped
		for _, map in { m.pend, m.vals } do
			for id in map do
				local q = quests[id]
				if q == nil or q.complete then
					map[id] = nil
				end
			end
		end
		for id in m.pendKey do
			if m.pend[id] == nil and m.vals[id] == nil then
				m.pendKey[id] = nil
			end
		end
		m.hasPending = next(m.pend) ~= nil or next(m.vals) ~= nil
		m.anyDirty = true -- the next send compares the new set and values with the last one
	end

	-- add `amount` to one indexed objective (capped at its target); true when it moved
	local function addTo(m: any, e: any, amount: number): boolean
		local q = e.q
		local id = q.def.id
		if q.complete then
			return false
		end
		if q.slotKind ~= nil and q.key < currentPeriod(q.slotKind) then
			return false -- the ended period's set, until this player's rotation
		end
		local cur = live(m, q, e.oi)
		if cur >= e.target then
			return false
		end
		local add = math.min(amount, e.target - cur)
		resetCaps(m) -- a counter objective moved outside the fast path (console fill)
		local p = m.pend[id]
		if p == nil then
			p = {}
			m.pend[id] = p
		end
		p[e.oi] = (p[e.oi] or 0) + add
		m.pendKey[id] = q.key
		m.hasPending = true
		markDirty(m)
		if cur + add >= e.target and liveComplete(m, q) then
			m.flagged = true
		end
		return true
	end

	-- a value source read for one indexed threshold objective
	local function setValue(m: any, e: any, value: any)
		local q = e.q
		if q.complete then
			return
		end
		local v = Model.clampValue(value)
		if v == live(m, q, e.oi) then
			return
		end
		local id = q.def.id
		local vals = m.vals[id]
		if vals == nil then
			vals = {}
			m.vals[id] = vals
		end
		vals[e.oi] = v
		m.pendKey[id] = q.key
		m.hasPending = true
		markDirty(m)
		if Model.objDone(e.o, v) and liveComplete(m, q) then
			m.flagged = true
		end
	end

	local function readSource(player: any, name: string, params: any): any
		local p = if type(params) == "table" then params else {}
		local ok, value = pcall(function(): any
			if name == "currency" then
				return ctx.deps[Economy].balance(player, p.currency)
			elseif name == "rebirths" then
				return ctx.deps[Rebirth].count(player)
			elseif name == "streakDay" then
				return ctx.deps[Streak].get(player).day
			elseif name == "itemOwned" then
				local n = 0
				for _, inst in ctx.deps[Inventory].list(player) do
					if inst.itemId == p.item then
						n += 1
					end
				end
				return n
			elseif name == "leaderboardRank" then
				return (ctx.deps[Leaderboards].rank(player, p.board))
			end
			local spec = sources[name]
			return if spec ~= nil then spec.read(player) else nil
		end)
		return if ok then value else nil
	end

	-- re-read value sources for this player's active threshold objectives (one source, or all)
	local function readValues(player: any, only: string?, board: string?)
		local m = mem[player]
		if m == nil then
			return
		end
		for name, list in m.srcIndex do
			if only ~= nil and name ~= only then
				continue
			end
			for _, e in list do
				if e.o.kind ~= "threshold" then
					continue
				end
				if board ~= nil and (type(e.o.params) ~= "table" or e.o.params.board ~= board) then
					continue
				end
				setValue(m, e, readSource(player, name, e.o.params))
			end
		end
	end

	-- an add source's amount to every matching active `source` objective
	local function addSource(player: any, name: string, amount: number, matches: (params: any) -> boolean)
		local m = mem[player]
		if m == nil or not isOn() then
			return
		end
		local list = m.srcIndex[name]
		if list == nil then
			return
		end
		for _, e in list do
			if e.o.kind == "source" and matches(if type(e.o.params) == "table" then e.o.params else {}) then
				addTo(m, e, amount)
			end
		end
	end

	--------------------------------------------------------------------------
	-- Replication
	--------------------------------------------------------------------------

	local function signature(v: any): string
		if type(v) ~= "table" then
			return tostring(v)
		end
		local keys = {}
		for k in v do
			table.insert(keys, tostring(k))
		end
		table.sort(keys)
		local parts = {}
		for _, k in keys do
			local value = v[k]
			if value == nil then
				value = v[tonumber(k)]
			end
			table.insert(parts, k .. "=" .. signature(value))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end

	local function buildBoard(player: any): any
		local view = ctx.data.get(player)
		local env = makeEnv(player)
		local board: any = { list = {}, waiting = {}, pins = table.clone(view.pins) }
		for _, inst in Model.instances(view, env) do
			local def, entry = inst.def, inst.entry
			if inst.slotKind ~= nil then
				local key = SLOT_KEY[inst.slotKind]
				local set = board[key]
				if set == nil then
					set = {
						id = inst.setId,
						endsAt = Period.endsAt(inst.slotKind, inst.setId :: number, cfg.utcOffsetHours),
						slots = {},
					}
					board[key] = set
				end
				table.insert(set.slots, { q = def.id, s = entry.s, r = entry.r })
			else
				local row: any = { q = def.id, s = entry.s }
				if def.kind == "repeatable" then
					row.k = entry.k or 0
					row.cap = def.cap
					if row.k >= def.cap then
						row.s = 2
					end
				end
				if type(entry.p) == "number" then
					row.p = entry.p
				end
				table.insert(board.list, row)
			end
		end
		for _, w in view.waiting do
			if defs[w.q] ~= nil then
				table.insert(board.waiting, { q = w.q, k = w.k, p = w.p })
			end
		end
		return board
	end

	local function publishBoard(player: any)
		local m = mem[player]
		if m == nil or not ctx.data.isLoaded(player) then
			return
		end
		local board = buildBoard(player)
		local sig = signature(board)
		if sig ~= m.boardSig then
			m.boardSig = sig
			ctx.replicate.set(player, "board", board)
		end
	end

	-- The staggered per-player cadence: with replicateSeconds R > 1 a player's sends sit on its own
	-- grid (phase userId % ceil(R), step R), so the players' sends spread over the ticks instead of
	-- all landing on one; consecutive sends are always at least R apart. R <= 1: every R seconds.
	local function nextSendAt(player: any, t: number): number
		local r = cfg.replicateSeconds
		if r <= 1 then
			return t + r
		end
		local phase = player.UserId % math.ceil(r)
		return phase + math.ceil((t + r - phase) / r) * r
	end

	--[[
		Live values on the wire, two keys:
		  extra.progIds = { questId }  the tracked quests, sorted; set only when that set changes
		  extra.prog    = "3;0,12;7"   per quest of progIds, in order, its live values joined by
		                               "," and the quests by ";" (whole numbers)
		A string is copied and diffed as one value, where a table per quest (or one flat array)
		costs the framework a table copy and a walk per send. Nothing is sent when nothing moved;
		Progressed fires once per send with the ids whose values moved.
	]]
	local function sendProg(player: any)
		local m = mem[player]
		if m == nil then
			return
		end
		local quests, pend, vals, acc = m.quests, m.pend, m.vals, m.acc
		local prevIds, prevParts = m.progIds, m.progParts
		local ids = prevIds
		if m.progShape or ids == nil then
			local list: { string } = {}
			for id in quests do
				table.insert(list, id)
			end
			table.sort(list)
			if prevIds == nil or not sameValues(list, prevIds) then
				ids = table.freeze(list)
			end
			m.progShape = false
		end
		m.anyDirty = false
		m.nextSend = nextSendAt(player, now())
		-- the same set as the last send: compare each value with the last one sent (in place)
		local same = ids == prevIds and prevParts ~= nil
		local last: { number } = m.progLast
		if not same then
			last = {}
			m.progLast = last
		end
		local parts: { string } = table.create(#(ids :: { string }))
		local moved: { string } = {}
		local nums: { number } = m.progNums -- scratch for one quest's values
		local k = 0
		for i, id in ids :: { string } do
			local q = quests[id]
			local base, p, set, ce = q.base, pend[id], vals[id], q.counters
			local n = #base
			local changed = false
			for oi = 1, n do
				local value = if set ~= nil then set[oi] else nil
				if value == nil then
					value = base[oi] + (if p ~= nil then p[oi] or 0 else 0)
					local e = if ce ~= nil then ce[oi] else nil
					if e ~= nil and e.inCap then
						value += acc[e.o.key] or 0
					end
				end
				k += 1
				if last[k] ~= value then
					last[k] = value
					changed = true
				end
				nums[oi] = value :: number
			end
			if changed or not same then
				parts[i] = if n == 1 then tostring(nums[1]) else table.concat(nums, ",", 1, n)
				if same then
					table.insert(moved, id)
				end
			else
				parts[i] = (prevParts :: { string })[i]
			end
		end
		if same and #moved == 0 then
			return -- nothing moved since the last send
		end
		local text = table.concat(parts, ";")
		if not same then
			-- a new set: a quest moved when its part differs from the last send's (one new on the
			-- board: when it has progress not yet committed)
			local before: { [string]: string } = {}
			if prevIds ~= nil and prevParts ~= nil then
				for i, id in prevIds do
					before[id] = prevParts[i]
				end
			end
			for i, id in ids :: { string } do
				local old = before[id]
				if old ~= nil then
					if parts[i] ~= old then
						table.insert(moved, id)
					end
				elseif pend[id] ~= nil or vals[id] ~= nil or (quests[id].counters ~= nil and m.accAny) then
					table.insert(moved, id)
				end
			end
		end
		m.progIds, m.progParts = ids, parts
		if ids ~= prevIds then
			ctx.replicate.set(player, "progIds", ids)
		end
		if text ~= m.progText then
			m.progText = text
			ctx.replicate.set(player, "prog", text)
		end
		if #moved > 0 then
			signals.Progressed:Fire(player, table.freeze(moved))
		end
	end

	local function publishEmpty(player: any)
		local m = mem[player]
		if m ~= nil then
			m.boardSig = nil
			m.progIds, m.progParts, m.progText = nil, nil, nil
			m.progShape = true
		end
		ctx.replicate.set(player, "board", {})
		ctx.replicate.set(player, "progIds", {})
		ctx.replicate.set(player, "prog", "")
	end

	--------------------------------------------------------------------------
	-- Transactions
	--------------------------------------------------------------------------

	-- the pending progress taken into a tx goes back to memory when that tx doesn't commit
	local function restore(m: any, pend: any, vals: any, keys: any)
		resetCaps(m)
		for id, p in pend do
			local cur = m.pend[id]
			if cur == nil then
				m.pend[id] = p
			else
				for oi, d in p do
					cur[oi] = (cur[oi] or 0) + d
				end
			end
			m.hasPending = true
		end
		for id, v in vals do
			local cur = m.vals[id]
			if cur == nil then
				m.vals[id] = v
			else
				for oi, value in v do
					if cur[oi] == nil then
						cur[oi] = value
					end
				end
			end
			m.hasPending = true
		end
		for id, key in keys do
			if m.pendKey[id] == nil then
				m.pendKey[id] = key
			end
		end
	end

	-- fold pending progress into the working copy; completions go to out.completed
	local function applyPending(s: any, env: any, pend: any, vals: any, keys: any, out: any)
		local ids: { string } = {}
		for id in pend do
			table.insert(ids, id)
		end
		for id in vals do
			if pend[id] == nil then
				table.insert(ids, id)
			end
		end
		table.sort(ids)
		for _, id in ids do
			local def = defs[id]
			if def == nil then
				continue
			end
			local entry, slotKind, setId = Model.current(s, def, env, true)
			-- every skip below means the index is out of date: rebuild it after the commit
			if entry == nil or entry.s ~= 0 then
				out.structural = true
				continue
			end
			if def.kind == "repeatable" and (entry.k or 0) >= def.cap then
				out.structural = true
				continue
			end
			local key = if slotKind ~= nil then setId else entry.p
			if keys[id] ~= key then
				out.structural = true
				continue -- pending of an ended period's or window's instance
			end
			if
				slotKind ~= nil
				and env.now >= Period.endsAt(slotKind, setId :: number, cfg.utcOffsetHours)
			then
				out.structural = true
				continue -- nothing completes after its period
			end
			local n = Model.values(def, entry.n)
			local p, v = pend[id], vals[id]
			for oi, o in def.objectives do
				if v ~= nil and v[oi] ~= nil then
					n[oi] = v[oi]
				elseif p ~= nil and p[oi] ~= nil then
					n[oi] = math.min(Model.target(o), n[oi] + p[oi])
				end
			end
			entry.n = n
			out.newValues[id] = n
			if Model.complete(def, n) then
				entry.s = 1
				table.insert(out.completed, id)
			end
		end
	end

	--[[
		One Quests transaction for `player`: (pruning), (the deal), the fold, then `body`.
		body(tx, s, env, out) sets out.refusal (and calls tx.retryLater) to refuse.
		Returns (committed, out). After a commit: the index is rebuilt, the board and live
		values are published, Rotated / Completed fire, then autoClaim runs (its own claim tx).
	]]
	local function questTx(player: any, opts: TxOpts, body: ((any, any, any, any) -> ())?): (boolean, any)
		local m = mem[player]
		local out: any =
			{ rotated = {}, completed = {}, structural = false, refusal = nil, after = {}, newValues = {} }
		if m == nil then
			out.refusal = "not_loaded"
			return false, out
		end
		resetCaps(m) -- every accumulated amount is in pend, which the tx takes
		local pend, vals, keys = m.pend, m.vals, m.pendKey
		local wasFlagged = m.flagged
		m.pend, m.vals, m.pendKey, m.hasPending = {}, {}, {}, false
		m.flagged = false
		local started = false
		local function fn(tx: any)
			started = true
			local s = ctx.section(tx)
			local env = makeEnv(player)
			if opts.prune then
				Model.prune(s, env)
			end
			if opts.normalize then
				Model.normalize(s, env, out)
			end
			applyPending(s, env, pend, vals, keys, out)
			if body ~= nil then
				body(tx, s, env, out)
			end
		end
		local ok, committed = pcall(ctx.tx, player, fn)
		if not ok then
			restore(m, pend, vals, keys)
			m.flagged = m.flagged or wasFlagged
			if opts.protected == nil or not started then
				error(committed, 0)
			end
			ctx.log.warn(
				`claim '{opts.protected}': a reward handler errored; nothing granted: {tostring(committed)}`
			)
			out.refusal = "reward_failed"
			return false, out
		end
		if committed ~= true then
			restore(m, pend, vals, keys)
			m.flagged = m.flagged or wasFlagged
			out.refusal = out.refusal or "not_loaded"
			return false, out
		end
		-- committed
		local plain = not out.structural
			and #out.completed == 0
			and body == nil
			and not opts.prune
			and not opts.normalize
		if mem[player] ~= nil then
			if plain then
				-- a fold that completed nothing: the folded values are the new base, same index
				resetCaps(m)
				for id, n in out.newValues do
					local q = m.quests[id]
					if q ~= nil then
						q.base = n
					end
				end
			else
				rebuild(player)
				readValues(player)
				publishBoard(player)
				sendProg(player)
			end
		end
		for _, r in out.rotated do
			signals.Rotated:Fire(player, r.kind, r.periodId)
		end
		for _, id in out.completed do
			signals.Completed:Fire(player, id)
		end
		for _, fn2 in out.after do
			fn2()
		end
		for _, id in out.completed do
			local def = defs[id]
			if def ~= nil and def.autoClaim and mem[player] ~= nil then
				part.api.claim(player, id)
			end
		end
		return true, out
	end

	local function fold(player: any)
		local m = mem[player]
		if m == nil or not m.ready or not isOn() then
			return
		end
		questTx(player, {})
	end

	--------------------------------------------------------------------------
	-- Rewards (inside the claim tx)
	--------------------------------------------------------------------------

	-- grants every reward of `def`; a refusal reason, or nil when everything was granted
	local function grantRewards(tx: any, player: any, def: any): string?
		local reason = REWARD_PREFIX .. def.id
		local copies = 0
		for _, r in def.reward do
			if r.kind == "item" then
				copies += r.count or 1
			elseif r.kind == "roll" then
				copies += 1
			end
		end
		if copies > 0 and ctx.isEnabled(Inventory) then
			if ctx.depsTx[Inventory].count(tx) + copies > ctx.deps[Inventory].cap(player) then
				return "inventory_full"
			end
		end
		for _, r in def.reward do
			if r.kind == "currency" then
				if not ctx.depsTx[Economy].grant(tx, r.amount, reason, r.currency) then
					return "reward_failed"
				end
			elseif r.kind == "item" then
				for _ = 1, r.count or 1 do
					if ctx.depsTx[Inventory].add(tx, r.item, { source = reason }) == nil then
						return "reward_failed"
					end
				end
			elseif r.kind == "roll" then
				-- a free roll at luck exactly 1 (the disclosed extra.questOdds), never session luck
				local got, info = ctx.depsTx[Rarity].roll(tx, r.table, 1, { grant = true, reason = reason })
				if got == nil then
					return if type(info) == "table" and info.reason == "inventory_full"
						then "inventory_full"
						else "reward_failed"
				end
			elseif r.kind == "custom" then
				local fn = rewards[r.handler]
				if fn == nil then
					return "reward_failed"
				end
				fn(tx, player, r.params, def.id)
			end
		end
		return nil
	end

	local function hasCustom(def: any): boolean
		for _, r in def.reward do
			if r.kind == "custom" then
				return true
			end
		end
		return false
	end

	local function refuse(tx: any, out: any, reason: string)
		out.refusal = reason
		tx.retryLater()
	end

	--------------------------------------------------------------------------
	-- Hooks
	--------------------------------------------------------------------------

	-- first tx on load: config pruning + the deal (docs: "Save data", "The deal")
	local function onLoaded(player: any)
		local m = newMem(player)
		mem[player] = m
		if not isOn() then
			publishEmpty(player)
			return
		end
		local ok = questTx(player, { prune = true, normalize = true })
		if ok and mem[player] ~= nil then
			m.ready = true
			sendProg(player)
		end
	end

	-- fold pending progress before the final save
	local function onRemoving(player: any)
		local m = mem[player]
		if m ~= nil and m.hasPending then
			pcall(fold, player)
		end
		mem[player] = nil
		rotateSet[player] = nil
	end

	-- fold every player's pending progress (BindToClose)
	local function onShutdown()
		for player, m in mem do
			if m.hasPending then
				pcall(fold, player)
			end
		end
	end

	local function queueRotation(player: any)
		if not rotateSet[player] then
			rotateSet[player] = true
			table.insert(rotateQueue, player)
		end
	end

	local function onTick(_dt: number)
		if not hasQuests or not isOn() then
			return
		end
		local t = now()
		local d = Period.day(t, cfg.utcOffsetHours)
		local w = Period.week(t, cfg.utcOffsetHours, cfg.weekStartsOn)
		if d ~= lastDay or w ~= lastWeek then
			for player in mem do
				queueRotation(player)
			end
			lastDay, lastWeek = d, w
		end
		-- the rotation after a reset (or an ended event, a flag turned on): rotatePerTick players
		local budget = cfg.rotatePerTick
		while budget > 0 and #rotateQueue > 0 do
			local player = table.remove(rotateQueue, 1)
			rotateSet[player] = nil
			local m = mem[player]
			if m ~= nil and ctx.data.isLoaded(player) then
				budget -= 1
				local ok = questTx(player, { prune = not m.ready, normalize = true })
				if ok then
					m.ready = true
				end
			end
		end
		local poll = t >= nextPoll
		if poll then
			nextPoll = t + cfg.sourcePollSeconds
		end
		for player, m in mem do
			if not m.ready then
				continue
			end
			if m.stale then
				rebuild(player)
				readValues(player)
				publishBoard(player)
			end
			if m.flagged then
				fold(player)
			elseif t >= m.nextFold then
				if m.hasPending then
					fold(player)
				end
			end
			if t >= m.nextFold then
				local step = cfg.foldSeconds
				m.nextFold += math.max(step, math.ceil((t - m.nextFold) / step) * step)
			end
			if poll then
				for name, spec in sources do
					if spec.changed == nil and m.srcIndex[name] ~= nil then
						readValues(player, name)
					end
				end
			end
			if m.anyDirty and t >= m.nextSend then
				sendProg(player)
			end
		end
	end

	-- the flag flipped: publish the (empty or full) board
	local function onFlagChanged(on: boolean)
		for player, m in mem do
			if on then
				m.stale = true
				queueRotation(player)
			else
				publishEmpty(player)
			end
		end
	end

	-- framework EventStarted / EventEnded (EventContext: id, startedAt, endsAt)
	local function onEventStarted(event: any)
		if type(event) ~= "table" or type(event.id) ~= "string" or type(event.startedAt) ~= "number" then
			return
		end
		local key = Period.windowKey(event.startedAt, scheduled[event.id] == true)
		if windows[event.id] == nil or key > windows[event.id] then
			windows[event.id] = key
		end
		for _, m in mem do
			m.stale = true
		end
	end

	local function onEventEnded(event: any)
		if type(event) ~= "table" or type(event.id) ~= "string" then
			return
		end
		for player, m in mem do
			m.stale = true
			queueRotation(player) -- complete-unclaimed event quests move to waiting
		end
	end

	-- a dependency signal a built-in source reads (module name, signal name, the signal's args packed)
	local function onDepSignal(moduleName: string, signalName: string, args: { any })
		if not isOn() then
			return
		end
		if moduleName == "Leaderboards" then
			local board = args[1]
			for player in mem do
				readValues(player, "leaderboardRank", board)
			end
			return
		end
		local player = args[1]
		local m = mem[player]
		if m == nil then
			return
		end
		if m.stale then
			rebuild(player)
		end
		if moduleName == "Economy" then
			local currency, delta, reason = args[2], args[4], args[5]
			if type(delta) == "number" and delta > 0 and not startsWith(reason, REWARD_PREFIX) then
				addSource(player, "currencyEarned", math.floor(delta), function(params: any): boolean
					local want = params.currency
					if want == nil then
						if primaryCurrency == nil then
							local okPrimary, id = pcall(function(): any
								return ctx.deps[Economy].primaryCurrency()
							end)
							primaryCurrency = if okPrimary then id else nil
						end
						want = primaryCurrency
					end
					return want == currency
				end)
			end
			readValues(player, "currency")
		elseif moduleName == "Inventory" then
			local inst = args[2]
			if
				signalName == "ItemAdded"
				and type(inst) == "table"
				and not startsWith(inst.source, REWARD_PREFIX)
			then
				addSource(player, "itemCollected", 1, function(params: any): boolean
					if params.item ~= nil and params.item ~= inst.itemId then
						return false
					end
					if params.rarity ~= nil then
						local okDef, def = pcall(function(): any
							return ctx.deps[Items].get(inst.itemId)
						end)
						return okDef and type(def) == "table" and def.rarity == params.rarity
					end
					return true
				end)
			end
			readValues(player, "itemOwned")
			if needsRequires then
				m.stale = true
			end
		elseif moduleName == "Rebirth" then
			addSource(player, "rebirthDone", 1, function(): boolean
				return true
			end)
			readValues(player, "rebirths")
			if needsRequires then
				m.stale = true
			end
		elseif moduleName == "Streak" then
			readValues(player, "streakDay")
		end
	end

	-- a registered value source's `changed` fired for a player
	local function onSourceChanged(name: string, player: any)
		if not isOn() or mem[player] == nil then
			return
		end
		readValues(player, name)
	end

	-- ackQuest: complete matching ack objectives of active quests once each (never claims)
	local function onAck(player: any, key: string): boolean
		local m = mem[player]
		if m == nil then
			return false
		end
		if m.stale then
			rebuild(player)
		end
		local moved = false
		for _, e in m.ackIndex[key] or {} do
			moved = addTo(m, e, 1) or moved
		end
		return moved
	end

	-- fill every objective of a tracked quest through the same path as server progress (console)
	local function fill(player: any, questId: string): boolean
		local m = mem[player]
		if m == nil then
			return false
		end
		if m.stale then
			rebuild(player)
		end
		local q = m.quests[questId]
		if q == nil or q.complete then
			return false
		end
		for oi, o in q.def.objectives do
			local e = { q = q, oi = oi, o = o, target = Model.target(o) }
			if o.kind == "threshold" then
				setValue(m, e, if Model.isRank(o) then 1 else o.target)
			else
				addTo(m, e, e.target)
			end
		end
		return true
	end

	--------------------------------------------------------------------------
	-- API
	--------------------------------------------------------------------------

	local api: any = {}

	function api.progress(player: any, key: any, amount: any): boolean
		-- the hot path: `mem` holds exactly the players loaded here (onLoaded .. onPlayerRemoving),
		-- so a hit is a valid player and the (pcall) player check runs only on a miss
		local m = mem[player]
		if m == nil then
			needPlayer("progress", player)
			needString("progress", "key", key)
			return false
		end
		needString("progress", "key", key)
		if not m.ready or (cfg.flag ~= nil and not isOn()) then
			return false
		end
		local n = if amount == nil then 1 else amount
		if type(n) ~= "number" or n ~= n or n <= 0 or n > cfg.maxAmount then
			return false
		end
		n = math.max(1, math.floor(n))
		if m.stale then
			rebuild(player)
		end
		local list = m.index[key]
		if list == nil then
			return false
		end
		currentPeriod("daily") -- refresh the period cache once for this call
		if periodNow.daily ~= m.capDay or periodNow.weekly ~= m.capWeek then
			resetCaps(m) -- the amounts so far belong to the ended period's entries
			m.capDay, m.capWeek = periodNow.daily, periodNow.weekly
		end
		local cap = m.cap[key]
		if cap == nil then
			cap = capOf(m, list)
			m.cap[key] = cap
		end
		if cap == math.huge then
			return false -- every objective on this key is complete, at its target or ended
		end
		m.hasPending = true
		m.anyDirty = true
		local a = (m.acc[key] or 0) + n
		if a < cap then
			m.acc[key] = a -- no objective reaches its target: settled later (see settle)
			m.accAny = true
			return true
		end
		-- an objective reaches its target: the exact per-entry path (clamped, completion flagged)
		m.acc[key] = nil
		settle(m)
		m.cap[key] = nil
		local pend, moved = m.pend, false
		for _, e in list do
			local q = e.q
			if q.complete or (q.slotKind ~= nil and q.key < periodNow[q.slotKind]) then
				continue
			end
			local id, oi, target = q.id, e.oi, e.target
			local p = pend[id]
			local cur = (q.base[oi] or 0) + (if p ~= nil then p[oi] or 0 else 0)
			if cur >= target then
				continue
			end
			local add = if a < target - cur then a else target - cur
			if p == nil then
				p = {}
				pend[id] = p
			end
			p[oi] = (p[oi] or 0) + add
			m.pendKey[id] = q.key
			moved = true
			if cur + add >= target and liveComplete(m, q) then
				m.flagged = true
			end
		end
		return moved
	end

	function api.claim(player: any, questId: any): (boolean, string?)
		needPlayer("claim", player)
		needString("claim", "questId", questId)
		local why = refusal(player)
		if why ~= nil then
			return false, why
		end
		local def = defs[questId]
		if def == nil then
			return false, "unknown_quest"
		end
		local ok, out = questTx(player, {
			normalize = true,
			prune = not mem[player].ready,
			protected = if hasCustom(def) then def.id else nil,
		}, function(tx: any, s: any, env: any, out: any)
			local target, reason = Model.findClaim(s, def, env)
			if target == nil then
				refuse(tx, out, reason or "not_active")
				return
			end
			-- the claim record
			if target.where == "waiting" then
				table.remove(s.waiting, target.index)
			elseif target.where == "slot" or def.kind == "event" then
				target.entry.s = 2 -- claimed in this period / window
			elseif def.kind == "repeatable" then
				local e = target.entry
				e.k = (e.k or 0) + 1
				e.n = Model.zeros(def)
				e.s = 0
				s.granted[def.id] = nil
			else -- chain, oneTime: the claim ledger; the next chain step is now current
				s.done[def.id] = env.now
				s.prog[def.id] = nil
				s.granted[def.id] = nil
				local i = table.find(s.pins, def.id)
				if i ~= nil then
					table.remove(s.pins, i)
				end
			end
			-- and every reward, in the same tx
			local failed = grantRewards(tx, player, def)
			if failed ~= nil then
				refuse(tx, out, failed)
				return
			end
			out.structural = true
			table.insert(out.after, function()
				signals.Claimed:Fire(player, def.id, def.reward)
				if def.funnel ~= nil then
					ctx.analytics.funnel(player, def.funnel)
				end
				ctx.analytics.custom(player, "QuestClaimed", 1, { quest = def.id, kind = def.kind })
			end)
		end)
		if not ok then
			return false, out.refusal
		end
		if mem[player] ~= nil then
			mem[player].ready = true
		end
		return true, nil
	end

	function api.reroll(player: any, kind: any, slot: any): (boolean, string)
		needPlayer("reroll", player)
		local why = refusal(player)
		if why ~= nil then
			return false, why
		end
		if kind ~= "daily" and kind ~= "weekly" then
			return false, "bad_kind"
		end
		local count = cfg[kind].count
		if type(slot) ~= "number" or slot ~= math.floor(slot) or slot < 1 or slot > count then
			return false, "bad_slot"
		end
		local limit = cfg[kind].rerollsPerSlot
		local result: string? = nil
		local ok, out = questTx(
			player,
			{ normalize = true, prune = not mem[player].ready },
			function(tx: any, s: any, env: any, out: any)
				local set = s[SLOT_KEY[kind]]
				local entry = set.slots[slot]
				if entry == nil then
					refuse(tx, out, "bad_slot")
					return
				end
				local def = defs[entry.q]
				if entry.s ~= 0 or def == nil or def.kind ~= kind then
					refuse(tx, out, "slot_done")
					return
				end
				if limit <= 0 or entry.r >= limit then
					refuse(tx, out, "no_rerolls")
					return
				end
				local candidates = Model.snapshotCandidates(set, env, kind)
				local n = entry.r + 1
				local weights: { [string]: number } = {}
				for _, id in candidates do
					weights[id] = defs[id].weight
				end
				local id = Deal.pick(
					candidates,
					weights,
					Deal.seed(env.userId, kind, set.id, cfg.poolVersion, slot, n)
				)
				if id == nil then
					refuse(tx, out, "pool_empty")
					return
				end
				set.seen[id] = true
				set.slots[slot] = { q = id, n = Model.zeros(defs[id]), s = 0, r = n }
				local pinned = table.find(s.pins, entry.q)
				if pinned ~= nil then
					table.remove(s.pins, pinned)
				end
				out.structural = true
				result = id
			end
		)
		if not ok then
			return false, out.refusal
		end
		if mem[player] ~= nil then
			mem[player].ready = true
		end
		return true, result :: string
	end

	local function questView(inst: any, snapshot: any, m: any): any
		local def, entry = inst.def, inst.entry
		local q = m.quests[def.id]
		local values = if q ~= nil then liveValues(m, q) else Model.values(def, entry.n)
		local status = if entry.s == 2 then "claimed" elseif entry.s == 1 then "complete" else "active"
		if def.kind == "repeatable" and (entry.k or 0) >= def.cap then
			status = "claimed"
		end
		if status == "active" and Model.complete(def, values) then
			status = "complete"
		end
		local objectives = {}
		for oi, o in def.objectives do
			table.insert(objectives, {
				kind = o.kind,
				key = o.key,
				source = o.source,
				value = values[oi] or 0,
				target = Model.target(o),
			})
		end
		local out: any = {
			id = def.id,
			kind = def.kind,
			status = status,
			pinned = table.find(snapshot.pins, def.id) ~= nil,
			objectives = objectives,
			reward = def.reward,
		}
		if inst.slotKind ~= nil then
			out.slot = inst.slot
			out.periodId = inst.setId
			out.endsAt = Period.endsAt(inst.slotKind, inst.setId, cfg.utcOffsetHours)
			out.rerollsLeft = math.max(0, cfg[inst.slotKind].rerollsPerSlot - (entry.r or 0))
		elseif type(entry.p) == "number" then
			out.periodId = entry.p
		end
		if def.kind == "repeatable" then
			out.claims = entry.k or 0
			out.cap = def.cap
			out.endsAt = Period.endsAt(def.period, entry.p, cfg.utcOffsetHours)
		end
		return out
	end

	function api.active(player: any): { QuestTypes.QuestView }
		needPlayer("active", player)
		if refusal(player) ~= nil then
			return EMPTY :: any
		end
		local m = mem[player]
		if m.stale then
			rebuild(player)
		end
		local snapshot = ctx.data.get(player)
		local env = makeEnv(player)
		local list = {}
		for _, inst in Model.instances(snapshot, env) do
			table.insert(list, questView(inst, snapshot, m))
		end
		for _, w in snapshot.waiting do
			local def = defs[w.q]
			if def == nil then
				continue
			end
			local objectives = {}
			for _, o in def.objectives do
				local target = Model.target(o)
				table.insert(
					objectives,
					{ kind = o.kind, key = o.key, source = o.source, value = target, target = target }
				)
			end
			table.insert(list, {
				id = def.id,
				kind = def.kind,
				status = "complete",
				periodId = w.p,
				waiting = true,
				pinned = false,
				objectives = objectives,
				reward = def.reward,
			})
		end
		return deepFreeze(list)
	end

	function api.state(player: any, questId: any): QuestTypes.QuestState?
		needPlayer("state", player)
		needString("state", "questId", questId)
		local def = defs[questId]
		if def == nil or refusal(player) ~= nil then
			return nil
		end
		local m = mem[player]
		if m.stale then
			rebuild(player)
		end
		local snapshot = ctx.data.get(player)
		local env = makeEnv(player)
		local status, entry = Model.state(snapshot, def, env)
		local out: any = { status = status }
		if entry ~= nil then
			local q = m.quests[def.id]
			out.values = if q ~= nil then liveValues(m, q) else Model.values(def, entry.n)
			if status == "active" and Model.complete(def, out.values) then
				out.status = "complete"
			end
			if def.kind == "repeatable" then
				out.claims = entry.k or 0
			end
			local _, slotKind, setId = Model.current(snapshot, def, env, false)
			out.periodId = if slotKind ~= nil then setId else entry.p
		end
		return deepFreeze(out)
	end

	function api.def(questId: any): QuestTypes.Quest?
		needString("def", "questId", questId)
		return defs[questId]
	end

	function api.grant(player: any, questId: any): (boolean, string?)
		needPlayer("grant", player)
		needString("grant", "questId", questId)
		local why = refusal(player)
		if why ~= nil then
			return false, why
		end
		local def = defs[questId]
		if def == nil then
			return false, "unknown_quest"
		end
		if def.offer ~= "grant" or (def.kind ~= "oneTime" and def.kind ~= "repeatable") then
			return false, "not_grantable"
		end
		local ok, out = questTx(
			player,
			{ normalize = true, prune = not mem[player].ready },
			function(tx: any, s: any, env: any, out: any)
				if def.kind == "oneTime" and s.done[def.id] ~= nil then
					refuse(tx, out, "claimed")
				elseif s.granted[def.id] == true then
					refuse(tx, out, "already_active")
				elseif def.retired or not env.unlocked(def, s) then
					refuse(tx, out, "locked")
				else
					s.granted[def.id] = true
					out.structural = true
				end
			end
		)
		if not ok then
			return false, out.refusal
		end
		return true, nil
	end

	function api.pin(player: any, questId: any, on: any): (boolean, string?)
		needPlayer("pin", player)
		needString("pin", "questId", questId)
		local why = refusal(player)
		if why ~= nil then
			return false, why
		end
		local def = defs[questId]
		if def == nil then
			return false, "unknown_quest"
		end
		local ok, out = questTx(
			player,
			{ normalize = true, prune = not mem[player].ready },
			function(tx: any, s: any, env: any, out: any)
				local at = table.find(s.pins, def.id)
				if on ~= true then
					if at ~= nil then
						table.remove(s.pins, at)
						out.structural = true
					end
					return
				end
				if Model.current(s, def, env, false) == nil then
					refuse(tx, out, "not_active")
				elseif at == nil then
					if #s.pins >= cfg.pinMax then
						refuse(tx, out, "pin_limit")
					else
						table.insert(s.pins, def.id)
						out.structural = true
					end
				end
			end
		)
		if not ok then
			return false, out.refusal
		end
		return true, nil
	end

	api.signals = signals
	part.api = api

	--------------------------------------------------------------------------
	-- Extensions (init only: boot validation runs in start)
	--------------------------------------------------------------------------

	part.extensions = {
		registerSource = function(name: any, spec: any)
			if initDone then
				error("Quests.registerSource: call it during init (boot validation runs in start)", 2)
			end
			if type(name) ~= "string" or name == "" then
				error("Quests.registerSource(name, spec): name must be a non-empty string", 2)
			end
			if Validate.SOURCES[name] ~= nil then
				error(`Quests.registerSource: '{name}' is a built-in source`, 2)
			end
			if sources[name] ~= nil then
				error(`Quests.registerSource: '{name}' is already registered`, 2)
			end
			if type(spec) ~= "table" or type(spec.read) ~= "function" then
				error("Quests.registerSource(name, spec): spec.read must be a function", 2)
			end
			if spec.changed ~= nil then
				local okConnect, connect = pcall(function(): any
					return spec.changed.Connect
				end)
				if not okConnect or connect == nil then
					error("Quests.registerSource: spec.changed must have :Connect(fn)", 2)
				end
			end
			sources[name] = { read = spec.read, changed = spec.changed }
		end,
		registerReward = function(handler: any, fn: any)
			if initDone then
				error("Quests.registerReward: call it during init (boot validation runs in start)", 2)
			end
			if type(handler) ~= "string" or handler == "" then
				error("Quests.registerReward(handler, fn): handler must be a non-empty string", 2)
			end
			if type(fn) ~= "function" then
				error("Quests.registerReward(handler, fn): fn must be a function", 2)
			end
			if rewards[handler] ~= nil then
				error(`Quests.registerReward: '{handler}' is already registered`, 2)
			end
			rewards[handler] = fn
		end,
	}

	--------------------------------------------------------------------------
	-- Actions (client to server; the client's strings never go past the config lookup)
	--------------------------------------------------------------------------

	part.actions = {
		claimQuest = {
			limit = { rate = 2, burst = 4 },
			handler = function(player: any, questId: any): any
				local def = if type(questId) == "string" then defs[questId] else nil
				if def == nil then
					return false, "unknown_quest"
				end
				return api.claim(player, def.id)
			end,
		},
		rerollQuest = {
			limit = { rate = 1, burst = 2 },
			handler = function(player: any, kind: any, slot: any): any
				local which = if kind == "daily" then "daily" elseif kind == "weekly" then "weekly" else nil
				if which == nil then
					return false, "bad_kind"
				end
				local count = cfg[which].count
				if type(slot) ~= "number" or slot ~= math.floor(slot) or slot < 1 or slot > count then
					return false, "bad_slot"
				end
				return api.reroll(player, which, slot)
			end,
		},
		pinQuest = {
			limit = { rate = 2, burst = 4 },
			handler = function(player: any, questId: any, on: any): any
				local def = if type(questId) == "string" then defs[questId] else nil
				if def == nil then
					return false, "unknown_quest"
				end
				return api.pin(player, def.id, on == true)
			end,
		},
		ackQuest = {
			limit = { rate = 1, burst = 3 },
			handler = function(player: any, key: any): any
				if type(key) ~= "string" or not ackKeys[key] or refusal(player) ~= nil then
					return false
				end
				return onAck(player, key)
			end,
		},
	}

	--------------------------------------------------------------------------
	-- Console
	--------------------------------------------------------------------------

	local function registerConsole()
		ctx.console.register("state", function(caller: any, userId: any): string
			if not isAdmin(caller) then
				return "quests state is for Studio or admins"
			end
			local p = findPlayer(userId)
			if p == nil then
				return "no loaded player"
			end
			local lines = { `quests for {p.UserId} (flag {if isOn() then "on" else "off"}):` }
			for _, v in api.active(p) do
				local parts = {}
				for _, o in v.objectives do
					table.insert(parts, `{o.value}/{o.target}`)
				end
				local where = if v.waiting then " (waiting)" else ""
				table.insert(lines, `  {v.id} [{v.kind}] {v.status}{where} {table.concat(parts, " ")}`)
			end
			if #lines == 1 then
				table.insert(lines, "  (none)")
			end
			return table.concat(lines, "\n")
		end, "quests state [userId]: a player's active quests (Studio or admins)")
		ctx.console.register("progress", function(_caller: any, key: any, amount: any, userId: any): string
			if not ctx.isStudio then
				return "quests progress is Studio-only"
			end
			local p = findPlayer(userId)
			if p == nil then
				return "no loaded player"
			end
			if type(key) ~= "string" then
				return "usage: quests progress <key> <amount> [userId]"
			end
			local moved = api.progress(p, key, tonumber(amount) or 1)
			return `progress {key}: {if moved then "moved" else "nothing matched"}`
		end, "quests progress <key> <amount> [userId]: add to a counter (Studio)")
		ctx.console.register("complete", function(_caller: any, questId: any, userId: any): string
			if not ctx.isStudio then
				return "quests complete is Studio-only"
			end
			local p = findPlayer(userId)
			if p == nil then
				return "no loaded player"
			end
			local def = if type(questId) == "string" then defs[questId] else nil
			if def == nil then
				return `unknown quest '{tostring(questId)}'`
			end
			if refusal(p) ~= nil then
				return `{def.id}: not filled ({refusal(p)})`
			end
			local filled = fill(p, def.id)
			return `{def.id}: {if filled then "filled" else "not filled (not active, or already complete)"}`
		end, "quests complete <questId> [userId]: fill every objective (Studio)")
		ctx.console.register("timeshift", function(_caller: any, seconds: any): string
			if not ctx.isStudio then
				return "quests timeshift is Studio-only"
			end
			local n = tonumber(seconds)
			if n == nil or n ~= n then
				return "usage: quests timeshift <seconds>"
			end
			clockShift += n
			local day = Period.day(now(), cfg.utcOffsetHours)
			return `quests clock shifted by {clockShift}s on this server (day {day})`
		end, "quests timeshift <seconds>: shift this server's quest clock (Studio)")
	end

	--------------------------------------------------------------------------
	-- Lifecycle
	--------------------------------------------------------------------------

	local function enabledMap(): { [string]: boolean }
		local out: { [string]: boolean } = {}
		for name, ref in OPTIONAL do
			out[name] = ctx.isEnabled(ref)
		end
		return out
	end

	function part.init(context: any)
		ctx = context
		cfg = ctx.config
		if cfg.flag ~= nil then
			local ok, err = pcall(ctx.flags.isOn, cfg.flag)
			if not ok then
				error(`[Quests] config.flag: {tostring(err)}`, 0)
			end
		end
		defs = Validate.defs(cfg)
		order = { daily = {}, weekly = {}, chain = {}, oneTime = {}, repeatable = {}, event = {} }
		hasQuests = false
		needsRequires = false
		for id, def in defs do
			hasQuests = true
			if order[def.kind] ~= nil then
				table.insert(order[def.kind], id)
			end
			for _, o in def.objectives do
				if type(o) == "table" and o.kind == "ack" and type(o.key) == "string" then
					ackKeys[o.key] = true
				end
			end
			local req = def.requires
			if req ~= nil and (req.rebirths ~= nil or req.items ~= nil) then
				needsRequires = true
			end
		end
		for _, list in order do
			table.sort(list)
		end
		chainOrder = {}
		chainOf = {}
		for chainId, steps in cfg.chains do
			table.insert(chainOrder, chainId)
			if type(steps) == "table" then
				for _, step in steps do
					if type(step) == "string" and chainOf[step] == nil then
						chainOf[step] = chainId
					end
				end
			end
		end
		table.sort(chainOrder)
		local events = ctx.gameConfig.events
		if type(events) == "table" then
			for id, ev in events do
				scheduled[id] = type(ev) == "table" and ev.schedule ~= nil
			end
		end
		for _, name in SIGNAL_NAMES do
			signals[name] = ctx.signals.new(name)
		end
		registerConsole()
	end

	function part.start(_context: any)
		initDone = true
		lastDay = Period.day(now(), cfg.utcOffsetHours)
		lastWeek = Period.week(now(), cfg.utcOffsetHours, cfg.weekStartsOn)
		local enabled = enabledMap()
		local errors = Validate.check(cfg, {
			enabled = enabled,
			sources = sources,
			rewards = rewards,
			itemKnown = if enabled.Items
				then function(id: string): boolean
					return ctx.deps[Items].get(id) ~= nil
				end
				else nil,
			oddsDetail = if enabled.Rarity
				then function(tableId: string): any
					return ctx.deps[Rarity].getOddsDetail(tableId, nil, 1)
				end
				else nil,
			events = ctx.gameConfig.events or {},
		})
		if #errors > 0 then
			error("[Quests] invalid config.Quests:\n  - " .. table.concat(errors, "\n  - "), 0)
		end

		-- extra.questOdds: the luck-1 odds of every roll reward's table, the same for everyone
		local odds: { [string]: any } = {}
		if enabled.Rarity then
			for _, def in defs do
				for _, r in def.reward do
					if r.kind == "roll" and type(r.table) == "string" and odds[r.table] == nil then
						odds[r.table] = ctx.deps[Rarity].getOddsDetail(r.table, nil, 1)
					end
				end
			end
		end
		ctx.replicate.setAll("questOdds", odds)

		-- dependency signals the built-in sources read (only modules this config references)
		local used: { [string]: boolean } = {}
		for _, def in defs do
			for _, o in def.objectives do
				local builtin = if type(o) == "table" and type(o.source) == "string"
					then Validate.SOURCES[o.source]
					else nil
				if builtin then
					for _, need in builtin.needs do
						used[need] = true
					end
				end
			end
			if def.requires ~= nil then
				if def.requires.rebirths ~= nil then
					used.Rebirth = true
				end
				if def.requires.items ~= nil then
					used.Inventory = true
				end
			end
		end
		for moduleName, names in SOURCE_SIGNALS do
			if used[moduleName] and enabled[moduleName] then
				local depApi = ctx.deps[OPTIONAL[moduleName]]
				for _, signalName in names do
					local okSignal, signal = pcall(function(): any
						return depApi.signals[signalName]
					end)
					if okSignal and signal ~= nil then
						signal:Connect(function(...: any)
							onDepSignal(moduleName, signalName, { ... })
						end)
					else
						-- the page re-reads built-in sources only on their module's signal (no poll)
						ctx.log.warn(
							`{moduleName}.signals.{signalName} unavailable: '{VALUE_SOURCE_OF[moduleName]}' is read only on load and rebuild`
						)
					end
				end
			end
		end
		for name, spec in sources do
			if spec.changed ~= nil then
				(spec.changed :: any):Connect(function(player: any)
					onSourceChanged(name, player)
				end)
			end
		end

		ctx.signals.framework.EventStarted:Connect(onEventStarted)
		ctx.signals.framework.EventEnded:Connect(onEventEnded)
		if cfg.flag ~= nil then
			ctx.flags.onChanged(cfg.flag, onFlagChanged)
		end
		ctx.data.onLoaded(function(player: any)
			players[player] = true
			onLoaded(player)
		end)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			onRemoving(player)
			players[player] = nil
		end)
		ctx.lifecycle.onShutdown(onShutdown)
		ctx.lifecycle.onTick(1, onTick)
	end

	return part
end

return Server
