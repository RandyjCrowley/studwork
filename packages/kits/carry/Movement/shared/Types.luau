--!strict
--[[
	Movement's public types (docs/framework/kits/carry.md, "Movement"): check names, volume kinds,
	responses, strikes and the API. Types only, no values.
]]

local World = require(script.Parent.World)

export type World = World.World

export type CheckName = "speed" | "teleport" | "volumeSweep" | "noGround" | "wallSweep" | "riseSpeed"
export type VolumeKind = "hazard" | "noEntry" | "checkpoint" | "platform" | "climbable"
export type Response = "log" | "strike" | "resetPosition" | "disqualifyRun"

export type Strike = {
	reason: CheckName,
	at: number,
	response: Response,
	details: { [string]: any },
}

export type MovementAPI = {
	startRun: (player: Player, runId: string) -> (),
	endRun: (player: Player, runId: string) -> (boolean, { Strike }), -- unknown/ended runId: (false, {})
	teleport: (player: Player, cframe: CFrame) -> (),
	exempt: (player: Player, seconds: number?, reason: string) -> (),
	strikes: (player: Player) -> { Strike },
	lastValid: (player: Player) -> (CFrame?, boolean), -- (accepted, trusted)
	-- false while the flag is off or no World is attached, and (with a player) until that player's fresh baseline
	-- after the flag turns back on: a caller then uses its own fallback (Carry: the raw root and its clamp)
	active: (player: Player?) -> boolean,
	velocity: (player: Player) -> Vector3?,
	registerVolume: (tag: string, kind: VolumeKind) -> (),
	registerPlatformSource: (fn: (part: BasePart, t: number) -> Vector3) -> (),
	setSpeedCap: (player: Player, studsPerSec: number?) -> (),
	setResponse: (check: CheckName, response: Response) -> (),
	useWorld: (world: World) -> (),
}

return {}
