--!strict
--[[
	Goals: the shared types (docs/framework/kits/quests.md, "Goals"). Pure type declarations plus
	the id rule; both sides require this file.
]]

local Types = {}

-- A world position in a goal's config: { x, y, z } (array) or { x = , y = , z = } (named). On the
-- wire (extra.goal) it is always the array form (Validate.toArray).
export type ArrayPosition = { number }
export type NamedPosition = { x: number, y: number, z: number }
export type Position = ArrayPosition | NamedPosition

export type Target = {
	tag: string?, -- the nearest instance with this CollectionService tag
	path: string?, -- "Workspace.Map.Shop", resolved with FindFirstChild from the root
	position: Position?,
	picker: string?, -- a client function registered with registerPicker
}

export type Check = {
	quest: string?, -- { quest = id, on = "complete" | "claimed" } or { quest = id, objective = n }
	on: ("complete" | "claimed")?,
	objective: number?,
	source: string?, -- { source = name, atLeast = number, params? }
	atLeast: number?,
	params: { [string]: any }?,
	call: boolean?, -- { call = true }: the game calls Goals.complete
	ack: boolean?, -- { ack = true }: the client sends ackGoal(id) while it's the current goal
}

export type Goal = {
	id: string,
	text: string?, -- default "Goals.goal.<id>"
	check: Check,
	target: Target?,
	fallback: Position?,
	widget: string?,
	funnel: string?,
}

-- A chain written in code (Balance.luau): `local CHAIN: Types.Chain = { { id = ..., check = ... }, ... }`
export type Chain = { Goal }

export type Pointer = {
	beam: boolean,
	edgeArrow: boolean,
	updateSeconds: number,
	nearStuds: number,
	maxStuds: number,
}

export type Config = {
	flag: string?,
	chain: { Goal },
	chainVersion: number,
	skippable: boolean,
	nextSeconds: number,
	sourcePollSeconds: number,
	pointer: Pointer,
}

export type GoalView = {
	id: string?,
	index: number,
	count: number,
	text: string,
	args: { [string]: any }?,
	target: Target?,
	widget: string?,
	isNext: boolean,
	hidden: boolean,
}

export type NextGoal = {
	text: string,
	args: { [string]: any }?,
	target: Target?,
	widget: string?,
}

export type PointerInfo = {
	position: any?, -- Vector3
	onScreen: boolean,
	distance: number?,
	from: ("instance" | "lastKnown" | "fallback" | "position")?,
}

export type SignalLike = { Connect: (any, (player: any) -> ()) -> any }
export type SourceSpec = { read: (player: any) -> number?, changed: SignalLike? }

-- The save section ("goals", version 1). v = 0: never loaded with Goals.
export type Section = { done: { [string]: boolean }, fin: boolean, hide: boolean, v: number }

-- extra.goal (per player)
export type Wire = {
	id: string?,
	i: number,
	n: number,
	text: string,
	args: { [string]: any }?,
	target: Target?,
	widget: string?,
	next: boolean,
	hidden: boolean,
}

Types.ID_MAX = 32
Types.MAX_GOALS = 20

function Types.validId(id: any): boolean
	return type(id) == "string" and #id >= 1 and #id <= Types.ID_MAX and string.match(id, "^[%w_]+$") ~= nil
end

return table.freeze(Types)
