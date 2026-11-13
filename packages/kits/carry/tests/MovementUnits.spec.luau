--!nocheck
--[[
	Movement's pure shared helpers (Lag, Caps, Arc, Slab, Window): the carry.md "Worked numbers" table, exactly.
	No World, no harness.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Movement"):WaitForChild("shared")
local Lag = require(shared:WaitForChild("Lag"))
local Caps = require(shared:WaitForChild("Caps"))
local Arc = require(shared:WaitForChild("Arc"))
local Slab = require(shared:WaitForChild("Slab"))
local Window = require(shared:WaitForChild("Window"))
local CF = require("packages/kits/carry/Movement/shared/CF.luau")

local V = vector.create
local LAG = { pingFactor = 1, jitterMarginSeconds = 0.15, minSeconds = 0.25, maxSeconds = 0.75 }

describe("Lag (the allowance)", function()
	it(
		"clamp(ping x 1 + 0.15, 0.25, 0.75): 0.45 at ping 0.30, 0.25 at ping 0, 0.75 at ping >= 0.6",
		function()
			expect(Lag.allowance(0.3, LAG)).toBeNear(0.45, 1e-9)
			expect(Lag.allowance(0, LAG)).toBeNear(0.25, 1e-9)
			expect(Lag.allowance(0.6, LAG)).toBeNear(0.75, 1e-9)
			expect(Lag.allowance(5, LAG)).toBeNear(0.75, 1e-9)
		end
	)

	it("the teleport lag is max(allowance, 0.6): 0.60 at ping 0.30, 0.75 at the clamp", function()
		expect(Lag.teleportLag(0.45, 0.6)).toBeNear(0.6, 1e-9)
		expect(Lag.teleportLag(0.75, 0.6)).toBeNear(0.75, 1e-9)
	end)
end)

describe("Caps (the worked numbers: WalkSpeed 16, JumpPower 50, Gravity 196.2, ping 0.30, dt 0.1)", function()
	local eff = Caps.effectiveSpeed(16, 16, 1.15)
	it("effective speed cap 18.40", function()
		expect(eff).toBeNear(18.4, 1e-9)
		expect(Caps.effectiveSpeed(16, 32, 1.15)).toBeNear(36.8, 1e-9) -- follows server WalkSpeed
		expect(Caps.effectiveSpeed(30, 16, 1.15)).toBeNear(34.5, 1e-9) -- a higher speedCap floor
	end)

	it("teleport cap 13.88 at dt 0.1 (16.64 at lag 0.75); a literal capStuds replaces the formula", function()
		expect(Caps.teleportCap(eff, 0.1, 0.6, 1, 0, nil)).toBeNear(13.88, 1e-9)
		expect(Caps.teleportCap(eff, 0.1, 0.75, 1, 0, nil)).toBeNear(16.64, 1e-9)
		expect(Caps.teleportCap(eff, 0.1, 0.6, 1, 30, nil)).toBeNear(13.88 + 18, 1e-9) -- platform speed x lag
		expect(Caps.teleportCap(eff, 0.1, 0.6, 1, 0, 7)).toBe(7)
	end)

	it(
		"speed window limit 85.64 per 4 s (88.40 at lag 0.75); 24 studs/s (96 per 4 s) exceeds both",
		function()
			expect(Caps.windowLimit(eff, 4, 0.6, 1, 0)).toBeNear(85.64, 1e-9)
			expect(Caps.windowLimit(eff, 4, 0.75, 1, 0)).toBeNear(88.4, 1e-9)
			expect(96 > 88.4).toBe(true)
		end
	)

	it("descent bound 56.28 per sample from standing, 308.98 after 1 s airborne", function()
		expect(Caps.maxDrop(196.2, 0.15, 0.1, 0.6, 1, true, 0, 0)).toBeNear(56.28, 0.01)
		expect(Caps.maxDrop(196.2, 0.15, 0.1, 0.6, 1, false, 1, 0)).toBeNear(308.98, 0.05)
	end)

	it("rise cap 45.27 at dt 0.1; an override replaces max(jumpVelocity, WalkSpeed) x launchSlack", function()
		expect(Caps.riseCap(50, 16, 1.1, 1.15, 0.1, 0.6, 1, nil, 0)).toBeNear(45.27, 0.01)
		expect(Caps.riseCap(50, 16, 1.1, 1.15, 0.1, 0.6, 1, 10, 0)).toBeNear(10 * 1.15 * 0.7 + 1, 1e-9)
	end)

	it("respawn envelope: 6 -> 17.04 studs horizontal, +16.57 / -6 -> -46.61 vertical", function()
		local p = {
			reach = 6,
			effCap = eff,
			lag = 0.6,
			jumpVelocity = 50,
			walkSpeed = 16,
			launchSlack = 1.1,
			gravity = 196.2,
			gravitySlack = 0.15,
			heightSlackStuds = 1.5,
		}
		local function inside(dx, dy, at)
			return Caps.inRespawnEnvelope(p, 0, 0, 0, 0, at, dx, dy, 0)
		end
		expect(inside(5.9, 0, 0)).toBe(true)
		expect(inside(6.1, 0, 0)).toBe(false)
		expect(inside(17.0, 0, 5)).toBe(true) -- e capped at the lag: 6 + 18.4 x 0.6 = 17.04
		expect(inside(17.1, 0, 5)).toBe(false)
		expect(inside(0, 16.5, 5)).toBe(true)
		expect(inside(0, 16.7, 5)).toBe(false)
		expect(inside(0, -46.5, 5)).toBe(true)
		expect(inside(0, -46.8, 5)).toBe(false)
		expect(inside(0, -6.1, 0)).toBe(false) -- e = 0: only the reach
	end)
end)

describe("Arc (the jump/fall envelope)", function()
	it("launch speed 55, gravity 166.77, apex allowance 10.57 above takeoff", function()
		local launch = Arc.launchSpeed(50, 16, 1.1, 0)
		local g = Arc.gravity(196.2, 0.15)
		expect(launch).toBeNear(55, 1e-9)
		expect(g).toBeNear(166.77, 1e-9)
		-- inside the lag + grace: the apex allowance, flat
		expect(Arc.maxY(10, 0.5, 0.6, 0.2, launch, g, 1.5) - 10).toBeNear(10.57, 0.01)
		-- much later: the envelope has fallen back below takeoff
		expect(Arc.maxY(10, 3, 0.6, 0.2, launch, g, 1.5) < 10).toBe(true)
		-- a platform's upward speed adds to the launch
		expect(Arc.launchSpeed(50, 16, 1.1, 20)).toBeNear(75, 1e-9)
	end)
end)

describe("Slab (segment vs OBB)", function()
	local box = Slab.box(CF.new(V(0, 0, 0)), V(4, 4, 4))
	it("a segment through the box crosses; a miss does not", function()
		expect(Slab.crosses(box, V(-10, 0, 0), V(10, 0, 0))).toBe(true)
		expect(Slab.crosses(box, V(-10, 5, 0), V(10, 5, 0))).toBe(false)
		expect(Slab.crosses(box, V(-10, 0, 0), V(-3, 0, 0))).toBe(false)
	end)

	it("entering counts; starting inside does not (no storm while standing in a volume)", function()
		expect(Slab.crosses(box, V(-5, 0, 0), V(0, 0, 0))).toBe(true)
		expect(Slab.crosses(box, V(0, 0, 0), V(5, 0, 0))).toBe(false)
		expect(Slab.contains(box, V(1, 1, 1))).toBe(true)
		expect(Slab.contains(box, V(3, 0, 0))).toBe(false)
	end)

	it("a thin box is hit by a long chord that steps over it (the 10-stud hop)", function()
		local thin = Slab.box(CF.new(V(5, 0, 0)), V(0.5, 6, 6))
		expect(Slab.crosses(thin, V(0, 0, 0), V(10, 0, 0))).toBe(true)
		expect(Slab.crosses(thin, V(0, 0, 0), V(4.5, 0, 0))).toBe(false)
	end)

	it("an ROTATED box is tested in its own space (a 45-degree slab)", function()
		local s = math.sqrt(0.5)
		-- rotated 45 degrees about Y: a 10 x 1 x 10 slab runs diagonally
		local rot = CF.fromParts(0, 0, 0, s, 0, s, 0, 1, 0, -s, 0, s)
		local diag = Slab.box(rot, V(10, 2, 1))
		-- along the box's long axis (local X is world (s, 0, -s)): a point on that axis is inside
		expect(Slab.contains(diag, V(3, 0, -3))).toBe(true)
		-- the same world point on an axis-aligned reading of a 10 x 2 x 1 box would be outside
		expect(Slab.contains(Slab.box(CF.new(V(0, 0, 0)), V(10, 2, 1)), V(3, 0, -3))).toBe(false)
		expect(Slab.crosses(diag, V(-3, 0, -3), V(3, 0, 3))).toBe(true) -- across the slab's width
		expect(Slab.crosses(diag, V(-3, 0, -3), V(-1, 0, -1))).toBe(false)
	end)
end)

describe("Window (the speed ring)", function()
	it("sums path length, nets platform-relative vectors and prunes by start time", function()
		local w = Window.new(8)
		Window.push(w, 0.0, 3, 3, 0, false, 0)
		Window.push(w, 0.1, 4, 4, 0, false, 0)
		expect(Window.measure(w)).toBe(7)
		expect(Window.oldestStart(w)).toBe(0.0)
		Window.prune(w, 0.05)
		expect(Window.measure(w)).toBe(4)
		Window.clear(w)
		Window.push(w, 1, 5, 5, 0, true, 30) -- on a platform: only the net relative vector counts
		Window.push(w, 1.1, 5, -5, 0, true, 20)
		expect(Window.measure(w)).toBe(0)
		expect(Window.maxFrameSpeed(w)).toBe(30)
	end)

	it("never allocates past its capacity: the oldest entry is dropped", function()
		local w = Window.new(8)
		for i = 1, 20 do
			Window.push(w, i, 1, 1, 0, false, 0)
		end
		expect(w.count).toBe(8)
		expect(Window.measure(w)).toBe(8)
		expect(Window.oldestStart(w)).toBe(13)
	end)
end)
