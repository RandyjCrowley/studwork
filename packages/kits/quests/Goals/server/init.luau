--!strict
--[[
	Goals: the server part (docs/framework/kits/quests.md, "Goals").

	The first-session chain: an ordered list of goals from config (or `setChain`), the current goal
	= the first one not done, one funnel step per goal, and a game-supplied "what's next" after the
	chain. Server-owned state in the "goals" save section; nothing is granted.

	  api: current, complete, setChain, setNext, skip, signals (GoalChanged, ChainDone)
	  extensions (init only): registerSource(name, spec)
	  actions (net.blink): skipGoals, ackGoal
	  console: goals state [userId] (Studio or admins); goals complete <goalId> [userId],
	           goals reset [userId] (Studio only)

	How work is batched (the design's open question 19):
	  - The signals that can change a check (Quests Completed/Claimed/Progressed, Economy
	    CurrencyChanged, Inventory ItemAdded/ItemRemoved, Rebirth Rebirthed, Streak StreakAdvanced,
	    a registered source's `changed`) only mark the player dirty. Goals' 1 s tick checks each
	    dirty player once and writes every newly done goal in ONE ctx.tx, whose tx.after logs the
	    funnel steps, fires GoalChanged / ChainDone and replicates extra.goal.
	  - `complete` never opens a tx: it queues the goal, written on the next tick (safe inside a
	    game's own tx). `ackGoal` (an action, never inside a tx) writes at once. `skip` and the
	    load step open their own tx.
	  - Past the chain, the `setNext` provider runs for a dirty player when its slot in a timer
	    wheel comes up: at most once per `nextSeconds` per player, no loop over idle players.
	  - Registered sources without `changed` are polled every `sourcePollSeconds`, only for
	    players with a not-done goal on them.
	  - First load: a section with v = 0 is new. A returning player (sessions > 1) starts finished
	    (no funnel steps, no ChainDone). Removed goal ids are dropped in the load tx; a save made
	    against another chainVersion is re-checked (finished stays finished). An empty chain or a
	    flag that is off writes nothing.

	The module is a factory (`new`) so each harness or server keeps its own state.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Shared = Modules:WaitForChild("Goals"):WaitForChild("shared")
local GoalTypes = require(Shared:WaitForChild("Types"))
local Validate = require(Shared:WaitForChild("Validate"))
local SignalTable = require(script.SignalTable)

local function kit(name: string): any
	return require(Modules:WaitForChild(name):WaitForChild("module")) :: any
end

local Quests = kit("Quests")
local Economy = kit("Economy")
local Inventory = kit("Inventory")
local Rebirth = kit("Rebirth")
local Streak = kit("Streak")

local OPTIONAL: { [string]: any } = {
	Quests = Quests,
	Economy = Economy,
	Inventory = Inventory,
	Rebirth = Rebirth,
	Streak = Streak,
}

-- the signals that can change a check: they only mark the player dirty (one check per tick)
local DIRTY_SIGNALS: { [string]: { string } } = {
	Quests = { "Completed", "Claimed", "Progressed" },
	Economy = { "CurrencyChanged" },
	Inventory = { "ItemAdded", "ItemRemoved" },
	Rebirth = { "Rebirthed" },
	Streak = { "StreakAdvanced" },
}

local SIGNAL_NAMES = { "GoalChanged", "ChainDone" }

-- a provider error is logged at most once per this many seconds
local ERROR_LOG_SECONDS = 60
-- args values a NextGoal may carry (wire-safe)
local ARG_TYPES: { [string]: boolean } = { string = true, number = true, boolean = true }
local MAX_TEXT = 200

local Server = {}

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- a wire-safe copy of a Target, or nil when it isn't one of the forms
local function wireTarget(t: any): GoalTypes.Target?
	if type(t) ~= "table" then
		return nil
	end
	if type(t.tag) == "string" and t.tag ~= "" then
		return { tag = t.tag }
	elseif type(t.path) == "string" and t.path ~= "" then
		return { path = t.path }
	elseif type(t.picker) == "string" and t.picker ~= "" then
		return { picker = t.picker }
	elseif Validate.position(t.position) then
		-- named {x, y, z} positions are valid in a chain; the wire always carries an array
		return { position = Validate.toArray(t.position) }
	end
	return nil
end

local function wireArgs(args: any): { [string]: any }?
	if type(args) ~= "table" then
		return nil
	end
	local out: { [string]: any } = {}
	local any = false
	for k, v in args do
		if type(k) == "string" and ARG_TYPES[type(v)] and (type(v) ~= "number" or finite(v)) then
			out[k] = v
			any = true
		end
	end
	return if any then out else nil
end

local function sameValue(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not sameValue(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function Server.new(): any
	local ctx: any = nil
	local cfg: any = nil
	local chain: { GoalTypes.Goal } = {}
	local chainVersion = 1
	local byId: { [string]: GoalTypes.Goal } = {}
	local sources: { [string]: GoalTypes.SourceSpec } = {}
	local provider: ((player: any) -> GoalTypes.NextGoal?)? = nil
	local players: { [any]: boolean } = {}
	local anyLoaded = false
	local initDone = false
	local signals: any = SignalTable.new()
	local part: any = {}

	-- per-player memory (cleared on leave)
	local prepared: { [any]: boolean } = {} -- the load step ran (flag on, chain non-empty)
	local dirty: { [any]: boolean } = {} -- re-check not-done goals on the next tick
	local queued: { [any]: { string } } = {} -- accepted Goals.complete calls, written next tick
	local answers: { [any]: GoalTypes.NextGoal } = {} -- the provider's last answer (wire-safe)
	local sentWire: { [any]: any } = {} -- what extra.goal holds (false = nothing sent yet)
	local nextLast: { [any]: number } = {} -- tick the provider last ran for the player
	local nextAt: { [any]: number } = {} -- the wheel slot the player waits in
	local want: { [any]: any } = {} -- what can change the player's not-done goals (wantOf)
	local wheel: { [number]: { [any]: boolean } } = {}
	local tickN = 0
	local pollAcc = 0
	local lastErrorLog = -math.huge
	local polled: { [string]: boolean } = {} -- registered sources without `changed`
	local enabled: { [string]: boolean } = {}

	--------------------------------------------------------------------------
	-- Helpers
	--------------------------------------------------------------------------

	local function isOn(): boolean
		if cfg == nil or cfg.flag == nil then
			return true
		end
		local ok, on = pcall(ctx.flags.isOn, cfg.flag)
		return ok and on == true
	end

	local function isPlayer(player: any): boolean
		if type(player) ~= "userdata" and type(player) ~= "table" then
			return false
		end
		local ok, userId = pcall(function(): any
			return player.UserId
		end)
		return ok and type(userId) == "number"
	end

	local function needPlayer(fn: string, player: any)
		if not isPlayer(player) then
			error(`Goals.{fn}: player must be a Player`, 3)
		end
	end

	local function refusal(player: any): string?
		if not isOn() then
			return "disabled"
		end
		if not players[player] or not ctx.data.isLoaded(player) then
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

	local function enabledMap(): { [string]: boolean }
		local out: { [string]: boolean } = {}
		for name, ref in OPTIONAL do
			out[name] = ctx.isEnabled(ref)
		end
		return out
	end

	local function validate(list: any): { string }
		local on = enabledMap()
		return Validate.check(list, {
			enabled = on,
			sources = sources,
			questDef = if on.Quests
				then function(id: string): any
					return ctx.deps[Quests].def(id)
				end
				else nil,
		})
	end

	local function useChain(list: { GoalTypes.Goal }, version: number)
		chain = list
		chainVersion = version
		byId = {}
		for _, goal in list do
			byId[goal.id] = goal
		end
	end

	local function section(player: any): any
		if not ctx.data.isLoaded(player) then
			return nil
		end
		local ok, s = pcall(ctx.data.get, player)
		return if ok then s else nil
	end

	-- the first goal in the chain not in `done` (and its index), nil when every goal is done
	local function firstOpen(done: { [string]: boolean }): (GoalTypes.Goal?, number)
		for i, goal in chain do
			if not done[goal.id] then
				return goal, i
			end
		end
		return nil, #chain + 1
	end

	local function textOf(goal: GoalTypes.Goal): string
		return goal.text or ("Goals.goal." .. goal.id)
	end

	--------------------------------------------------------------------------
	-- Checks (read-only: other modules' public read APIs, the committed state)
	--------------------------------------------------------------------------

	local function readSource(player: any, name: string, params: { [string]: any }?): number?
		local p: { [string]: any } = params or {}
		if name == "currency" then
			if not enabled.Economy then
				return nil
			end
			return ctx.deps[Economy].balance(player, if type(p.currency) == "string" then p.currency else nil)
		elseif name == "rebirths" then
			return if enabled.Rebirth then ctx.deps[Rebirth].count(player) else nil
		elseif name == "streakDay" then
			if not enabled.Streak then
				return nil
			end
			local s = ctx.deps[Streak].get(player)
			return if type(s) == "table" then s.day else nil
		elseif name == "itemOwned" then
			if not enabled.Inventory then
				return nil
			end
			local n = 0
			for _, inst in ctx.deps[Inventory].list(player) do
				if type(inst) == "table" and inst.itemId == p.item then
					n += 1
				end
			end
			return n
		end
		local spec = sources[name]
		if spec == nil then
			return nil
		end
		local ok, value = pcall(spec.read, player)
		return if ok and finite(value) then value else nil
	end

	local function checkMet(player: any, goal: GoalTypes.Goal): boolean
		local c = goal.check
		if c.source ~= nil then
			local value = readSource(player, c.source, c.params)
			return value ~= nil and c.atLeast ~= nil and value >= c.atLeast
		elseif c.quest ~= nil then
			if not enabled.Quests then
				return false
			end
			local quests = ctx.deps[Quests]
			local ok, st = pcall(quests.state, player, c.quest)
			if not ok or type(st) ~= "table" then
				return false
			end
			if c.objective ~= nil then
				if st.status == "complete" or st.status == "claimed" then
					return true
				end
				local def = quests.def(c.quest)
				local obj = def and def.objectives and def.objectives[c.objective]
				local value = st.values and st.values[c.objective]
				if obj == nil or not finite(value) then
					return false
				end
				local target = obj.target or 1
				if obj.kind == "threshold" and obj.source == "leaderboardRank" then
					return value >= 1 and value <= target -- lower is better; 0 = not ranked
				end
				return value >= target
			end
			if c.on == "claimed" then
				return st.status == "claimed"
			end
			return st.status == "complete" or st.status == "claimed"
		end
		return false -- call / ack: only Goals.complete or ackGoal
	end

	--------------------------------------------------------------------------
	-- Views and replication
	--------------------------------------------------------------------------

	local function viewOf(player: any): GoalTypes.GoalView?
		if not isOn() or not players[player] or not prepared[player] then
			return nil
		end
		local s = section(player)
		if s == nil then
			return nil
		end
		local hidden = s.hide == true
		if not s.fin then
			local goal, index = firstOpen(s.done)
			if goal ~= nil then
				return table.freeze({
					id = goal.id,
					index = index,
					count = #chain,
					text = textOf(goal),
					args = nil,
					target = wireTarget(goal.target),
					widget = goal.widget,
					isNext = false,
					hidden = hidden,
				})
			end
		end
		local answer = answers[player]
		if answer == nil then
			return nil
		end
		return table.freeze({
			id = nil,
			index = #chain,
			count = #chain,
			text = answer.text,
			args = answer.args,
			target = answer.target,
			widget = answer.widget,
			isNext = true,
			hidden = hidden,
		})
	end

	local function wireOf(view: GoalTypes.GoalView?): GoalTypes.Wire?
		if view == nil then
			return nil
		end
		return {
			id = view.id,
			i = view.index,
			n = view.count,
			text = view.text,
			args = view.args,
			target = view.target,
			widget = view.widget,
			next = view.isNext,
			hidden = view.hidden,
		}
	end

	-- extra.goal: sent only when it changed (compared by value); nothing per tick
	local function replicate(player: any)
		if not players[player] then
			return
		end
		local wire = wireOf(viewOf(player))
		local last = sentWire[player]
		if last ~= false and sameValue(last, wire) then
			return
		end
		sentWire[player] = wire
		ctx.replicate.set(player, "goal", wire)
	end

	--------------------------------------------------------------------------
	-- "What's next" (timer wheel)
	--------------------------------------------------------------------------

	local function sanitizeAnswer(answer: any): GoalTypes.NextGoal?
		if type(answer) ~= "table" or type(answer.text) ~= "string" or answer.text == "" then
			return nil
		end
		if #answer.text > MAX_TEXT then
			return nil
		end
		return {
			text = answer.text,
			args = wireArgs(answer.args),
			target = wireTarget(answer.target),
			widget = if type(answer.widget) == "string" then answer.widget else nil,
		}
	end

	local function runProvider(player: any)
		nextLast[player] = tickN
		local fn = provider
		local answer: GoalTypes.NextGoal? = nil
		if fn ~= nil then
			local ok, result = pcall(fn, player)
			if ok then
				answer = sanitizeAnswer(result)
			elseif tickN - lastErrorLog >= ERROR_LOG_SECONDS then
				lastErrorLog = tickN
				ctx.log.warn(`setNext provider failed (counted as nil): {tostring(result)}`)
			end
		end
		if not sameValue(answers[player], answer) then
			answers[player] = answer :: any
			replicate(player)
		end
	end

	-- queue a provider run: in the next slot at least nextSeconds after the last run
	local function markNext(player: any)
		if provider == nil or nextAt[player] ~= nil then
			return
		end
		local last = nextLast[player]
		local at = if last == nil then tickN + 1 else math.max(tickN + 1, last + cfg.nextSeconds)
		nextAt[player] = at
		local bucket = wheel[at]
		if bucket == nil then
			bucket = {}
			wheel[at] = bucket
		end
		bucket[player] = true
	end

	--------------------------------------------------------------------------
	-- Writing done goals (one tx per batch)
	--------------------------------------------------------------------------

	-- Marks `ids` done (those in the chain, not done yet) in one ctx.tx. Its tx.after logs each
	-- funnel step, fires GoalChanged / ChainDone and replicates. Must not run inside a tx.
	local function apply(player: any, ids: { string }): boolean
		local s = section(player)
		if s == nil or s.fin then
			return false
		end
		local fresh: { [string]: boolean } = {}
		local any = false
		for _, id in ids do
			if byId[id] ~= nil and not s.done[id] then
				fresh[id] = true
				any = true
			end
		end
		if not any then
			return false
		end
		local before = firstOpen(s.done)
		local beforeId = if before then before.id else nil
		local ok = ctx.tx(player, function(tx: any)
			local w = ctx.section(tx)
			for id in fresh do
				w.done[id] = true
			end
			tx.after(function()
				want[player] = nil
			end)
			local nowGoal = firstOpen(w.done)
			local nowId = if nowGoal then nowGoal.id else nil
			local finished = nowGoal == nil
			if finished then
				w.fin = true
			end
			tx.after(function()
				for _, goal in chain do
					if fresh[goal.id] and goal.funnel ~= nil then
						ctx.analytics.funnel(player, goal.funnel)
					end
				end
				if nowId ~= beforeId then
					signals.GoalChanged:Fire(player, nowId, beforeId)
				end
				if finished then
					signals.ChainDone:Fire(player)
					if provider ~= nil then
						runProvider(player) -- the hand-over: the first answer at once
					end
				end
				replicate(player)
			end)
		end)
		return ok == true
	end

	local function process(player: any)
		local ids = queued[player] or {}
		queued[player] = nil
		local s = section(player)
		if s == nil then
			return
		end
		if dirty[player] then
			dirty[player] = nil
			if s.fin then
				markNext(player)
			else
				for _, goal in chain do
					if not s.done[goal.id] and checkMet(player, goal) then
						table.insert(ids, goal.id)
					end
				end
			end
		end
		if #ids > 0 then
			apply(player, ids)
		end
	end

	--------------------------------------------------------------------------
	-- Hooks
	--------------------------------------------------------------------------

	-- first tx on load: drop removed ids, version re-check, returning players start finished
	local function onLoaded(player: any)
		if not isOn() or #chain == 0 or prepared[player] then
			return
		end
		local returning = ctx.framework.sessions(player) > 1
		local ok = ctx.tx(player, function(tx: any)
			local w = ctx.section(tx)
			local wasNew = w.v == 0
			local savedDone: { [string]: boolean } = table.clone(w.done)
			for id in savedDone do
				if byId[id] == nil then
					w.done[id] = nil
				end
			end
			local newlyFinished = false
			if wasNew and returning then
				w.fin = true -- played before the game added Goals: no tutorial, no funnel steps
			elseif not w.fin and firstOpen(w.done) == nil then
				w.fin = true -- every goal of a changed chain was already done
				newlyFinished = true
			end
			w.v = chainVersion
			tx.after(function()
				want[player] = nil
				prepared[player] = true
				if newlyFinished then
					signals.ChainDone:Fire(player)
				end
				local s = section(player)
				if s and s.fin then
					if provider ~= nil then
						runProvider(player)
					end
				else
					dirty[player] = true -- every not-done goal is checked on the next tick
				end
				replicate(player)
			end)
		end)
		local _ = ok
	end

	local function onRemoving(player: any)
		local at = nextAt[player]
		if at ~= nil and wheel[at] then
			wheel[at][player] = nil
		end
		prepared[player] = nil
		dirty[player] = nil
		want[player] = nil
		queued[player] = nil
		answers[player] = nil
		sentWire[player] = nil
		nextLast[player] = nil
		nextAt[player] = nil
	end

	local function markPolls()
		for p in prepared do
			local s = section(p)
			if s and not s.fin then
				for _, goal in chain do
					local name = goal.check.source
					if name ~= nil and polled[name] and not s.done[goal.id] then
						dirty[p] = true
						break
					end
				end
			end
		end
	end

	-- 1 s: queued completions written, dirty players checked (once each), next-goal timer wheel, polls
	local function onTick(_dt: number)
		tickN += 1
		if not isOn() then
			-- the slot is dropped, so its players must not keep waiting in it (markNext refuses
			-- a player whose nextAt is set): free them for when the flag comes back on
			local dropped = wheel[tickN]
			if dropped ~= nil then
				for p in dropped do
					nextAt[p] = nil
				end
			end
			wheel[tickN] = nil
			return
		end
		if next(polled) ~= nil then
			pollAcc += 1
			if pollAcc >= cfg.sourcePollSeconds then
				pollAcc = 0
				markPolls()
			end
		end
		local work: { any } = {}
		for p in dirty do
			table.insert(work, p)
		end
		for p in queued do
			if not dirty[p] then
				table.insert(work, p)
			end
		end
		for _, p in work do
			if prepared[p] then
				process(p)
			else
				dirty[p] = nil
				queued[p] = nil
			end
		end
		local bucket = wheel[tickN]
		if bucket ~= nil then
			wheel[tickN] = nil
			for p in bucket do
				nextAt[p] = nil
				if prepared[p] then
					runProvider(p)
				end
			end
		end
	end

	local function onFlagChanged(on: boolean)
		table.clear(want)
		for p in players do
			if on then
				if prepared[p] then
					dirty[p] = true
					replicate(p)
				else
					onLoaded(p)
				end
			else
				replicate(p) -- nil: the pointer hides
			end
		end
	end

	--[[
		What can change one of the player's not-done goals, from the committed section; forgotten
		after every Goals write (want[player] = nil). Past the chain (`fin`) every signal counts:
		the setNext provider may read anything.
	]]
	local function wantOf(player: any): any
		local w = want[player]
		if w ~= nil then
			return w
		end
		local s = section(player)
		w = { fin = s == nil or s.fin == true, quest = {}, objective = {}, source = {}, currency = {} }
		if not w.fin then
			for _, goal in chain do
				if not s.done[goal.id] then
					local c = goal.check
					if c.quest ~= nil then
						w.quest[c.quest] = true
						if c.objective ~= nil then
							w.objective[c.quest] = true
						end
					elseif c.source == "currency" then
						table.insert(w.currency, c)
					elseif c.source ~= nil then
						w.source[c.source] = true
					end
				end
			end
		end
		want[player] = w
		return w
	end

	-- the dirty mark of each signal: only when it can change a not-done goal of the player
	local function onQuestSignal(player: any, questId: any)
		if players[player] and prepared[player] then
			local w = wantOf(player)
			if w.fin or w.quest[questId] then
				dirty[player] = true
			end
		end
	end

	local function onProgressed(player: any, questIds: any)
		if players[player] and prepared[player] then
			local w = wantOf(player)
			if w.fin then
				dirty[player] = true
			elseif next(w.objective) ~= nil and type(questIds) == "table" then
				for _, id in questIds do
					if w.objective[id] then
						dirty[player] = true
						return
					end
				end
			end
		end
	end

	-- CurrencyChanged(player, currency, newBalance): a currency goal can only be met by the
	-- currency it reads (no `params.currency` = the default one, so any) reaching `atLeast`
	local function onCurrency(player: any, currency: any, newBalance: any)
		if players[player] and prepared[player] then
			local w = wantOf(player)
			if w.fin then
				dirty[player] = true
				return
			end
			for _, c in w.currency do
				local named = if type(c.params) == "table" then c.params.currency else nil
				if
					(named == nil or named == currency)
					and (type(newBalance) ~= "number" or newBalance >= (c.atLeast :: number))
				then
					dirty[player] = true
					return
				end
			end
		end
	end

	local function onSource(name: string): (any) -> ()
		return function(player: any)
			if players[player] and prepared[player] then
				local w = wantOf(player)
				if w.fin or w.source[name] then
					dirty[player] = true
				end
			end
		end
	end

	-- the built-in source each module signal can change
	local SIGNAL_SOURCE: { [string]: string } = {
		ItemAdded = "itemOwned",
		ItemRemoved = "itemOwned",
		Rebirthed = "rebirths",
		StreakAdvanced = "streakDay",
	}

	-- ackGoal for the current goal (already looked up in the chain)
	local function onAck(player: any, goalId: string): boolean
		if not prepared[player] then
			return false
		end
		local s = section(player)
		if s == nil or s.fin or s.done[goalId] then
			return false
		end
		local current = firstOpen(s.done)
		if current == nil or current.id ~= goalId then
			return false -- out of order: only the current goal can be acknowledged
		end
		return apply(player, { goalId })
	end

	-- goals reset (Studio): clear the player's section
	local function reset(player: any): boolean
		if not players[player] or not ctx.data.isLoaded(player) then
			return false
		end
		local ok = ctx.data.update(player, function(w: any)
			w.done = {}
			w.fin = false
			w.hide = false
			w.v = chainVersion
		end)
		if not ok then
			return false
		end
		want[player] = nil
		answers[player] = nil
		queued[player] = nil
		if #chain > 0 then
			prepared[player] = true
			dirty[player] = true
		end
		replicate(player)
		return true
	end

	--------------------------------------------------------------------------
	-- API
	--------------------------------------------------------------------------

	local api: any = {}

	function api.current(player: any): GoalTypes.GoalView?
		needPlayer("current", player)
		return viewOf(player)
	end

	function api.complete(player: any, goalId: any): (boolean, string?)
		needPlayer("complete", player)
		if type(goalId) ~= "string" then
			error("Goals.complete: goalId must be a string", 2)
		end
		local why = refusal(player)
		if why ~= nil then
			return false, why
		end
		if byId[goalId] == nil then
			return false, "unknown_goal"
		end
		local s = section(player)
		if s == nil or not prepared[player] then
			return false, "not_loaded"
		end
		if s.fin or s.done[goalId] then
			return false, "done"
		end
		local list = queued[player]
		if list == nil then
			list = {}
			queued[player] = list
		end
		if not table.find(list, goalId) then
			table.insert(list, goalId)
		end
		return true, nil
	end

	function api.setChain(list: any, version: any)
		if anyLoaded then
			error("Goals.setChain: call it in start, before any player loads", 2)
		end
		if
			version ~= nil and (type(version) ~= "number" or version < 1 or version ~= math.floor(version))
		then
			error("Goals.setChain(chain, version): version must be an integer >= 1", 2)
		end
		local errors = validate(list)
		if #errors > 0 then
			error("Goals.setChain: invalid chain:\n  - " .. table.concat(errors, "\n  - "), 2)
		end
		useChain(table.clone(list), version or chainVersion)
	end

	function api.setNext(fn: any)
		if type(fn) ~= "function" then
			error("Goals.setNext(fn): fn must be a function (player) -> NextGoal?", 2)
		end
		provider = fn
		for p in prepared do
			local s = section(p)
			if s and s.fin then
				markNext(p)
			end
		end
	end

	function api.skip(player: any, hidden: any): boolean
		needPlayer("skip", player)
		if type(hidden) ~= "boolean" then
			error("Goals.skip(player, hidden): hidden must be a boolean", 2)
		end
		if not cfg.skippable or refusal(player) ~= nil then
			return false
		end
		local s = section(player)
		if s == nil then
			return false
		end
		if s.hide ~= hidden then
			local ok = ctx.data.update(player, function(w: any)
				w.hide = hidden
			end)
			if not ok then
				return false
			end
		end
		replicate(player)
		return true
	end

	api.signals = signals
	part.api = api

	--------------------------------------------------------------------------
	-- Extensions (init only: boot validation runs in start)
	--------------------------------------------------------------------------

	part.extensions = {
		registerSource = function(name: any, spec: any)
			if initDone then
				error("Goals.registerSource: call it during init (boot validation runs in start)", 2)
			end
			if type(name) ~= "string" or name == "" then
				error("Goals.registerSource(name, spec): name must be a non-empty string", 2)
			end
			if Validate.SOURCES[name] ~= nil then
				error(`Goals.registerSource: '{name}' is a built-in source`, 2)
			end
			if sources[name] ~= nil then
				error(`Goals.registerSource: '{name}' is already registered`, 2)
			end
			if type(spec) ~= "table" or type(spec.read) ~= "function" then
				error("Goals.registerSource(name, spec): spec.read must be a function", 2)
			end
			sources[name] = { read = spec.read, changed = spec.changed }
		end,
	}

	--------------------------------------------------------------------------
	-- Actions
	--------------------------------------------------------------------------

	part.actions = {
		skipGoals = {
			limit = { rate = 0.5, burst = 2 },
			handler = function(player: any, hidden: any): any
				if not cfg.skippable or type(hidden) ~= "boolean" then
					return false
				end
				return api.skip(player, hidden)
			end,
		},
		ackGoal = {
			limit = { rate = 1, burst = 3 },
			handler = function(player: any, goalId: any): any
				local goal = if type(goalId) == "string" then byId[goalId] else nil
				if goal == nil or type(goal.check) ~= "table" or goal.check.ack ~= true then
					return false
				end
				if refusal(player) ~= nil then
					return false
				end
				return onAck(player, goal.id)
			end,
		},
	}

	--------------------------------------------------------------------------
	-- Console
	--------------------------------------------------------------------------

	local function registerConsole()
		ctx.console.register("state", function(caller: any, userId: any): string
			if not isAdmin(caller) then
				return "goals state is for Studio or admins"
			end
			local p = findPlayer(userId)
			if p == nil then
				return "no loaded player"
			end
			local view = api.current(p)
			if view == nil then
				return `goals for {p.UserId}: none shown (chain of {#chain}, flag {if isOn()
					then "on"
					else "off"})`
			end
			return `goals for {p.UserId}: {view.id or "next"} ({view.index}/{view.count}) {view.text}`
		end, "goals state [userId]: a player's current goal (Studio or admins)")
		ctx.console.register("complete", function(_caller: any, goalId: any, userId: any): string
			if not ctx.isStudio then
				return "goals complete is Studio-only"
			end
			local p = findPlayer(userId)
			if p == nil then
				return "no loaded player"
			end
			local goal = if type(goalId) == "string" then byId[goalId] else nil
			if goal == nil then
				return `unknown goal '{tostring(goalId)}'`
			end
			local ok, why = api.complete(p, goal.id)
			return `{goal.id}: {if ok then "completed" else tostring(why)}`
		end, "goals complete <goalId> [userId]: mark a goal done (Studio)")
		ctx.console.register("reset", function(_caller: any, userId: any): string
			if not ctx.isStudio then
				return "goals reset is Studio-only"
			end
			local p = findPlayer(userId)
			if p == nil then
				return "no loaded player"
			end
			return if reset(p) then "goals reset" else "goals not reset"
		end, "goals reset [userId]: start the chain over (Studio)")
	end

	--------------------------------------------------------------------------
	-- Lifecycle
	--------------------------------------------------------------------------

	function part.init(context: any)
		ctx = context
		cfg = ctx.config
		if cfg.flag ~= nil then
			local ok, err = pcall(ctx.flags.isOn, cfg.flag)
			if not ok then
				error(`[Goals] config.flag: {tostring(err)}`, 0)
			end
		end
		for _, name in SIGNAL_NAMES do
			signals[name] = ctx.signals.new(name)
		end
		registerConsole()
	end

	function part.start(_context: any)
		initDone = true
		local errors = validate(cfg.chain)
		if #errors > 0 then
			error("[Goals] invalid config.Goals:\n  - " .. table.concat(errors, "\n  - "), 0)
		end
		useChain(table.clone(cfg.chain), cfg.chainVersion)
		-- a goal's funnel step the game's analytics.funnel doesn't list would never be logged
		local analyticsCfg = ctx.gameConfig.analytics
		for _, warning in Validate.warnings(chain, if analyticsCfg ~= nil then analyticsCfg.funnel else nil) do
			ctx.log.warn(`[Goals] {warning}`)
		end

		enabled = enabledMap()
		for moduleName, names in DIRTY_SIGNALS do
			if enabled[moduleName] then
				local depApi = ctx.deps[OPTIONAL[moduleName]]
				for _, signalName in names do
					local handler: any
					if signalName == "Progressed" then
						handler = onProgressed
					elseif moduleName == "Quests" then
						handler = onQuestSignal -- Completed, Claimed (player, questId)
					elseif signalName == "CurrencyChanged" then
						handler = onCurrency
					else
						handler = onSource(SIGNAL_SOURCE[signalName])
					end
					depApi.signals[signalName]:Connect(handler)
				end
			end
		end
		for name, spec in sources do
			if spec.changed ~= nil then
				(spec.changed :: any):Connect(onSource(name))
			else
				polled[name] = true
			end
		end
		if cfg.flag ~= nil then
			ctx.flags.onChanged(cfg.flag, onFlagChanged)
		end
		ctx.data.onLoaded(function(player: any)
			anyLoaded = true
			players[player] = true
			sentWire[player] = false
			onLoaded(player)
		end)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			onRemoving(player)
			players[player] = nil
		end)
		ctx.lifecycle.onTick(1, onTick)
	end

	return part
end

return Server
