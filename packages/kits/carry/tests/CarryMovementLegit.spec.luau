--!nocheck
--[[
	CarryMovementLegit: legitimate play that the real Movement and the real Carry, booted together, must never punish.
	Each case is a false positive that a Studio run or the final review found and the earlier sims missed:

	  - wallSweep (enforced at "strike") on parts a character can walk through: a carried object, a CanCollide = false
	    checkpoint, another pair's carried object, the carrier's own just-dropped object (CarryDropped group).
	    FakeWorld's casts use the engine's filter (a cast hits every CanQuery part unless it respects CanCollide), so
	    these fail if Movement's casts stop respecting CanCollide / the character's collision group.
	  - Movement's kill switch (flag off) mid-carry: Carry falls back to its own clamp; nothing is dropped or refused.
	  - A jumping carrier on a jittery 300 ms connection: a freeze-then-catch-up is not a hard landing.

	All on Scenarios.rig (FakeWorld with the latency model).
]]
local S = require("packages/kits/carry/tests/Scenarios.luau")
local V, FakeWorld = S.V, S.FakeWorld
local rtt300 = S.jitter.rtt300

local STRIKE = { responses = { wallSweep = "strike" } }

-- the example fixture's crate: 3 studs a side, so held at holdOffset it spans the carrier's root height
local function fixtureCrate(rig)
	return rig.fw:addPart({ name = "Crate", position = V(0, 1.5, -3), size = V(3, 3, 3), tags = { "Crate" } })
end

-- runs `seconds` and returns whether the player was ever untrusted by Movement along the way
local function runWatchingTrust(rig, p, seconds)
	local revoked = false
	rig:run(seconds, function()
		if rig.mv.lastValid(p) ~= nil and not rig:trusted(p) then
			revoked = true
		end
	end)
	return revoked
end

describe('wallSweep at "strike" never fires on parts a character can walk through', function()
	it("control: noclipping a solid wall in the same rig IS a wallSweep strike", function()
		local rig = S.rig({ seed = 1, movement = STRIKE })
		rig:box(V(30, 6, 0), V(1, 12, 40))
		local p = rig:player(1, { path = S.walk(V(5, 3, 0), 16) })
		rig:run(3)
		expect(rig:count(p, "wallSweep") >= 1).toBe(true)
	end)

	it(
		"a sole carrier walks 30 studs holding a crate: CanQuery off while carried, zero wallSweep strikes",
		function()
			local rig = S.rig({ seed = 1, movement = STRIKE })
			local p = rig:player(1, { path = FakeWorld.paths.line(V(0, 3, 0), V(10, 0, 0), 1), ping = 0.05 })
			local crate = fixtureCrate(rig)
			rig:settle()
			expect(rig.carry.pickUp(p, crate)).toBe(true)
			expect(crate.canQuery).toBe(false)
			expect(crate.canCollide).toBe(false)
			local revoked = runWatchingTrust(rig, p, 3)
			expect(rig.carry.stateOf(crate)).toBe("carried")
			expect(rig:count(p, "wallSweep")).toBe(0)
			expect(revoked).toBe(false)
			expect(rig.carry.drop(p, crate)).toBe(true)
			expect(crate.canQuery).toBe(true)
			expect(crate.canCollide).toBe(true)
		end
	)

	it("the same walk at rtt300 jitter over 5 seeds: zero wallSweep strikes", function()
		for seed = 1, 5 do
			local rig = S.rig({ seed = seed, movement = STRIKE })
			local p = rig:player(1, {
				path = FakeWorld.paths.line(V(0, 3, 0), V(10, 0, 0), 1),
				jitter = rtt300,
				ping = 0.3,
			})
			local crate = fixtureCrate(rig)
			rig:settle()
			expect(rig.carry.pickUp(p, crate)).toBe(true)
			rig:run(6)
			expect(rig:count(p, "wallSweep")).toBe(0)
		end
	end)

	it(
		"walking through a CanCollide = false checkpoint gate: one crossing, no wallSweep, trust kept",
		function()
			local rig = S.rig({
				seed = 1,
				movement = { volumes = { Gate = "checkpoint" }, responses = { wallSweep = "strike" } },
			})
			local gate = rig:box(V(0, 5, 0), V(4, 10, 20), { "Gate" }, { canCollide = false })
			expect(gate.canQuery).toBe(true) -- a game that never clears CanQuery
			local p = rig:player(1, { path = FakeWorld.paths.line(V(-20, 3, 0), V(12, 0, 0)), ping = 0.05 })
			local revoked = runWatchingTrust(rig, p, 4)
			expect(rig:count(p, "wallSweep")).toBe(0)
			expect(#rig.crossLog).toBe(1)
			expect(revoked).toBe(false)
		end
	)

	it("a helper walks through a wardrobe two others are carrying: no wallSweep", function()
		local rig = S.rig({
			seed = 1,
			movement = STRIKE,
			carry = {
				carriables = {
					Wardrobe = {
						massClass = "heavy",
						carriers = { min = 2, max = 2 },
						gripPoints = { { -2, 0, 0 }, { 2, 0, 0 } },
					},
				},
			},
		})
		local a = rig:player(1, { path = S.stand(V(-2, 3, 0)) })
		local b = rig:player(2, { path = S.stand(V(2, 3, 0)) })
		local wardrobe = rig.fw:addPart({
			name = "Wardrobe",
			position = V(0, 2.5, -2.5),
			size = V(6, 5, 2),
			tags = { "Wardrobe" },
		})
		local helper = rig:player(3, {
			path = function(s)
				return V(0, 3, -15 + 10 * math.max(0, s - 1.5))
			end,
			ping = 0.05,
		})
		rig:settle()
		expect(rig.carry.pickUp(a, wardrobe) and rig.carry.pickUp(b, wardrobe)).toBe(true)
		expect(rig.carry.stateOf(wardrobe)).toBe("carried")
		local revoked = runWatchingTrust(rig, helper, 3)
		expect(rig:count(helper, "wallSweep")).toBe(0)
		expect(revoked).toBe(false)
	end)

	it(
		"a carrier drops a tall box and walks on through it (CarryDropped doesn't collide with characters)",
		function()
			local rig = S.rig({
				seed = 1,
				movement = STRIKE,
				carry = {
					carriables = {
						Box = {
							massClass = "medium",
							carriers = { min = 1, max = 1 },
							gripPoints = { { 0, 0, 0 } },
						},
					},
				},
			})
			-- the live setup Carry's Engine makes (FakeWorld has no Engine): characters in CarryCharacters, which
			-- doesn't collide with CarryDropped
			rig.fw:setCollidable("CarryDropped", "CarryCharacters", false)
			local p = rig:player(1, {
				path = FakeWorld.paths.line(V(0, 3, 0), V(10, 0, 0), 1),
				ping = 0.05,
				collisionGroup = "CarryCharacters",
			})
			local box = rig.fw:addPart({
				name = "Box",
				position = V(2.5, 2.5, 0),
				size = V(4, 5, 4),
				tags = { "Box" },
			})
			rig:settle()
			expect(rig.carry.pickUp(p, box)).toBe(true)
			rig:run(1.5)
			expect(rig.carry.drop(p, box)).toBe(true)
			expect(box.collisionGroup).toBe("CarryDropped")
			expect(box.canCollide).toBe(true)
			local revoked = runWatchingTrust(rig, p, 2)
			expect(rig:count(p, "wallSweep")).toBe(0)
			expect(revoked).toBe(false)
		end
	)
end)

describe("Movement's flag off mid-carry: Carry falls back to its own clamp", function()
	it(
		"the carry continues, pick-up works with the flag off, and both keep working when it is back on",
		function()
			local rig = S.rig({
				seed = 1,
				movement = { flag = "movementOn" },
				flags = { movementOn = { default = true } },
				isStudio = true, -- the `flags set` console command is Studio-only
			})
			local p = rig:player(1, { path = FakeWorld.paths.line(V(0, 3, 0), V(8, 0, 0), 1) })
			local crate = rig:crate(V(0, 1, -3))
			rig:settle()
			expect(rig.carry.pickUp(p, crate)).toBe(true)
			expect(rig.mv.active(p)).toBe(true)
			rig:run(1)
			rig.h:console("flags set movementOn false")
			rig:run(2)
			expect(rig.mv.active(p)).toBe(false)
			expect(rig:dropReasons()).toEqual({})
			expect(rig.carry.stateOf(crate)).toBe("carried")
			-- the object kept following the carrier on Carry's own clamp
			local pos = rig.fw.world.rootOf(p)
			expect(math.abs(crate.cf.p.x - pos.x) < 6).toBe(true)
			expect(rig.carry.drop(p, crate)).toBe(true)
			expect(rig.carry.pickUp(p, crate)).toBe(true) -- pick-up with Movement's flag off
			rig.h:console("flags set movementOn true")
			rig:run(2)
			expect(rig.mv.active(p)).toBe(true)
			expect(rig:dropReasons()).toEqual({ "manual" })
			expect(rig.carry.stateOf(crate)).toBe("carried")
			rig:run(4) -- walks on with Movement back on
			expect(rig.carry.drop(p, crate)).toBe(true)
			rig:run(0.5)
			local _, trusted = rig.mv.lastValid(p)
			expect(trusted).toBe(true)
			expect(rig:count(p)).toBe(0)
		end
	)
end)

describe("a jumping carrier on a jittery 300 ms connection is never dropped for a hard landing", function()
	for _, mode in { { "Movement on", {} }, { "Movement off", false } } do
		it(`{mode[1]}: 10 seeds x 30 s of jumping with hitches, no drop at all`, function()
			for seed = 1, 10 do
				-- hard landing is opt-in: these run with it on, so "no drop" means the rule held
				local rig = S.rig({
					seed = seed,
					movement = mode[2],
					carry = { dropRules = { hardLandingSpeed = 55 } },
				})
				local p =
					rig:player(1, { path = S.jumper(seed, V(0, 3, 0), 12), jitter = rtt300, ping = 0.3 })
				local crate = rig:crate()
				rig:settle()
				expect(rig.carry.pickUp(p, crate)).toBe(true)
				rig:runWithHitches(30, seed)
				expect(rig:dropReasons()).toEqual({})
			end
		end)
	end

	it("control: a carrier who walks off a 20-stud ledge still drops it as hardLanding", function()
		local rig = S.rig({
			seed = 1,
			movement = false,
			ground = false,
			carry = { dropRules = { hardLandingSpeed = 55 } }, -- opt-in
		})
		rig:box(V(0, -0.5, 0), V(20, 1, 20)) -- the upper floor (top at y = 0), its edge at x = 10
		rig:box(V(40, -20.5, 0), V(60, 1, 40)) -- the lower floor, 20 studs down
		local p = rig:player(1, { path = S.ledge(V(0, 3, 0), 10, 10, 20) })
		local crate = rig:crate(V(0, 1, -3))
		rig:settle()
		expect(rig.carry.pickUp(p, crate)).toBe(true)
		rig:run(5)
		expect(rig:dropReasons()[1]).toBe("hardLanding")
	end)
end)
