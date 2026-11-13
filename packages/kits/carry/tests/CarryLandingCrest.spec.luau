--!nocheck
--[[
	Hard landing after a climb, and hard landing off by default (Carry dropRules.hardLandingSpeed is opt-in).
	- A supported rise (walking up a ramp or stairs) and the pick-up itself are standing points, so a jump at a
	  crest, or a jump as the first move after a pick-up, is measured from there, not from the foot of the climb.
	- Real falls after a climb still drop.
	- With the module defaults, no fall or jump drops an object by hard landing.
	Every case: 10 takeoff times or seeds x Movement off/on x 0 ms / rtt300 jitter (Scenarios on FakeWorld); counts exact.
]]
local S = require("packages/kits/carry/tests/Scenarios.luau")
local V, G = S.V, S.G

local ON = { dropRules = { hardLandingSpeed = 55 } }

-- ground(x) plus boxes: columns of width `dx` over [xa, xb], flat slabs outside
local function build(rig, ground, xa, xb, dx)
	rig:box(V(xa - 40, ground(xa - 1) - 0.5, 0), V(80, 1, 30))
	rig:box(V(xb + 80, ground(xb + 1) - 0.5, 0), V(160, 1, 30))
	local x = xa
	while x < xb - 1e-9 do
		local w = math.min(dx, xb - x)
		rig:box(V(x + w / 2, ground(x + w / 2) - 0.5, 0), V(w, 1, 30))
		x += w
	end
end

local function jumpOn(ground, speed, v0, jumpAt, delay)
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

local function walker(ground, speed, delay, jumps, v0, total)
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

-- one run: terrain, a path, optional zone / before hook
local function trial(o)
	local rig = S.rig({ seed = o.seed or 1, movement = o.movement, ground = false, carry = o.carry })
	build(rig, o.ground, o.xa, o.xb, o.dx or 0.25)
	if o.zone then
		rig:zone(o.zone[1], o.zone[2])
	end
	local p = rig:player(1, {
		path = o.path,
		jitter = if o.jitter then S.jitter.rtt300 else nil,
		ping = if o.jitter then 0.3 else nil,
	})
	local crate = rig:crate(V(0, o.ground(0) + 1, -3))
	rig:settle()
	assert(rig.carry.pickUp(p, crate), "pickUp")
	rig.p, rig.crate = p, crate
	if o.before then
		o.before(rig)
	end
	rig:run(o.seconds or 6)
	return rig
end

local MODES = {
	{ "off 0ms", false, false },
	{ "off rtt300", false, true },
	{ "on 0ms", true, false },
	{ "on rtt300", true, true },
}

-- hardLanding drops out of 10, per mode
local function counts(carry, mk): { [string]: number }
	local out = {}
	for _, m in MODES do
		local n = 0
		for i = 1, 10 do
			local o = mk(i)
			o.movement = if m[2] then {} else false
			o.jitter = m[3]
			o.seed = i
			o.carry = carry
			local rig = trial(o)
			for _, reason in rig:dropReasons() do
				if reason == "hardLanding" then
					n += 1
				end
			end
		end
		out[m[1]] = n
	end
	return out
end

local function every(n)
	return { ["off 0ms"] = n, ["off rtt300"] = n, ["on 0ms"] = n, ["on rtt300"] = n }
end

-- a sharp hill: flat to x=12, up a 34deg ramp to 10 at x=27, down a 34deg ramp to 0 at x=42
local function hill(x)
	if x < 12 then
		return 0
	elseif x < 27 then
		return (x - 12) / 1.5
	elseif x < 42 then
		return 10 - (x - 27) / 1.5
	end
	return 0
end

-- a footbridge: up stairs (run 1.5) 8 studs over x 12..24, a `top`-stud top, down stairs 8 studs
local function bridge(top)
	return function(x)
		if x < 12 then
			return 0
		elseif x < 24 then
			return math.ceil((x - 12) / 1.5 - 1e-9)
		elseif x < 24 + top then
			return 8
		elseif x < 24 + top + 12 then
			return 8 - math.ceil((x - 24 - top) / 1.5 - 1e-9)
		end
		return 0
	end
end

-- a 20-stud staircase (run 1.5) from x=2, below a top landing
local function stairs(x)
	if x < 2 then
		return 20
	elseif x < 32 then
		return 20 - math.ceil((x - 2) / 1.5 - 1e-9)
	end
	return 0
end

-- up a 34deg ramp 10 studs, then straight off a cliff to -10: a 20-stud fall
local function rampCliff(x)
	if x < 12 then
		return 0
	elseif x < 27 then
		return (x - 12) / 1.5
	end
	return -10
end

-- a vertical 40-stud cliff at x=20
local function cliff(x)
	return if x < 20 then 40 else 0
end

local cases = {
	hill = function(i)
		return {
			ground = hill,
			xa = 12,
			xb = 42,
			path = jumpOn(hill, 16, 50, 2.50 + (i - 1) * 0.02, 1),
			seconds = 6,
		}
	end,
	bridge2 = function(i)
		local g = bridge(2)
		return {
			ground = g,
			xa = 12,
			xb = 38,
			path = jumpOn(g, 16, 50, 1 + 26 / 16 - 0.2 + (i - 1) * 0.02, 1),
			seconds = 6,
		}
	end,
	bridge4 = function(i)
		local g = bridge(4)
		return {
			ground = g,
			xa = 12,
			xb = 40,
			path = jumpOn(g, 16, 50, 1 + 28 / 16 - 0.2 + (i - 1) * 0.02, 1),
			seconds = 6,
		}
	end,
	firstMoveJump = function(i)
		local at = 1.2 + (i - 1) * 0.01
		return { ground = stairs, xa = 2, xb = 32, path = jumpOn(stairs, 16, 50, at, at - 0.05), seconds = 6 }
	end,
	rampCliff = function(i)
		return {
			ground = rampCliff,
			xa = 12,
			xb = 27.25,
			path = walker(rampCliff, 16, 1 + (i - 1) * 0.013, {}, 50, 8),
			seconds = 6,
		}
	end,
	cliff = function(i)
		return {
			ground = cliff,
			xa = 20,
			xb = 21,
			path = walker(cliff, 16, 1 + (i - 1) * 0.013, {}, 50, 8),
			seconds = 6,
		}
	end,
}

describe("hard landing on: a climb is a standing point", function()
	it("a jump around the crest of a 34deg hill (up 10, down 10): 0 drops", function()
		expect(counts(ON, cases.hill)).toEqual(every(0))
	end)
	it("a jump near the far edge of a footbridge with a 2-stud top: 0 drops", function()
		expect(counts(ON, cases.bridge2)).toEqual(every(0))
	end)
	it("a jump near the far edge of a footbridge with a 4-stud top: 0 drops", function()
		expect(counts(ON, cases.bridge4)).toEqual(every(0))
	end)
	it("picked up standing on a top landing, the first move a jump down the stairs: 0 drops", function()
		expect(counts(ON, cases.firstMoveJump)).toEqual(every(0))
	end)
	it("control: up a ramp then straight off a cliff (a 20-stud fall) still drops 10/10", function()
		expect(counts(ON, cases.rampCliff)).toEqual(every(10))
	end)
	it("control: walking off a vertical 40-stud cliff still drops 10/10", function()
		expect(counts(ON, cases.cliff)).toEqual(every(10))
	end)
end)

describe("hard landing is off by default", function()
	it("the module default has no hardLandingSpeed (opt-in), with hardLandingMarginStuds 4", function()
		local rules = S.Carry.config.defaults.dropRules
		expect(rules.hardLandingSpeed).toBe(nil)
		expect(rules.hardLandingMarginStuds).toBe(4)
	end)
	it(
		"with the defaults, a 40-stud cliff, a 20-stud fall after a climb, a crest jump and a stairs jump never drop by hard landing",
		function()
			for _, name in { "cliff", "rampCliff", "hill", "firstMoveJump" } do
				expect(counts(nil, cases[name])).toEqual(every(0))
			end
		end
	)
end)
