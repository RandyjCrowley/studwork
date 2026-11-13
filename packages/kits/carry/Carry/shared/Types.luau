--!strict
--[[
	Carry's public types (docs/framework/kits/carry.md): the config shapes, the API, the client API
	and the signal payload vocabularies. Types only, no values.
]]

local World = require(script.Parent.World)

export type World = World.World

export type DropRules = {
	belowMin: boolean?,
	tiltDegrees: number?,
	stretchStuds: number?,
	hardLandingSpeed: number?,
	hardLandingMarginStuds: number?,
	carrierDied: boolean?,
	carrierLeft: ("drop" | "returnToSpawn")?,
	carrierDisqualified: ("off" | "runDisqualified" | "strike")?,
	untrustedCarrier: boolean?,
	hazard: boolean?,
}

export type CarriableDef = {
	model: string?,
	massClass: string,
	carriers: { min: number, max: number },
	gripPoints: { { number } },
	speedPenalty: number,
	fragility: number,
	pickUpRadius: number?,
	killY: number?,
	dropRules: DropRules?,
}

export type CarryState = "idle" | "gathering" | "carried" | "thrown" | "dropped" | "delivered"

export type DropReason =
	"belowMin"
	| "tilt"
	| "stretch"
	| "hardLanding"
	| "carrierDied"
	| "carrierLeft"
	| "disqualified"
	| "teleport"
	| "hazard"
	| "missedThrow"
	| "manual"
	| "flagOff"
	| "removed"

export type RefusalReason =
	"notCarriable"
	| "busy"
	| "full"
	| "capacity"
	| "tooFar"
	| "disagree"
	| "untrusted"
	| "thrown"
	| "delivered"
	| "notSoleHolder"
	| "notThrowable"
	| "receiverBusy"
	| "invalidReceiver"
	| "noCharacter"
	| "off"

export type Timings = {
	startedAt: number,
	deliveredAt: number,
	perCarrierSeconds: { [number]: number }, -- keyed by UserId; world.clock() deltas
}

export type CarryAPI = {
	registerCarriable: (tag: string, def: CarriableDef) -> (),
	setDropRule: (tag: string?, rules: DropRules) -> (),
	pickUp: (player: Player, object: Instance) -> (boolean, string?),
	drop: (player: Player, object: Instance) -> boolean,
	handOff: (player: Player, object: Instance, toPlayer: Player) -> (boolean, string?),
	releasePlayer: (player: Player, reason: string) -> (),
	reportHazard: (player: Player, object: Instance) -> (),
	reset: (object: Instance, cframe: CFrame?) -> boolean,
	holders: (object: Instance) -> { Player },
	isCarrying: (player: Player) -> Instance?,
	objectOf: (objectId: string) -> Instance?,
	stateOf: (object: Instance) -> CarryState?,
	useWorld: (world: World) -> (),
}

export type Connection = { Disconnect: (self: Connection) -> () }

export type CarryClientAPI = {
	carrying: () -> string?,
	stateOf: (objectId: string) -> (CarryState, { number })?,
	onWobble: (fn: (objectId: string, angleDeg: number, phase: number) -> ()) -> Connection,
	setControls: (enabled: boolean) -> (),
}

return {}
