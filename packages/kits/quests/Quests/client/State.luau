--!strict
--[[
	Quests client state readers (pure). They read this module's slice of the replicated state
	(module-api.md §10: state.modules.Quests.extra = { board, progIds, prog, questOdds }) and the module's
	config (titles, objectives and rewards are not replicated: the client has the config).

	  State.loaded(state) -> boolean
	  State.board(state) -> Board?                 the raw extra.board
	  State.prog(state) -> { [questId]: { number } }  live objective values, decoded from
	        extra.progIds = { questId } and extra.prog = "3;0,12;7" (per quest of progIds, in
	        order, its values joined by "," and the quests by ";"); malformed or missing = {}
	  State.odds(state) -> { [tableId]: OddsDetail }  extra.questOdds
	  State.views(state, cfg, now?) -> { QuestView }  board order: daily slots, weekly slots, list
	        (chains, oneTime, repeatable, event), waiting. Unknown quest ids are skipped. A slot
	        view's endsAt is its set's; an event view's is state.framework.activeEvents[event].
	  State.tabsOf(views) -> { string }            "daily", "weekly", "chain", ("event"), ("waiting")
	  State.inTab(views, tab) -> { QuestView }
	  State.claimable(views) -> number             complete quests the player can claim now
	  State.firstClaimable(views) -> number?       index in `views` of the first claimable
	  State.pinned(views, pinMax) -> { QuestView } the pinned, unfinished quests, in pin order
	  State.snapshot(views) -> { [key]: { status, claims } }
	  State.transitions(prev, next) -> (completed, claimed)   ids; nothing when prev is nil (first state)
	  State.tabOf(view) -> string                  the tab a view belongs to
	  State.titleKey(cfg, id) -> string            the quest's title key
	  State.progressOf(view) -> (value, target, ratio)   every objective as one bar
	  State.resetsIn(endsAt, now) -> number        seconds, never negative
	  State.duration(seconds) -> string            "h:mm"
	  State.resetsLine(seconds) -> (key, args)     "Resets in" text: h:mm, or days + hours from 24 h on
	  State.tabEndsAt(views, tab) -> number?       the earliest endsAt of the tab's slot quests
	  State.objectiveLine(objective) -> (key, args)   the UI.text key and args of an objective line
	  State.itemName(items, id) -> string          an item's display name (the id when unknown)
	  State.rewardLine(reward, ctx?) -> (key, args)   the UI.text key and args of a reward chip

	Nothing here can write: the server owns every value.
]]

local State = {}

local NAME = "Quests"

local TITLE_PREFIX = "Quests.quest." -- a string key prefix, not display text
local DEFAULT_PIN_MAX = 3
local DEFAULT_REROLLS = { daily = 1, weekly = 0 }
local MAX_REROLLS = 3 -- the server's config ceiling (rerollsPerSlot 0..3)

State.NAME = NAME

export type View = {
	id: string,
	kind: string,
	status: string,
	slot: number?,
	periodId: number?,
	endsAt: number?,
	rerollsLeft: number?,
	claims: number?,
	cap: number?,
	pinned: boolean,
	waiting: boolean?,
	title: string,
	text: string?,
	objectives: { any },
	reward: { any },
}

local function extra(state: any): any
	if type(state) ~= "table" or type(state.modules) ~= "table" then
		return nil
	end
	local slice = state.modules[NAME]
	return if type(slice) == "table" then slice.extra else nil
end

function State.loaded(state: any): boolean
	return type(state) == "table" and state.loaded == true
end

function State.board(state: any): any
	local e = extra(state)
	if type(e) ~= "table" or type(e.board) ~= "table" then
		return nil
	end
	return e.board
end

-- the most objectives a quest has (Validate's limit); more values than this are cut
local MAX_OBJECTIVES = 4

function State.prog(state: any): { [string]: { number } }
	local e = extra(state)
	local out: { [string]: { number } } = {}
	if type(e) ~= "table" or type(e.progIds) ~= "table" or type(e.prog) ~= "string" then
		return out
	end
	local ids = e.progIds
	local quests = string.split(e.prog, ";")
	for i = 1, math.min(#ids, #quests) do
		local id = ids[i]
		if type(id) ~= "string" then
			break -- the rest can't be placed
		end
		local list: { number } = {}
		for j, text in string.split(quests[i], ",") do
			if j > MAX_OBJECTIVES then
				break
			end
			local v = tonumber(text)
			list[j] = if v ~= nil and v == v then v else 0
		end
		out[id] = list
	end
	return out
end

function State.odds(state: any): { [string]: any }
	local e = extra(state)
	return if type(e) == "table" and type(e.questOdds) == "table" then e.questOdds else {}
end

local function num(v: any, default: number): number
	return if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then v else default
end

local function statusOf(s: any): string
	if s == 0 then
		return "active"
	elseif s == 1 then
		return "complete"
	elseif s == 2 then
		return "claimed"
	end
	return "locked"
end

-- The quest's config entry: `cfg.quests[id]` (raw; the title key falls back to "Quests.quest.<id>").
local function questDef(cfg: any, id: any): any
	if type(id) ~= "string" or type(cfg) ~= "table" or type(cfg.quests) ~= "table" then
		return nil
	end
	local raw = cfg.quests[id]
	return if type(raw) == "table" then raw else nil
end

local function objectivesOf(def: any, values: any, done: boolean): { any }
	local out = {}
	local list = if type(def.objectives) == "table" then def.objectives else {}
	for i, o in ipairs(list) do
		local target = math.max(1, num(o.target, 1))
		local value = if done
			then target
			else math.min(
				target,
				math.max(0, math.floor(num(type(values) == "table" and values[i] or nil, 0)))
			)
		table.insert(out, {
			kind = o.kind,
			key = o.key,
			source = o.source,
			label = o.label,
			value = value,
			target = target,
		})
	end
	return out
end

local function rewardsOf(def: any): { any }
	return if type(def.reward) == "table" then def.reward else {}
end

local function pinSet(board: any): { [string]: number }
	local out: { [string]: number } = {}
	if type(board.pins) == "table" then
		for i, id in ipairs(board.pins) do
			if type(id) == "string" then
				out[id] = i
			end
		end
	end
	return out
end

local function rerollsLeft(cfg: any, kind: string, used: any): number
	local section = if type(cfg) == "table" and type(cfg[kind]) == "table" then cfg[kind] else nil
	local per = num(if section then section.rerollsPerSlot else nil, DEFAULT_REROLLS[kind] or 0)
	return math.max(0, math.min(per, MAX_REROLLS) - math.max(0, num(used, 0)))
end

function State.views(state: any, cfg: any, now: number?): { View }
	local board = State.board(state)
	if board == nil then
		return {}
	end
	local prog = State.prog(state)
	local pins = pinSet(board)
	local out: { View } = {}
	-- The server sends no end time for an event quest's row: its window ends with the framework's
	-- event (state.framework.activeEvents = { [eventId] = endsAt }, module-api.md §10).
	local activeEvents = if type(state.framework) == "table"
			and type(state.framework.activeEvents) == "table"
		then state.framework.activeEvents
		else {}

	local function push(id: any, kind: string, status: string, extraFields: { [string]: any }): View?
		local def = questDef(cfg, id)
		if def == nil then
			return nil
		end
		local done = status == "claimed" or status == "complete"
		local view: View = {
			id = id,
			kind = kind,
			status = status,
			pinned = pins[id] ~= nil and extraFields.waiting ~= true,
			title = if type(def.title) == "string" then def.title else TITLE_PREFIX .. id,
			text = if type(def.text) == "string" then def.text else nil,
			objectives = objectivesOf(def, prog[id], done),
			reward = rewardsOf(def),
		} :: any
		for k, v in extraFields do
			(view :: any)[k] = v
		end
		table.insert(out, view)
		return view
	end

	for _, kind in { "daily", "weekly" } do
		local set = board[if kind == "daily" then "day" else "week"]
		if type(set) == "table" and type(set.slots) == "table" then
			for i, slot in ipairs(set.slots) do
				if type(slot) == "table" then
					push(slot.q, kind, statusOf(slot.s), {
						slot = i,
						periodId = set.id,
						endsAt = set.endsAt,
						rerollsLeft = rerollsLeft(cfg, kind, slot.r),
					})
				end
			end
		end
	end

	if type(board.list) == "table" then
		for _, entry in ipairs(board.list) do
			if type(entry) == "table" then
				local def = questDef(cfg, entry.q)
				if def ~= nil then
					push(
						entry.q,
						if type(def.kind) == "string" then def.kind else "chain",
						statusOf(entry.s),
						{
							endsAt = if def.kind == "event" and type(def.event) == "string"
								then (if type(activeEvents[def.event]) == "number"
									then activeEvents[def.event]
									else nil)
								else nil,
							claims = entry.k,
							cap = if entry.cap ~= nil
								then entry.cap
								else (if def.kind == "repeatable" then num(def.cap, 1) else nil),
							periodId = entry.p,
						}
					)
				end
			end
		end
	end

	if type(board.waiting) == "table" then
		for _, w in ipairs(board.waiting) do
			if type(w) == "table" then
				push(w.q, if type(w.k) == "string" then w.k else "daily", "complete", {
					waiting = true,
					periodId = w.p,
				})
			end
		end
	end

	local _ = now
	return out
end

local TAB_OF_KIND: { [string]: string } = {
	daily = "daily",
	weekly = "weekly",
	event = "event",
}

local function tabOf(view: View): string
	if view.waiting == true then
		return "waiting"
	end
	return TAB_OF_KIND[view.kind] or "chain"
end

State.tabOf = tabOf

function State.tabsOf(views: { View }): { string }
	local has: { [string]: boolean } = {}
	for _, v in views do
		has[tabOf(v)] = true
	end
	local tabs = { "daily", "weekly", "chain" }
	if has.event then
		table.insert(tabs, "event")
	end
	if has.waiting then
		table.insert(tabs, "waiting")
	end
	return tabs
end

function State.inTab(views: { View }, tab: string): { View }
	local out = {}
	for _, v in views do
		if tabOf(v) == tab then
			table.insert(out, v)
		end
	end
	return out
end

local function claimable(v: View): boolean
	return v.status == "complete"
end

function State.claimable(views: { View }): number
	local n = 0
	for _, v in views do
		if claimable(v) then
			n += 1
		end
	end
	return n
end

function State.firstClaimable(views: { View }): number?
	for i, v in ipairs(views) do
		if claimable(v) then
			return i
		end
	end
	return nil
end

function State.pinned(views: { View }, pinMax: number?): { View }
	local board: { View } = {}
	for _, v in views do
		if v.pinned and v.status ~= "claimed" and v.status ~= "locked" then
			table.insert(board, v)
		end
	end
	local order: { [string]: number } = {}
	for i, v in ipairs(views) do
		if order[v.id] == nil then
			order[v.id] = i
		end
	end
	local limit = math.max(0, math.floor(num(pinMax, DEFAULT_PIN_MAX)))
	local out = {}
	for _, v in board do
		if #out >= limit then
			break
		end
		table.insert(out, v)
	end
	return out
end

local function keyOf(v: View): string
	if v.waiting then
		return `{v.id}@w{tostring(v.periodId)}`
	end
	return v.id
end

function State.snapshot(views: { View }): { [string]: { status: string, claims: number } }
	local out = {}
	for _, v in views do
		out[keyOf(v)] =
			{ status = v.status, claims = num(v.claims, 0), waiting = v.waiting == true, id = v.id }
	end
	return out :: any
end

-- Which quests turned complete or got claimed between two snapshots. `prev == nil` (the first state
-- after joining) fires nothing. A waiting entry leaving the list counts as a claim only for quests
-- that aren't current again (a reset moves a slot to waiting, it never fires).
function State.transitions(prev: any, nextSnap: any): ({ string }, { string })
	local completed: { string } = {}
	local claimed: { string } = {}
	if prev == nil then
		return completed, claimed
	end
	for key, now in nextSnap do
		local before = prev[key]
		if before ~= nil and not now.waiting then
			if now.status == "complete" and before.status ~= "complete" and before.status ~= "claimed" then
				table.insert(completed, now.id)
			end
			if (now.status == "claimed" and before.status ~= "claimed") or now.claims > before.claims then
				table.insert(claimed, now.id)
			end
		end -- a quest that appears already complete (done offline) is not a live completion
	end
	for key, before in prev do
		if before.waiting and nextSnap[key] == nil then
			table.insert(claimed, before.id)
		end
	end
	table.sort(completed)
	table.sort(claimed)
	return completed, claimed
end

-- The quest's title key (the config's, else "Quests.quest.<id>").
function State.titleKey(cfg: any, id: string): string
	local def = questDef(cfg, id)
	return if def ~= nil and type(def.title) == "string" then def.title else TITLE_PREFIX .. id
end

-- All objectives of a quest as one bar: (value, target, ratio 0..1).
function State.progressOf(view: View): (number, number, number)
	local value, target = 0, 0
	for _, o in view.objectives do
		value += o.value
		target += o.target
	end
	if view.status == "complete" or view.status == "claimed" then
		value = target
	end
	return value, target, if target > 0 then math.min(1, value / target) else 0
end

function State.resetsIn(endsAt: any, now: number): number
	if type(endsAt) ~= "number" then
		return 0
	end
	return math.max(0, math.ceil(endsAt - now))
end

-- "h:mm" (hours are not capped: a week is "168:00").
function State.duration(seconds: number): string
	local s = math.max(0, math.floor(num(seconds, 0)))
	local minutes = math.ceil(s / 60)
	return string.format("%d:%02d", minutes // 60, minutes % 60)
end

-- The "Resets in" text: h:mm below a day, "{days}d {hours}h" from 24 h on (a week is "7d 0h",
-- not "168:00"). Returns the UI.text key and its args.
function State.resetsLine(seconds: number): (string, { [string]: any })
	local s = math.max(0, math.floor(num(seconds, 0)))
	local minutes = math.ceil(s / 60)
	if minutes >= 24 * 60 then
		local hours = minutes // 60 -- a part hour counts as a full one: never shows less time than is left
		if minutes % 60 ~= 0 then
			hours += 1
		end
		return "Quests.resetsInDays", { days = hours // 24, hours = hours % 24 }
	end
	return "Quests.resetsIn", { time = State.duration(s) }
end

function State.tabEndsAt(views: { View }, tab: string): number?
	local best: number? = nil
	for _, v in State.inTab(views, tab) do
		if v.endsAt ~= nil and (best == nil or v.endsAt < best) then
			best = v.endsAt
		end
	end
	return best
end

function State.objectiveLine(objective: any): (string, { [string]: any })
	if type(objective.label) == "string" then
		return objective.label, {}
	end
	local kind = objective.kind
	if kind == "source" then
		return "Quests.objective.source", { source = objective.source or "" }
	elseif kind == "threshold" then
		return "Quests.objective.threshold", { target = objective.target, source = objective.source or "" }
	elseif kind == "ack" then
		return "Quests.objective.ack", { key = objective.key or "" }
	end
	return "Quests.objective.counter", { key = objective.key or "" }
end

-- The display name of an item id from GameConfig.items (the catalog list of { id, name, ... }; a map
-- id -> def also works); the id itself when the catalog doesn't know it.
function State.itemName(items: any, id: any): any
	if type(items) ~= "table" then
		return id
	end
	local def = items[id]
	if type(def) ~= "table" then
		def = nil
		for _, entry in items do
			if type(entry) == "table" and entry.id == id then
				def = entry
				break
			end
		end
	end
	return if type(def) == "table" and type(def.name) == "string" then def.name else id
end

-- ctx = { items = GameConfig.items?, primaryCurrency = string? }
function State.rewardLine(reward: any, ctx: any?): (string, { [string]: any })
	local c = ctx or {}
	local kind = reward.kind
	if kind == "currency" then
		return "Quests.reward.currency",
			{ amount = reward.amount, currency = reward.currency or c.primaryCurrency or "Coins" }
	elseif kind == "item" then
		local name = State.itemName(c.items, reward.item)
		if type(reward.count) == "number" and reward.count > 1 then
			return "Quests.reward.item", { item = `{name} x{reward.count}` }
		end
		return "Quests.reward.item", { item = name }
	elseif kind == "roll" then
		return "Quests.reward.roll", { table = reward.table }
	end
	return "Quests.reward.custom", {}
end

return State
