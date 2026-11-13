--!strict
--[[
	Caps: the per-sample and window limits of Movement (carry.md, "Worked numbers"; frozen, probe-verified,
	implemented as written). Pure functions of numbers, no World.

	  effCap        = max(speedCap, walkSpeed) x speedSlack                                  18.40 studs/s
	  teleportCap   = effCap x (dt + lag) + slack + platformSpeed x lag                      13.88 studs at dt 0.1
	  windowLimit   = effCap x (span + lag) + slack + platformSpeed x lag                    85.64 studs per 4 s
	  maxDrop       = vDown x T + 1/2 g'' T^2 + slack + platformDown x T, T = dt + lag       56.28 studs from standing
	  riseCap       = max(jumpVelocity, walkSpeed) x launchSlack x speedSlack x (dt + lag) + slack   45.27 studs
	  respawn envelope: horizontal <= reach + effCap x e; -(reach + 1/2 g'' e^2) <= dy <= reach + apex
	`lag` is always the teleport lag (Lag.teleportLag).
]]

local Caps = {}

function Caps.effectiveSpeed(speedCap: number, walkSpeed: number, speedSlack: number): number
	return math.max(speedCap, walkSpeed) * speedSlack
end

-- `literal` (config teleport.capStuds) replaces the formula
function Caps.teleportCap(
	effCap: number,
	dt: number,
	lag: number,
	slackStuds: number,
	platformSpeed: number,
	literal: number?
): number
	if literal ~= nil then
		return literal
	end
	return effCap * (dt + lag) + slackStuds + platformSpeed * lag
end

function Caps.windowLimit(
	effCap: number,
	span: number,
	lag: number,
	slackStuds: number,
	platformSpeed: number
): number
	return effCap * (span + lag) + slackStuds + platformSpeed * lag
end

-- The largest legal drop between two samples (a positive number of studs). `sinceGround` is the time since
-- the last grounded sample; `wasGrounded` is whether the previous sample was grounded (then vDown = 0).
function Caps.maxDrop(
	gravity: number,
	gravitySlack: number,
	dt: number,
	lag: number,
	slackStuds: number,
	wasGrounded: boolean,
	sinceGround: number,
	platformDownSpeed: number
): number
	local gDown = gravity * (1 + gravitySlack)
	local T = dt + lag
	local vDown = if wasGrounded then 0 else gDown * (sinceGround + lag)
	return vDown * T + 0.5 * gDown * T * T + slackStuds + platformDownSpeed * T
end

-- `speedCapOverride` (config rise.speedCap) replaces max(jumpVelocity, walkSpeed) x launchSlack
function Caps.riseCap(
	jumpVelocity: number,
	walkSpeed: number,
	launchSlack: number,
	speedSlack: number,
	dt: number,
	lag: number,
	slackStuds: number,
	speedCapOverride: number?,
	platformUpSpeed: number
): number
	local base = if speedCapOverride ~= nil
		then speedCapOverride
		else math.max(jumpVelocity, walkSpeed) * launchSlack
	return (base * speedSlack + platformUpSpeed) * (dt + lag) + slackStuds
end

export type EnvelopeParams = {
	reach: number,
	effCap: number,
	lag: number,
	jumpVelocity: number,
	walkSpeed: number,
	launchSlack: number,
	gravity: number,
	gravitySlack: number,
	heightSlackStuds: number,
}

-- Is the sample inside the respawn envelope of the server-authored position (refX, refY, refZ) set at `refAt`?
-- The elapsed time is capped at the lag, so waiting buys nothing.
function Caps.inRespawnEnvelope(
	p: EnvelopeParams,
	refX: number,
	refY: number,
	refZ: number,
	refAt: number,
	now: number,
	x: number,
	y: number,
	z: number
): boolean
	local e = math.min(math.max(0, now - refAt), p.lag)
	local dx, dz = x - refX, z - refZ
	if math.sqrt(dx * dx + dz * dz) > p.reach + p.effCap * e then
		return false
	end
	local vJ = math.max(p.jumpVelocity, p.walkSpeed) * p.launchSlack
	local gUp = p.gravity * (1 - p.gravitySlack)
	local gDown = p.gravity * (1 + p.gravitySlack)
	local apex = vJ * vJ / (2 * gUp) + p.heightSlackStuds
	local dy = y - refY
	if dy > p.reach + apex then
		return false
	end
	if dy < -(p.reach + 0.5 * gDown * e * e) then
		return false
	end
	return true
end

return Caps
