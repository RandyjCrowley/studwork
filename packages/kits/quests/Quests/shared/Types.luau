--!strict
--[[
	Quests: the shared types (docs/framework/kits/quests.md). Pure type declarations plus the id rule;
	both sides require this file.
]]

local Types = {}

export type QuestKind = "daily" | "weekly" | "chain" | "oneTime" | "repeatable" | "event"
export type SlotKind = "daily" | "weekly"

export type Objective = {
	kind: "counter" | "source" | "threshold" | "ack",
	key: string?, -- counter, ack
	source: string?, -- source, threshold
	target: number?, -- counter, source, threshold: an integer 1..1e9
	params: { [string]: any }?,
	label: string?, -- a string key for the objective's line
}

export type Reward = {
	kind: "currency" | "item" | "roll" | "custom",
	amount: number?, -- currency
	currency: string?, -- currency
	item: string?, -- item
	count: number?, -- item, 1..10
	table: string?, -- roll
	handler: string?, -- custom
	params: { [string]: any }?, -- custom
}

export type Requires = {
	quests: { string }?,
	rebirths: number?,
	items: { string }?,
}

-- A config entry (`config.Quests.quests[id]`); `def(id)` returns it frozen with defaults filled in.
export type Quest = {
	id: string,
	kind: QuestKind,
	objectives: { Objective },
	reward: { Reward },
	title: string,
	text: string?,
	weight: number,
	requires: Requires?,
	cap: number,
	period: SlotKind,
	event: string?,
	offer: "auto" | "grant",
	autoClaim: boolean,
	retired: boolean,
	funnel: string?,
}

export type Config = {
	flag: string?,
	quests: { [string]: any },
	chains: { [string]: { string } },
	daily: { count: number, rerollsPerSlot: number },
	weekly: { count: number, rerollsPerSlot: number },
	poolVersion: number,
	utcOffsetHours: number,
	weekStartsOn: "monday" | "sunday",
	autoClaim: boolean,
	waitingMax: number,
	pinMax: number,
	foldSeconds: number,
	replicateSeconds: number,
	sourcePollSeconds: number,
	rotatePerTick: number,
	maxAmount: number,
}

export type QuestView = {
	id: string,
	kind: string,
	status: "active" | "complete" | "claimed",
	slot: number?,
	periodId: number?,
	endsAt: number?,
	rerollsLeft: number?,
	claims: number?,
	cap: number?,
	pinned: boolean,
	waiting: boolean?,
	objectives: { { kind: string, key: string?, source: string?, value: number, target: number } },
	reward: { any }, -- the frozen config rewards
}

export type QuestState = {
	status: "locked" | "available" | "active" | "complete" | "claimed" | "inactive",
	values: { number }?,
	claims: number?,
	periodId: number?,
}

-- A value source (the `registerSource` extension): `read` must not yield; nil = no value yet.
export type SignalLike = { Connect: (any, (player: any) -> ()) -> any }
export type SourceSpec = { read: (player: any) -> number?, changed: SignalLike? }
export type RewardFn = (tx: any, player: any, params: any, questId: string) -> ()

-- The save section ("quests", version 1).
export type Slot = { q: string, n: { number }, s: number, r: number } -- s: 0 active, 1 complete, 2 claimed
export type SlotSet = { id: number, slots: { Slot }, seen: { [string]: boolean } }
export type Prog = { n: { number }, s: number, p: number?, k: number? }
export type Waiting = { q: string, k: "daily" | "weekly" | "event", p: number }
export type Section = {
	day: SlotSet,
	week: SlotSet,
	prog: { [string]: Prog },
	done: { [string]: number },
	waiting: { Waiting },
	pins: { string },
	granted: { [string]: boolean },
}

-- extra.board (per player)
export type BoardSet = { id: number, endsAt: number, slots: { { q: string, s: number, r: number } } }
export type Board = {
	day: BoardSet?,
	week: BoardSet?,
	list: { { q: string, s: number, k: number?, cap: number?, p: number? } },
	waiting: { { q: string, k: string, p: number } },
	pins: { string },
}

Types.ID_MAX = 32

-- `^[%w_]{1,32}$` (Lua patterns have no {m,n}).
function Types.validId(id: any): boolean
	return type(id) == "string" and #id >= 1 and #id <= Types.ID_MAX and string.match(id, "^[%w_]+$") ~= nil
end

Types.QUEST_KINDS = table.freeze({ "daily", "weekly", "chain", "oneTime", "repeatable", "event" })
Types.OBJECTIVE_KINDS = table.freeze({ "counter", "source", "threshold", "ack" })
Types.REWARD_KINDS = table.freeze({ "currency", "item", "roll", "custom" })

-- Hard maxima of the save section (sanitize cuts lists here; config ranges stay inside them).
Types.MAX_SLOTS = 6
Types.MAX_VALUES = 4
Types.MAX_WAITING = 12
Types.MAX_PINS = 5
Types.MAX_OBJECTIVES = 4
Types.MAX_REWARDS = 4

return table.freeze(Types)
