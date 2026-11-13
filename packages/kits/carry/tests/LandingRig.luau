--!nocheck
--[[
	LandingRig: the hard-landing scenarios (CarryHardLanding.spec), on Scenarios.rig (the REAL Carry, with the
	REAL Movement or without it). Not a spec.

	Every scenario returns the rig after picking up a crate and running; `rig:dropReasons()` is the verdict.
	  L.fall(o)       walk off a ledge and fall `drop` studs (o.shift moves the landing inside the 0.1 s tick)
	  L.jumping(o)    jump repeatedly on flat ground for o.seconds (o.v0 the jump velocity)
	  L.stepDown(o)   jump down an o.step-stud step every jump (a descending staircase of one step per jump)
	  L.stairs(o)     walk down a staircase (1-stud steps) or a ramp of o.height studs
	  L.platform(o)   ride a tagged platform down o.height studs at o.speed
	  L.terrain(o, ground, boxes, path)   any ground profile (L.stairsTerrain / L.terraces / L.rampLedge) walked
	                  along `path` (L.jumpOn: follows the ground with one jump; L.walker: gravity integrated)
	Common o: movement (false | config), seed, jitter (true = rtt300), hitchAt (a server hitch at that time,
	relative to the pick-up), jump (FakeWorld humanoid options: jumpPower/useJumpPower/jumpHeight/jumpVelocity).
]]
local S = require("packages/kits/carry/tests/Scenarios.luau")
local V, G = S.V, S.G

local L = {}
L.S = S

-- the crate's pick-up time on every rig: settle() runs 0.6 s
local PICKUP = 0.6

-- the client path of a jumper: walks +X at `speed` and jumps at v0 every 1.2-2.5 s; each jump lands `step`
-- studs lower than it took off (step 0 = flat ground)
function L.jumpPath(seed, start, speed, v0, step)
	local r = S.lcg(seed + 2000)
	local jumps = {}
	local t = 1 + r()
	for _ = 1, 400 do
		table.insert(jumps, t)
		t += 1.2 + r() * 1.3
	end
	local air = (v0 + math.sqrt(v0 * v0 + 2 * G * step)) / G
	return function(s)
		local base = start.y
		for _, j in jumps do
			if s < j then
				break
			end
			local u = s - j
			if u < air then
				return V(start.x + speed * s, base + v0 * u - 0.5 * G * u * u, start.z)
			end
			base -= step
		end
		return V(start.x + speed * s, base, start.z)
	end
end

-- walking +X down a staircase from x = x0: `steps` steps of 1 stud rise and `run` studs run, each step a short
-- fall under gravity (how a character steps down); ramp = true: a straight slope instead
function L.stairsPath(start, speed, x0, height, run, ramp, delay)
	return function(s)
		local x = start.x + speed * math.max(0, s - (delay or 0))
		local d = x - x0
		if d <= 0 then
			return V(x, start.y, start.z)
		end
		local total = height * run
		if d >= total then
			return V(x, start.y - height, start.z)
		end
		if ramp then
			return V(x, start.y - d / run, start.z)
		end
		-- the step being stepped off: k full steps down, then a fall of up to 1 stud
		local k = math.floor(d / run)
		local u = (d - k * run) / speed -- seconds since stepping off step k
		return V(x, start.y - k - math.min(1, 0.5 * G * u * u), start.z)
	end
end

local function hitchAt(rig, at, seconds)
	-- run until `at` (seconds after the pick-up), hitch, then the caller runs the rest
	rig:run(math.max(0, at))
	rig:hitch(seconds or 0.45)
end

local function finish(rig, o, total)
	if o.hitchAt then
		hitchAt(rig, o.hitchAt, o.hitchSeconds)
		rig:run(math.max(0, total - o.hitchAt - (o.hitchSeconds or 0.45)))
	elseif o.hitches then
		rig:runWithHitches(total, o.seed)
	else
		rig:run(total)
	end
	return rig
end

local function player(rig, path, o)
	local po = {
		path = path,
		jitter = if o.jitter then S.jitter.rtt300 else nil,
		ping = if o.jitter then 0.3 else nil,
	}
	for k, v in o.jump or {} do
		po[k] = v
	end
	return rig:player(1, po)
end

-- hard landing is opt-in (off in the module defaults): every landing scenario runs with it on at 55 unless the
-- scenario sets dropRules.hardLandingSpeed itself
local function withHardLanding(carry: any?): any
	local c = table.clone(carry or {})
	local rules = table.clone(c.dropRules or {})
	if rules.hardLandingSpeed == nil then
		rules.hardLandingSpeed = 55
	end
	c.dropRules = rules
	return c
end

local function rigOf(o, extra)
	local ro = { seed = o.seed or 1, movement = o.movement, ground = false, carry = withHardLanding(o.carry) }
	for k, v in extra or {} do
		ro[k] = v
	end
	return S.rig(ro)
end

-- walk off a ledge at x = 10 (10 studs/s) and fall o.drop studs; the landing is at client time
-- 1 - shift/10 + sqrt(2 drop / g)
function L.fall(o)
	local rig = rigOf(o)
	local shift = o.shift or 0
	rig:box(V(0, -0.5, 0), V(20, 1, 20))
	rig:box(V(60, -o.drop - 0.5, 0), V(100, 1, 40))
	local p = player(rig, S.ledge(V(shift, 3, 0), 10, 10, o.drop), o)
	local crate = rig:crate(V(shift, 1, -3))
	rig:settle()
	assert(rig.carry.pickUp(p, crate), "pickUp")
	rig.p, rig.crate = p, crate
	if o.before then
		o.before(rig)
	end
	return finish(rig, o, o.seconds or 6)
end

-- the client time a ledge fall lands (L.fall)
function L.landAt(drop, shift)
	return 1 - (shift or 0) / 10 + math.sqrt(2 * drop / G)
end

-- jump on flat ground (step = 0) or down a step per jump, walking +X at 12 studs/s
function L.jumping(o)
	local rig = rigOf(o, { ground = if (o.step or 0) == 0 then 0 else -1000 })
	if (o.step or 0) > 0 then
		rig:box(V(0, -0.5, 0), V(60, 1, 60))
	end
	local p = player(rig, L.jumpPath(o.seed or 1, V(0, 3, 0), 12, o.v0, o.step or 0), o)
	local crate = rig:crate()
	rig:settle()
	assert(rig.carry.pickUp(p, crate), "pickUp")
	rig.p, rig.crate = p, crate
	return finish(rig, o, o.seconds or 30)
end

-- walk down a staircase (1-stud steps, `run` studs deep) or a ramp of o.height studs at o.speed (16)
function L.stairs(o)
	local rig = rigOf(o)
	local height, run, speed = o.height or 20, o.run or 1.5, o.speed or 16
	local x0 = 12
	local top = height
	rig:box(V(x0 - 20, top - 0.5, 0), V(40, 1, 20)) -- the top landing
	if o.ramp then
		-- a slope stands in as thin boxes (the fake ground cast only needs something under the feet)
		for i = 0, height * 4 - 1 do
			local y = top - (i + 1) / 4
			rig:box(V(x0 + (i + 0.5) * run / 4, y - 0.5, 0), V(run / 4, 1, 20))
		end
	else
		for k = 1, height do
			rig:box(V(x0 + (k - 0.5) * run, top - k - 0.5, 0), V(run, 1, 20))
		end
	end
	rig:box(V(x0 + height * run + 60, -0.5, 0), V(120, 1, 20)) -- the bottom floor
	local p = player(rig, L.stairsPath(V(0, top + 3, 0), speed, x0, height, run, o.ramp, 1), o)
	local crate = rig:crate(V(0, top + 1, -3))
	rig:settle()
	assert(rig.carry.pickUp(p, crate), "pickUp")
	rig.p, rig.crate = p, crate
	return finish(rig, o, o.seconds or (1 + x0 / speed + height * run / speed + 3))
end

-- stand on a tagged platform that descends o.height studs at o.speed studs/s, starting 1 s after the pick-up
function L.platform(o)
	local rig = rigOf(o)
	local height, speed = o.height or 20, o.speed or 12
	local y0 = height
	local t0 = PICKUP + 1
	local function platY(t)
		return y0 - math.clamp((t - t0) * speed, 0, height)
	end
	rig:box(V(0, y0 - 1, 0), V(30, 2, 30), { "CarryLift" }, {
		motion = function(t)
			return S.CF.new(V(0, platY(t) - 1, 0))
		end,
	})
	rig:box(V(0, -0.5, 0), V(200, 1, 200)) -- the floor under the lift's bottom stop... far below its top
	local path = function(s)
		return V(0, platY(s) + 3, 0)
	end
	local p = player(rig, path, o)
	local crate = rig:crate(V(0, y0 + 1, -3))
	rig:settle()
	assert(rig.carry.pickUp(p, crate), "pickUp")
	rig.p, rig.crate = p, crate
	return finish(rig, o, o.seconds or (1 + height / speed + 3))
end

-- the count of hardLanding drops on a finished rig
function L.hard(rig)
	local n = 0
	for _, r in rig:dropReasons() do
		if r == "hardLanding" then
			n += 1
		end
	end
	return n
end

-- Chained terrain (CarryLandingChains.spec): a ground profile `ground(x)` (feet height under x) with the boxes that
-- make it, walked +X.

-- a staircase (1-stud steps `run` deep) or a ramp from x0 down `height` studs: the top landing before it at
-- `height`, the floor at 0 after it
function L.stairsTerrain(x0, height, run, ramp)
	local ground = function(x)
		local d = x - x0
		if d <= 0 then
			return height
		end
		if d >= height * run then
			return 0
		end
		if ramp then
			return height - d / run
		end
		return height - math.ceil(d / run)
	end
	local boxes = { { V(x0 - 20, height - 0.5, 0), V(40, 1, 20) } }
	if ramp then
		-- a slope stands in as thin boxes (the cast only needs something under the feet)
		for i = 0, height * 4 - 1 do
			table.insert(
				boxes,
				{ V(x0 + (i + 0.5) * run / 4, height - (i + 1) / 4 - 0.5, 0), V(run / 4, 1, 20) }
			)
		end
	else
		for k = 1, height do
			table.insert(boxes, { V(x0 + (k - 0.5) * run, height - k - 0.5, 0), V(run, 1, 20) })
		end
	end
	table.insert(boxes, { V(x0 + height * run + 60, -0.5, 0), V(120, 1, 20) })
	return ground, boxes
end

-- terraces: `n` ledges of `h` studs from x0, `tread` studs apart, the top at `top`
function L.terraces(top, x0, h, tread, n)
	local ground = function(x)
		if x < x0 then
			return top
		end
		return top - math.min(n, math.floor((x - x0) / tread) + 1) * h
	end
	local boxes = { { V(x0 - 20, top - 0.5, 0), V(40, 1, 20) } }
	for k = 1, n - 1 do
		table.insert(boxes, { V(x0 + (k - 0.5) * tread, top - k * h - 0.5, 0), V(tread, 1, 20) })
	end
	table.insert(boxes, { V(x0 + (n - 1) * tread + 60, top - n * h - 0.5, 0), V(120, 1, 20) })
	return ground, boxes
end

-- a ramp from x0 down `rampHeight` studs (run 1.5), then a `ledge`-stud ledge to the floor at 0
function L.rampLedge(x0, rampHeight, ledge)
	local top = rampHeight + ledge
	local x1 = x0 + rampHeight * 1.5
	local ground = function(x)
		if x < x0 then
			return top
		elseif x < x1 then
			return top - (x - x0) / 1.5
		end
		return 0
	end
	local boxes = { { V(x0 - 20, top - 0.5, 0), V(40, 1, 20) }, { V(x1 + 63, -0.5, 0), V(126, 1, 20) } }
	for i = 0, rampHeight * 4 - 1 do
		table.insert(boxes, { V(x0 + (i + 0.5) * 1.5 / 4, top - (i + 1) / 4 - 0.5, 0), V(1.5 / 4, 1, 20) })
	end
	return ground, boxes
end

-- follows the ground (root = ground + 3) walking +X at `speed` after `delay`; one jump at v0 at client time `jumpAt`
-- (the arc from the takeoff's ground until it meets the ground again)
function L.jumpOn(ground, speed, v0, jumpAt, delay)
	return function(s)
		local x = speed * math.max(0, s - delay)
		local base = ground(x) + 3
		if jumpAt ~= nil and s >= jumpAt then
			local u = s - jumpAt
			local arc = ground(speed * math.max(0, jumpAt - delay)) + 3 + v0 * u - 0.5 * G * u * u
			if arc > base then
				return V(x, arc, 0)
			end
		end
		return V(x, base, 0)
	end
end

-- a walker with gravity integrated (1/600 s) over the ground, snapped onto it, walking +X at `speed` after `delay`;
-- jumps (client times) at v0 when on the ground
function L.walker(ground, speed, delay, jumps, v0, total)
	local dt = 1 / 600
	local ys = {}
	local y = ground(0) + 3
	local vy = 0
	local nextJump = 1
	local n = math.floor(total / dt) + 2
	for i = 0, n do
		local s = i * dt
		local gy = ground(speed * math.max(0, s - delay)) + 3
		if jumps[nextJump] ~= nil and s >= jumps[nextJump] and y <= gy + 1e-6 then
			vy = v0
			nextJump += 1
		end
		vy -= G * dt
		y += vy * dt
		if y <= gy then
			y, vy = gy, 0
		end
		ys[i] = y
	end
	return function(s)
		return V(speed * math.max(0, s - delay), ys[math.clamp(math.floor(s / dt), 0, n)], 0)
	end
end

-- pick up a crate at the start of `ground` (built from `boxes`), follow `path`, run o.seconds
function L.terrain(o, ground, boxes, path)
	local rig = rigOf(o)
	for _, b in boxes do
		rig:box(b[1], b[2])
	end
	local p = player(rig, path, o)
	local crate = rig:crate(V(0, ground(0) + 1, -3))
	rig:settle()
	assert(rig.carry.pickUp(p, crate), "pickUp")
	rig.p, rig.crate = p, crate
	if o.before then
		o.before(rig)
	end
	return finish(rig, o, o.seconds or 8)
end

-- every event after the pick-up, as "Dropped:<reason>" / "<name>"
function L.events(rig)
	local out = {}
	for _, e in rig.log do
		if e.name == "Dropped" then
			table.insert(out, "Dropped:" .. tostring(e.args[2]))
		elseif e.name ~= "PickedUp" then
			table.insert(out, e.name)
		end
	end
	return table.concat(out, ",")
end

L.PICKUP = PICKUP
return L
