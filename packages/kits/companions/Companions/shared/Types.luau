--!strict
export type Movement = "walk" | "hop" | "fly" | "hover"
export type ItemFields = {
	movement: Movement?,
	hoverHeight: number?,
	score: number?,
	incomeBonus: number?,
	look: string?,
	idleAnimation: string?,
	moveAnimation: string?,
	triangles: number?,
}
export type Save = { equipped: { string }, manual: boolean }
export type PublicCopy = { uid: string, itemId: string, mutation: string? }
export type Owner = { userId: number, equipped: { PublicCopy } }
export type Roster = { [string]: Owner }
export type Reason =
	"disabled"
	| "not_loaded"
	| "invalid_uid"
	| "not_owned"
	| "not_companion"
	| "locked"
	| "already_equipped"
	| "slots_full"
	| "not_equipped"
	| "transaction_failed"
export type Look = (model: Instance, itemDef: any) -> ()
export type Connection = { Disconnect: (self: Connection) -> () }
export type DecoratorConnection = {
	Disconnect: (self: DecoratorConnection) -> (),
	Invalidate: (self: DecoratorConnection) -> (),
}
export type DebugStats = {
	drawn: number,
	candidates: number,
	culled: number,
	parts: number,
	estimatedTriangles: number,
	unknownMeshParts: number,
	lowDetail: boolean,
}
return {}
