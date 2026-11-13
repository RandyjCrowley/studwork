--!strict
--[[
	Landing: the hard-landing decision (carry.md "dropRules", hardLandingSpeed). Pure: one Fall record per carried
	object, fed once per logic tick with the object's clamped, server-observed height.

	  Landing.new(y, t) -> Fall
	  Landing.minFall(jumpVelocity, p) -> studs      the smallest fall that drops the object
	  Landing.step(fall, t, y, moved, jumpVelocity, p, probe, arg, ty?, where?) -> number?
	      the fall height when a fall has just ended as a hard landing, else nil. `moved`: the object's pose changed
	      this tick. `ty`: the carriers' own height in the object's terms (the unclamped blend target; default `y`).
	      `where`: an opaque position the record keeps as `fall.anchor` whenever the carriers are known to stand
	      (the probe uses it). `probe(arg) -> (air, grounded, gap?, ledge?)` looks under the carriers; it is called only
	      on a tick that goes lower (fall.probes counts the calls of the open fall), so steady carrying costs nothing.
	      `gap` (default 0): how far above standing height the carriers still are when `grounded`. `ledge` (default
	      unlimited): the highest single drop in the ground along the carriers' path since `fall.anchor` (LEDGE_SLOPE).
	  Landing.pending(fall, p) -> number?
	      the height of an open fall that already qualifies (before anything else ends the carry: a delivery, a manual
	      drop, a hand-off, a throw, a release), else nil. While the last probe said a carrier was in the air, the fall
	      is measured to the ground under the carriers (where it is about to land), not to its lowest point so far.

	A fall is measured from its TOP to its TOUCHDOWN, decided there, and the next one starts from the touchdown:
	  - top: the last height the carriers stood at (`base`), or the apex after a rise. While no fall is open, a rise
	    moves top up; a lower tick with every carrier on the ground and none in the air (walking down stairs or a ramp)
	    moves top and base down to it, and so do two level moves in a row (walking on the flat): a walk down, then a
	    ledge or a jump, is measured from the last height the carriers stood at.
	  - a fall opens on the first tick lower than top. Its touchdown is the first lower tick whose probe says every
	    carrier is on the ground, once the fall saw a carrier in the air (or one caught-up step at FALL_SPEED covered
	    minFall: a freeze or hitch hid the whole fall). The touchdown height is the carriers' ground under them: the
	    lower of the object's y and `ty`, minus `gap`. So the clamp's limit on the object's fall speed per tick (the
	    object can still be above its final height when the carriers touch down) never shortens a fall, and neither
	    does a touchdown seen up to GROUND_SLACK above the ground.
	  - the fall's height is top - touchdown, but at most (top - base) + ledge: the carriers' own rise plus the
	    highest single ledge they went over. A jump while walking down stairs or a ramp falls far below its apex,
	    but the ground under it only stepped down a stair at a time; a ledge, a cliff or a hole is one drop.
	  - a fall with no touchdown seen ends on a rise of RISE_EPS above its lowest point, or after going no lower for
	    SETTLE seconds. While the last probe said a carrier was in the air, a fall that doesn't qualify yet stays open
	    up to AIR_HOLD seconds (a connection freeze or a server hitch in mid-air never splits a fall). It is decided on
	    its lowest point.
	It is a hard landing iff
	  - the fall height >= minFall: the higher of hardLandingSpeed^2 / 2g (the height a free fall needs to land at
	    hardLandingSpeed) and the carriers' highest jump apex v^2 / 2g + marginStuds, so no jump the carriers can make,
	    over a ledge of up to marginStuds, is one;
	  - it was a fall, not walking down: a carrier was seen in the air (no ground within its standing height +
	    AIR_GAP) on a lower tick, or a single observed step went down at least minFall at FALL_SPEED or faster;
	  - and fast: its fastest step was at least FALL_SPEED studs/s, each step timed from the previous pose change, so
	    a freeze then a catch-up reads as the average over the freeze, never as one huge tick (climbing down a ladder
	    is in the air too, but slow).
	The caller adds one more test the record can't make: the ground under the carriers did not itself move down
	(a lift). Heights don't depend on where in the 0.1 s tick the landing falls, or on lag: a late position is
	still a position the carriers really had.
]]

export type Params = {
	gravity: number,
	hardLandingSpeed: number,
	marginStuds: number,
}

export type Fall = {
	open: boolean,
	lastY: number, -- the object's height at the last pose change
	moveAt: number, -- the time of the last pose change
	level: number, -- level moves in a row
	top: number, -- the height the current (or next) fall is measured from
	base: number, -- the last height the carriers stood at
	anchor: any, -- the caller's `where` when `base` was set (nil until then)
	low: number, -- the open fall's lowest object height so far
	lowAt: number,
	lowWhere: any, -- the caller's `where` there
	depth: number, -- the open fall's lowest carrier height (min of y and ty) so far
	ledge: number, -- the highest single ledge under the open fall's path (probe)
	ground: number, -- the ground under the carriers at the last probe, in the object's terms
	air: boolean, -- a carrier was in the air on some lower tick of the open fall
	inAir: boolean, -- the last probe said a carrier was in the air
	speed: number, -- the fastest step down (studs/s)
	bigStep: number, -- the largest single observed step down at FALL_SPEED or faster (studs)
	jump: number, -- the highest carrier jump velocity seen during the fall
	probes: number, -- probe calls in the open fall
}

local Landing = {}

-- a tick lower than this (studs) opens or extends a fall, and a level move stays within it; a rise above the
-- lowest point by more than RISE_EPS ends a fall whose touchdown wasn't seen
Landing.DESCEND_EPS = 0.05
Landing.RISE_EPS = 0.5
-- "in the air": no ground within standing height (HipHeight + half the root) + AIR_GAP. Above a step down, a
-- character is at most about a step lower than standing; 4 studs also covers R6 (HipHeight 0, 2-stud legs).
Landing.AIR_GAP = 4
-- "on the ground": ground within standing height + GROUND_SLACK (Movement's groundedSlackStuds)
Landing.GROUND_SLACK = 1.5
-- a fall with no touchdown seen ends after this long without going lower: longer than a 0.5 s client freeze plus
-- a 0.45 s server hitch
Landing.SETTLE = 1
-- ... but while the last probe said a carrier was in the air, a fall that doesn't qualify yet stays open up to this
-- long: a connection freeze in mid-air (a lag switch) never splits a fall; past it the fall is decided on what was
-- seen (a freeze or hover longer than this escapes)
Landing.AIR_HOLD = 3
-- the fastest step of a fall: a 15-stud fall half hidden by a freeze still shows 24+ studs/s (CarryHardLanding);
-- walking down 45-degree stairs at WalkSpeed 16, or climbing down, stays under it on average
Landing.FALL_SPEED = 20
-- the ground profile (the caller's probe): a ledge is a run of ground drops each steeper than LEDGE_SLOPE (rise over
-- run: 2 is 63 degrees), sampled every LEDGE_SPACING studs along the path, at most LEDGE_SAMPLES rays per probe. A
-- stair riser (1-2 studs) is a ledge of its own height; a cliff, a hole or a steep hillside is one ledge.
Landing.LEDGE_SLOPE = 2
Landing.LEDGE_SPACING = 0.5
Landing.LEDGE_SAMPLES = 16

function Landing.new(y: number, t: number): Fall
	return {
		open = false,
		lastY = y,
		moveAt = t,
		level = 0,
		top = y,
		base = y,
		anchor = nil,
		low = y,
		lowAt = t,
		lowWhere = nil,
		depth = y,
		ledge = math.huge,
		ground = y,
		air = false,
		inAir = false,
		speed = 0,
		bigStep = 0,
		jump = 0,
		probes = 0,
	}
end

function Landing.minFall(jumpVelocity: number, p: Params): number
	local g2 = 2 * p.gravity
	return math.max(
		p.hardLandingSpeed * p.hardLandingSpeed / g2,
		jumpVelocity * jumpVelocity / g2 + p.marginStuds
	)
end

-- the open fall's height down to `land`: top - land, at most the carriers' rise plus the highest ledge
local function height(f: Fall, land: number): number
	return math.min(f.top - land, f.top - f.base + f.ledge)
end

local function qualifies(f: Fall, h: number, p: Params): boolean
	local minFall = Landing.minFall(f.jump, p)
	return h >= minFall and f.speed >= Landing.FALL_SPEED and (f.air or f.bigStep >= minFall)
end

-- the carriers stand at `y` (at `where`): the next fall is measured from here
local function stand(f: Fall, y: number, where: any)
	f.top, f.base, f.anchor = y, y, where
end

-- ends the open fall at `land` and decides it; the carriers stand at `land` (at `where`) afterwards
local function close(f: Fall, land: number, where: any, p: Params): number?
	local h = height(f, land)
	f.open = false
	f.inAir = false
	local hard = qualifies(f, h, p)
	stand(f, land, where)
	return if hard then h else nil
end

function Landing.pending(f: Fall, p: Params): number?
	if not f.open then
		return nil
	end
	-- still in the air at the last probe: it is falling onto the ground under it
	local h = height(f, if f.inAir then math.min(f.depth, f.ground) else f.depth)
	return if qualifies(f, h, p) then h else nil
end

function Landing.step(
	f: Fall,
	t: number,
	y: number,
	moved: boolean,
	jumpVelocity: number,
	p: Params,
	probe: (any) -> (boolean, boolean, number?, number?),
	arg: any,
	ty: number?,
	where: any?
): number?
	local result: number? = nil
	local carriersY = math.min(y, ty or y)
	if f.open and jumpVelocity > f.jump then
		f.jump = jumpVelocity
	end
	if moved and y < (if f.open then f.low else f.top) - Landing.DESCEND_EPS then
		-- a lower tick: open a fall, or extend the open one
		if not f.open then
			f.open = true
			f.air, f.speed, f.bigStep, f.jump, f.probes = false, 0, 0, jumpVelocity, 0
			f.depth, f.ledge = carriersY, 0
		end
		local step = f.lastY - y
		local v = step / math.max(t - f.moveAt, 1e-3)
		if v > f.speed then
			f.speed = v
		end
		if v >= Landing.FALL_SPEED and step > f.bigStep then
			f.bigStep = step
		end
		f.low, f.lowAt, f.lowWhere = y, t, where
		if carriersY < f.depth then
			f.depth = carriersY
		end
		f.probes += 1
		local air, grounded, gap, ledge = probe(arg)
		f.ledge = math.max(f.ledge, ledge or math.huge)
		f.ground = carriersY - (gap or 0)
		f.inAir = air
		if air then
			f.air = true
		end
		if grounded then
			-- touchdown (after a fall), or a supported step down (walking): the carriers' ground under them
			local land = carriersY - math.clamp(gap or 0, 0, Landing.GROUND_SLACK)
			if f.air or f.bigStep >= Landing.minFall(f.jump, p) then
				result = close(f, land, where, p)
			else
				f.open, f.inAir = false, false
				stand(f, land, where)
			end
		end
	elseif f.open then
		local idle = t - f.lowAt
		if moved and y > f.low + Landing.RISE_EPS then
			-- a rise with no touchdown seen (a jump straight off the landing): decided on the lowest point
			result = close(f, f.depth, f.lowWhere, p)
			f.top = y
		elseif
			idle >= Landing.SETTLE
			and (not f.inAir or idle >= Landing.AIR_HOLD or qualifies(f, height(f, f.depth), p))
		then
			-- no touchdown seen, and no lower for long enough: decided on the lowest point
			result = close(f, f.depth, where, p)
		end
	elseif moved and y > f.top and y > f.lastY then
		-- a rise (a jump, or walking up): the next fall is measured from its apex. (Only a real rise: an object
		-- catching up with carriers who already touched down is above `top` but going down.)
		f.top = y
	end
	if moved then
		if not f.open and math.abs(y - f.lastY) <= Landing.DESCEND_EPS then
			-- level: two level moves in a row is walking on the flat (one could be the two sides of an apex)
			f.level += 1
			if f.level >= 2 then
				stand(f, y, where)
			end
		else
			f.level = 0
		end
		f.lastY, f.moveAt = y, t
	end
	return result
end

return Landing
