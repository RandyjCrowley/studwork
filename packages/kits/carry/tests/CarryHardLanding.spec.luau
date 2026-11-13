--!nocheck
--[[
	Hard landing (carry.md "dropRules", hardLandingSpeed / hardLandingMarginStuds; Carry/server/Landing.luau): the REAL
	Carry, with the REAL Movement and without it (Scenarios / LandingRig on FakeWorld). Every count is exact.

	  a. 15/20/30/40-stud ledge falls, the landing swept over 10 offsets inside the 0.1 s tick: 10/10 drop
	  b. the same falls at rtt300 (freeze-then-catch-up jitter) with a 0.45 s server hitch near the landing,
	     10 seeds: 10/10 drop
	  c. JumpPower 60 on flat ground, jumping for 30 s at rtt300 with hitches, 10 seeds: no drop
	  d. jumping down a 1-stud step every jump, at JumpHeight 7.2 and at JumpPower 60, rtt300, 10 seeds: no drop
	  e. walking down a 20-stud staircase (45 degrees) or ramp, riding a lift down 20 studs, rtt300, 10 seeds:
	     no drop
	  f. a fall of (minimum fall - 1) never drops; a stall 0.05 s before landing a 20-stud fall still drops
	Each scenario runs with Movement off (Carry alone) and on.
]]
local L = require("packages/kits/carry/tests/LandingRig.luau")
local S = L.S
local G = S.G
local Landing = require("packages/kits/carry/Carry/server/Landing.luau")
local Jump = require("packages/kits/carry/Carry/shared/Jump.luau")
local FakeWorld = S.FakeWorld

local MODES = { { "Movement off", false }, { "Movement on", true } }
local HEIGHTS = { 15, 20, 30, 40 }
local JUMP_POWER_60 = { useJumpPower = true, jumpPower = 60 }
local JUMP_HEIGHT_72 = { useJumpPower = false, jumpHeight = 7.2 }

local function mvOf(on, extra)
	if not on then
		return false
	end
	return extra or {}
end

-- how many of n runs ended with a hardLanding drop
local function hardRuns(n, fn)
	local hard = 0
	for i = 1, n do
		if L.hard(fn(i)) > 0 then
			hard += 1
		end
	end
	return hard
end

-- every drop reason over n runs (expected empty)
local function allDrops(n, fn)
	local out = {}
	for i = 1, n do
		for _, r in fn(i):dropReasons() do
			table.insert(out, `{i}:{r}`)
		end
	end
	return out
end

local function hitchFall(mv, drop, seed, extra)
	local shift = (seed % 10) * 0.1
	local o = {
		movement = mvOf(mv),
		drop = drop,
		shift = shift,
		seed = seed,
		jitter = true,
		hitchAt = L.landAt(drop, shift) - L.PICKUP - 0.5 + (seed % 7) * 0.12,
	}
	for k, v in extra or {} do
		o[k] = v
	end
	return L.fall(o)
end

describe("the minimum fall comes from the carriers' jump", function()
	it(
		"Jump.velocity: JumpPower when UseJumpPower, else sqrt(2 g JumpHeight); the apex is v^2 / 2g",
		function()
			expect(Jump.velocity(true, 60, 7.2, G)).toBe(60)
			expect(math.abs(Jump.velocity(false, 60, 7.2, G) - math.sqrt(2 * G * 7.2)) < 1e-9).toBe(true)
			expect(math.abs(Jump.apex(Jump.velocity(false, 50, 7.2, G), G) - 7.2) < 1e-9).toBe(true)
			expect(math.abs(Jump.apex(60, G) - 3600 / (2 * G)) < 1e-9).toBe(true)
		end
	)

	it("FakeWorld's humanoid facts use the same formula (UseJumpPower + JumpPower, JumpHeight)", function()
		local fw = FakeWorld.new({})
		local a, b, c, d = { Name = "A" }, { Name = "B" }, { Name = "C" }, { Name = "D" }
		fw:addPlayer(a, JUMP_POWER_60)
		fw:addPlayer(b, JUMP_HEIGHT_72)
		fw:addPlayer(c, {})
		fw:addPlayer(d, { jumpVelocity = 44 })
		expect(fw.world.humanoidFacts(a).jumpVelocity).toBe(60)
		expect(math.abs(fw.world.humanoidFacts(b).jumpVelocity - math.sqrt(2 * G * 7.2)) < 1e-9).toBe(true)
		expect(fw.world.humanoidFacts(c).jumpVelocity).toBe(50)
		expect(fw.world.humanoidFacts(d).jumpVelocity).toBe(44)
	end)

	it(
		"minFall = max(hardLandingSpeed^2 / 2g, apex + margin): the defaults keep a 15-stud fall above it",
		function()
			local p = { gravity = G, hardLandingSpeed = 55, marginStuds = 4 }
			local jp60 = Landing.minFall(60, p)
			expect(math.abs(jp60 - (3600 / (2 * G) + 4)) < 1e-9).toBe(true) -- 13.17
			expect(jp60 < 15).toBe(true)
			expect(math.abs(Landing.minFall(Jump.velocity(false, 0, 7.2, G), p) - 11.2) < 1e-9).toBe(true)
			expect(math.abs(Landing.minFall(50, p) - (2500 / (2 * G) + 4)) < 1e-9).toBe(true) -- 10.37
			-- a low jump: the hardLandingSpeed floor (55^2 / 2g = 7.71) wins
			expect(math.abs(Landing.minFall(20, p) - 3025 / (2 * G)) < 1e-9).toBe(true)
		end
	)

	it(
		"the shipped defaults: hard landing off (opt-in, these specs run it at 55), hardLandingMarginStuds 4",
		function()
			local rules = S.Carry.config.defaults.dropRules
			expect(rules.hardLandingSpeed).toBe(nil) -- was 55; off by default since the rule is a heuristic with known limits
			expect(rules.hardLandingMarginStuds).toBe(4)
		end
	)
end)

describe("Landing.step (pure): when a descent ends", function()
	local p = { gravity = G, hardLandingSpeed = 55, marginStuds = 4 }
	local function inAir()
		return true, false
	end
	local function onGround()
		return false, true
	end
	-- feeds (t, y) ticks; `probeAt(y)` says air/ground; returns the tick index and height of each hard landing
	local function feed(ticks, probeAt)
		local f = Landing.new(ticks[1][2], ticks[1][1])
		local out = {}
		for i = 2, #ticks do
			local t, y = ticks[i][1], ticks[i][2]
			local prev = ticks[i - 1][2]
			local h = Landing.step(f, t, y, y ~= prev, 50, p, function()
				return probeAt(y)
			end)
			if h ~= nil then
				table.insert(out, `{i}:{math.floor(h + 0.5)}`)
			end
		end
		return out
	end
	local function fallTicks(stallFrom, stallTicks)
		-- a 20-stud fall sampled every 0.1 s (top 20, ground 0), optionally frozen for stallTicks ticks
		local ticks, y, t = { { 0, 20 } }, 20, 0
		local ys = { 20, 19, 16, 11, 4, 0 }
		for k = 2, #ys do
			if stallFrom ~= nil and k == stallFrom then
				for _ = 1, stallTicks do
					t += 0.1
					table.insert(ticks, { t, y })
				end
			end
			t += 0.1
			y = ys[k]
			table.insert(ticks, { t, y })
		end
		for _ = 1, 15 do
			t += 0.1
			table.insert(ticks, { t, y })
		end
		return ticks
	end
	local function probe(y)
		if y > 3 then
			return inAir()
		end
		return onGround()
	end

	it("decides once, at the touchdown", function()
		local out = feed(fallTicks(), probe)
		expect(#out).toBe(1)
		expect(string.split(out[1], ":")[2]).toBe("20")
	end)

	it("a mid-air stall up to SETTLE neither ends nor restarts the fall", function()
		for _, stall in { 1, 3, 5, 9 } do
			local out = feed(fallTicks(5, stall), probe)
			expect(`{stall}: {#out} {if out[1] then string.split(out[1], ":")[2] else "-"}`).toBe(
				`{stall}: 1 20`
			)
		end
	end)

	it("touchdown decides at once (before a jump straight off the landing)", function()
		local ticks = { { 0, 20 }, { 0.1, 15 }, { 0.2, 5 }, { 0.3, 0 }, { 0.4, 2 } }
		expect(feed(ticks, probe)).toEqual({ "4:20" })
	end)

	it("with no carrier ever in the air, only one huge fast step (a hidden fall) makes it a fall", function()
		local walked =
			{ { 0, 20 }, { 0.1, 18 }, { 0.2, 16 }, { 0.3, 14 }, { 0.4, 12 }, { 0.5, 10 }, { 0.6, 8 } }
		for k = 7, 16 do
			table.insert(walked, { k / 10, 8 })
		end
		expect(feed(walked, onGround)).toEqual({}) -- 12 studs at 20 studs/s, ground under the feet all along
		local hidden = { { 0, 20 }, { 0.1, 20 }, { 0.6, 0 } } -- a 0.5 s freeze over a 20-stud fall
		for k = 7, 16 do
			table.insert(hidden, { k / 10, 0 })
		end
		expect(#feed(hidden, onGround)).toBe(1)
	end)
end)

describe("a. a real fall drops at every landing phase", function()
	for _, mode in MODES do
		it(`{mode[1]}: 15/20/30/40 studs x 10 offsets inside the tick: 10/10 each`, function()
			for _, drop in HEIGHTS do
				local hard = hardRuns(10, function(i)
					return L.fall({ movement = mvOf(mode[2]), drop = drop, shift = (i - 1) * 0.1 })
				end)
				expect(`{drop}: {hard}`).toBe(`{drop}: 10`)
			end
		end)
	end
end)

describe("b. a real fall drops under rtt300 jitter and a server hitch at the landing", function()
	for _, mode in MODES do
		it(`{mode[1]}: 15/20/30/40 studs x 10 seeds: 10/10 each`, function()
			for _, drop in HEIGHTS do
				local hard = hardRuns(10, function(seed)
					return hitchFall(mode[2], drop, seed)
				end)
				expect(`{drop}: {hard}`).toBe(`{drop}: 10`)
			end
		end)
	end
end)

describe("c. JumpPower 60 on flat ground never drops", function()
	for _, mode in MODES do
		it(`{mode[1]}: 10 seeds x 30 s of jumping at rtt300 with hitches: no drop at all`, function()
			local drops = allDrops(10, function(seed)
				return L.jumping({
					movement = mvOf(mode[2]),
					v0 = 60,
					seed = seed,
					jitter = true,
					hitches = true,
					jump = JUMP_POWER_60,
				})
			end)
			expect(drops).toEqual({})
		end)
	end
end)

describe("d. jumping down a 1-stud step never drops", function()
	for _, mode in MODES do
		for _, jump in { { "JumpHeight 7.2", JUMP_HEIGHT_72 }, { "JumpPower 60", JUMP_POWER_60 } } do
			it(`{mode[1]}, {jump[1]}: 10 seeds x 30 s at rtt300 with hitches: no drop at all`, function()
				local v0 =
					Jump.velocity(jump[2].useJumpPower, jump[2].jumpPower or 50, jump[2].jumpHeight or 7.2, G)
				local drops = allDrops(10, function(seed)
					return L.jumping({
						movement = mvOf(mode[2]),
						v0 = v0,
						step = 1,
						seed = seed,
						jitter = true,
						hitches = true,
						jump = jump[2],
					})
				end)
				expect(drops).toEqual({})
			end)
		end
	end
end)

describe("e. walking or riding down 20 studs never drops", function()
	for _, mode in MODES do
		it(`{mode[1]}: a 45-degree staircase at WalkSpeed 16, 10 seeds at rtt300: no drop`, function()
			expect(allDrops(10, function(seed)
				return L.stairs({ movement = mvOf(mode[2]), run = 1, seed = seed, jitter = true })
			end)).toEqual({})
		end)
		it(`{mode[1]}: a ramp, 10 seeds at rtt300: no drop`, function()
			expect(allDrops(10, function(seed)
				return L.stairs({ movement = mvOf(mode[2]), ramp = true, seed = seed, jitter = true })
			end)).toEqual({})
		end)
		it(
			`{mode[1]}: a lift going down 20 studs at 12 and at 20 studs/s, 10 seeds at rtt300: no drop`,
			function()
				for _, speed in { 12, 20 } do
					local drops = allDrops(10, function(seed)
						return L.platform({
							movement = mvOf(mode[2], { volumes = { CarryLift = "platform" } }),
							speed = speed,
							seed = seed,
							jitter = true,
						})
					end)
					expect(`{speed}: {#drops}`).toBe(`{speed}: 0`)
				end
			end
		)
	end
end)

describe("f. the floor, and a stall before the landing", function()
	local p = { gravity = G, hardLandingSpeed = 55, marginStuds = 4 }
	for _, mode in MODES do
		it(
			`{mode[1]}: a fall of (minimum fall - 1) never drops (JumpPower 50 and 60; 10 offsets, 10 rtt300 seeds)`,
			function()
				for _, jump in { { 50, {} }, { 60, JUMP_POWER_60 } } do
					local drop = Landing.minFall(jump[1], p) - 1
					local still = hardRuns(10, function(i)
						return L.fall({
							movement = mvOf(mode[2]),
							drop = drop,
							shift = (i - 1) * 0.1,
							jump = jump[2],
						})
					end)
					local lagged = hardRuns(10, function(seed)
						return hitchFall(mode[2], drop, seed, { jump = jump[2] })
					end)
					expect(`{jump[1]}: {still} {lagged}`).toBe(`{jump[1]}: 0 0`)
				end
			end
		)

		it(
			`{mode[1]}: a stall of 0.1/0.25/0.5 s starting 0.05 s before a 20-stud landing still drops`,
			function()
				for _, stall in { 0.1, 0.25, 0.5 } do
					local hard = hardRuns(10, function(i)
						local shift = (i - 1) * 0.1
						local landAt = L.landAt(20, shift)
						return L.fall({
							movement = mvOf(mode[2]),
							drop = 20,
							shift = shift,
							before = function(rig)
								rig:runUntil(10, function()
									return rig.fw.now >= landAt - 0.05
								end)
								rig.fw:freeze(rig.p, stall)
							end,
							seconds = 4,
						})
					end)
					expect(`{stall}: {hard}`).toBe(`{stall}: 10`)
				end
			end
		)
	end
end)
