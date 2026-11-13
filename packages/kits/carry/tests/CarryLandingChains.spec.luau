--!nocheck
--[[
	Hard landing on chained terrain (carry.md "dropRules", hardLandingSpeed; Carry/server/Landing.luau): each fall ends
	at its touchdown and the next starts there, a fall counts at most the carriers' own rise plus the highest single
	ledge under their path, a mid-air freeze never splits a fall, and a fall that already qualifies is resolved before
	a delivery or a manual drop. The REAL Carry, with the REAL Movement and without it, at 0 ms and at rtt300 (freeze-
	then-catch-up jitter), on FakeWorld (LandingRig). Every count is exact.

	  g. one JumpPower-50 jump on stairs (run 1.5 and 45 degrees), a 34 and an 18 degree ramp, from the top landing
	     onto stairs, and on an 8-stud staircase from its top, 10 takeoff times each: no drop
	  h. 4 x 5-stud ledges (treads 6 and 4), 4 x 3-stud ledges (treads 2 and 4), a 10-stud ramp then a 5-stud ledge,
	     a jump landing just before a staircase, 10 phases each: no drop. A 15-stud ledge at the end of a ramp: 10/10
	  i. a 20-stud fall with a 1.3 s and a 2.0 s connection freeze at mid-height: hardLanding 10/10
	  j. a 30-stud fall landing 2 or 3 studs short of a delivery zone, walking in: hardLanding 10/10, never Delivered;
	     a 30-stud fall straight into the zone: hardLanding 10/10
	  k. carry.drop 0-0.4 s (client time) after a 30-stud landing: hardLanding 10/10
	  l. the clamp's lag: with maxFallSpeed 30 the object trails its carriers, and a 12-stud fall still drops 10/10
	  Landing (pure): the touchdown restarts the fall, the ledge cap, the freeze hold, the in-air projection
]]
local L = require("packages/kits/carry/tests/LandingRig.luau")
local S = L.S
local V, G = S.V, S.G
local Landing = require("packages/kits/carry/Carry/server/Landing.luau")

local MODES = { { "Movement off", false }, { "Movement on", true } }
local LAGS = { { "0 ms", false }, { "rtt300", true } }

local function mvOf(on)
	return if on then {} else false
end

-- every run's events, tallied: "[Dropped:hardLanding] x10" etc.; [none] for a run with no event
local function tally(n, fn)
	local m, keys = {}, {}
	for i = 1, n do
		local s = L.events(fn(i))
		if s == "" then
			s = "none"
		end
		if m[s] == nil then
			m[s] = 0
			table.insert(keys, s)
		end
		m[s] += 1
	end
	table.sort(keys)
	local out = {}
	for _, k in keys do
		table.insert(out, `[{k}] x{m[k]}`)
	end
	return table.concat(out, " ")
end

-- how many of n runs dropped as a hard landing
local function hardRuns(n, fn)
	local hard = 0
	for i = 1, n do
		if L.hard(fn(i)) > 0 then
			hard += 1
		end
	end
	return hard
end

describe("g. one jump on descending stairs or a ramp never drops", function()
	-- the walk reaches the stairs (x0 = 12) at client time 1 + 12/16 = 1.75 s
	local CASES = {
		{
			"stairs run 1.5 (34 degrees), a jump on the stairs",
			{ height = 20, run = 1.5, from = 2.0, step = 0.08 },
		},
		{
			"stairs run 1 (45 degrees), a jump on the stairs",
			{ height = 20, run = 1, from = 1.9, step = 0.06 },
		},
		{
			"a 34-degree ramp, a jump on the ramp",
			{ height = 20, run = 1.5, ramp = true, from = 2.0, step = 0.08 },
		},
		{
			"an 18-degree ramp, a jump on the ramp",
			{ height = 20, run = 3, ramp = true, from = 2.0, step = 0.15 },
		},
		{
			"a jump from the top landing onto the stairs",
			{ height = 20, run = 1.5, from = 1.45, step = 0.03 },
		},
		{ "an 8-stud staircase, a jump at its top", { height = 8, run = 1.5, from = 1.45, step = 0.03 } },
	}
	for _, mode in MODES do
		for _, lag in LAGS do
			it(`{mode[1]}, {lag[1]}: each case x 10 takeoff times: no drop at all`, function()
				local got, want = {}, {}
				for _, c in CASES do
					local o = c[2]
					local ground, boxes = L.stairsTerrain(12, o.height, o.run, o.ramp)
					local hard = hardRuns(10, function(i)
						return L.terrain({
							movement = mvOf(mode[2]),
							jitter = lag[2],
							seed = i,
							seconds = 1 + 12 / 16 + o.height * o.run / 16 + 3,
						}, ground, boxes, L.jumpOn(ground, 16, 50, o.from + (i - 1) * o.step, 1))
					end)
					table.insert(got, `{c[1]}: {hard}`)
					table.insert(want, `{c[1]}: 0`)
				end
				expect(got).toEqual(want)
			end)
		end
	end
end)

describe("h. walking down ledges never drops when each landing is below the minimum fall", function()
	local function walk(o, i, ground, boxes, jumps, seconds)
		return L.terrain(
			{ movement = mvOf(o.mv), jitter = o.lag, seed = i, seconds = seconds or 8 },
			ground,
			boxes,
			L.walker(ground, 16, 1, jumps or {}, 50, (seconds or 8) + 2)
		)
	end
	local CASES = {
		{
			"4 x 5-stud ledges, tread 6",
			function(o, i)
				return walk(o, i, L.terraces(20, 12 + (i - 1) * 0.13, 5, 6, 4))
			end,
		},
		{
			"4 x 5-stud ledges, tread 4",
			function(o, i)
				return walk(o, i, L.terraces(20, 12 + (i - 1) * 0.13, 5, 4, 4))
			end,
		},
		{
			"4 x 3-stud ledges, tread 2",
			function(o, i)
				return walk(o, i, L.terraces(20, 12 + (i - 1) * 0.13, 3, 2, 4))
			end,
		},
		{
			"4 x 3-stud ledges, tread 4",
			function(o, i)
				return walk(o, i, L.terraces(20, 12 + (i - 1) * 0.13, 3, 4, 4))
			end,
		},
		{
			"a 10-stud ramp, then a 5-stud ledge",
			function(o, i)
				return walk(o, i, L.rampLedge(12 + (i - 1) * 0.13, 10, 5))
			end,
		},
		{
			"a jump landing less than 0.2 s before a staircase, walking on",
			function(o, i)
				local ground, boxes = L.stairsTerrain(12, 20, 1.5)
				-- airtime ~0.51 s; the walk reaches the stairs at client time 1.75
				return walk(o, i, ground, boxes, { 1.75 - 0.51 - 0.02 * i })
			end,
		},
	}
	for _, mode in MODES do
		for _, lag in LAGS do
			local o = { mv = mode[2], lag = lag[2] }
			it(`{mode[1]}, {lag[1]}: each case x 10 phases: no drop at all`, function()
				local got, want = {}, {}
				for _, c in CASES do
					table.insert(
						got,
						`{c[1]}: {hardRuns(10, function(i)
							return c[2](o, i)
						end)}`
					)
					table.insert(want, `{c[1]}: 0`)
				end
				expect(got).toEqual(want)
			end)
			it(`{mode[1]}, {lag[1]}: a 15-stud ledge at the end of a 10-stud ramp drops 10/10`, function()
				expect(hardRuns(10, function(i)
					return walk(o, i, L.rampLedge(12 + (i - 1) * 0.13, 10, 15))
				end)).toBe(10)
			end)
		end
	end
end)

describe("i. a connection freeze in mid-air never splits a fall", function()
	for _, mode in MODES do
		it(
			`{mode[1]}: a 20-stud fall frozen 1.3 s and 2.0 s at mid-height, 10 phases: hardLanding 10/10`,
			function()
				for _, F in { 1.3, 2.0 } do
					local res = tally(10, function(i)
						local drop, shift = 20, (i - 1) * 0.1
						local landAt = L.landAt(drop, shift)
						local half = landAt - math.sqrt(2 * drop / G) * (1 - math.sqrt(0.5))
						return L.fall({
							movement = mvOf(mode[2]),
							drop = drop,
							shift = shift,
							before = function(rig)
								rig:runUntil(10, function()
									return rig.fw.now >= half
								end)
								rig.fw:freeze(rig.p, F)
							end,
							seconds = 6,
						})
					end)
					expect(`{F}: {res}`).toBe(`{F}: [Dropped:hardLanding] x10`)
				end
			end
		)
	end
end)

describe("j. a fall next to (or into) a delivery zone is a hard landing, not a delivery", function()
	for _, mode in MODES do
		it(
			`{mode[1]}: 30 studs, landing 2 or 3 studs short of the zone, walking in: hardLanding 10/10`,
			function()
				for _, gap in { 2, 3 } do
					local res = tally(10, function(i)
						local drop = 30
						local landX = 10 + 10 * math.sqrt(2 * drop / G)
						return L.fall({
							movement = mvOf(mode[2]),
							drop = drop,
							shift = (i - 1) * 0.1,
							before = function(rig)
								rig:zone(V(landX + gap + 20, -drop + 4, 0), V(40, 8, 30))
							end,
						})
					end)
					expect(`{gap}: {res}`).toBe(`{gap}: [Dropped:hardLanding] x10`)
				end
			end
		)
		it(`{mode[1]}: 30 studs straight into the zone: hardLanding 10/10`, function()
			local res = tally(10, function(i)
				return L.fall({
					movement = mvOf(mode[2]),
					drop = 30,
					shift = (i - 1) * 0.1,
					before = function(rig)
						rig:zone(V(35, -25, 0), V(40, 10, 30))
					end,
				})
			end)
			expect(res).toBe("[Dropped:hardLanding] x10")
		end)
	end
end)

describe("k. a manual drop right after a landing is still a hard landing", function()
	for _, mode in MODES do
		it(
			`{mode[1]}: carry.drop 0/0.1/0.2/0.3/0.4 s after a 30-stud landing, 10 phases: hardLanding 10/10`,
			function()
				for _, after in { 0, 0.1, 0.2, 0.3, 0.4 } do
					local res = tally(10, function(i)
						local shift = (i - 1) * 0.1
						local landAt = L.landAt(30, shift)
						return L.fall({
							movement = mvOf(mode[2]),
							drop = 30,
							shift = shift,
							before = function(rig)
								rig:runUntil(10, function()
									return rig.fw.now >= landAt + after
								end)
								if rig.carry.stateOf(rig.crate) == "carried" then
									rig.carry.drop(rig.p, rig.crate)
								end
							end,
							seconds = 3,
						})
					end)
					expect(`+{after}: {res}`).toBe(`+{after}: [Dropped:hardLanding] x10`)
				end
			end
		)
	end
end)

describe("l. the clamp's lag never shortens a fall", function()
	for _, mode in MODES do
		it(
			`{mode[1]}: maxFallSpeed 30 (the object trails its carriers), a 12-stud fall x 10 offsets: 10/10`,
			function()
				local lagged = 0
				local hard = hardRuns(10, function(i)
					local rig = L.fall({
						movement = mvOf(mode[2]),
						drop = 12,
						shift = (i - 1) * 0.1,
						carry = { clamp = { maxFallSpeed = 30 } },
						before = function(rig)
							-- at the carriers' touchdown, the object is still well above where it rides on them
							local w = rig.fw.world
							local held = w.boundsOf(rig.crate).p.y - w.rootOf(rig.p).y
							local landAt = L.landAt(12, (i - 1) * 0.1)
							rig:runUntil(10, function()
								return rig.fw.now >= landAt + 0.05
							end)
							if w.boundsOf(rig.crate).p.y - w.rootOf(rig.p).y > held + 2 then
								lagged += 1
							end
						end,
						seconds = 4,
					})
					return rig
				end)
				expect(`{hard} lagged {lagged > 0}`).toBe("10 lagged true")
			end
		)
	end
end)

describe("Landing (pure): touchdown, ledges, freezes", function()
	local p = { gravity = G, hardLandingSpeed = 55, marginStuds = 4 }
	-- feeds (t, y) ticks; probeAt(i, y) -> air, grounded, gap, ledge; returns "<tick>:<height>" per hard landing
	local function feed(ticks, probeAt)
		local f = Landing.new(ticks[1][2], ticks[1][1])
		local out = {}
		for i = 2, #ticks do
			local t, y = ticks[i][1], ticks[i][2]
			local h = Landing.step(f, t, y, y ~= ticks[i - 1][2], 50, p, function()
				return probeAt(i, y)
			end, nil, nil, i)
			if h ~= nil then
				table.insert(out, `{i}:{math.floor(h + 0.5)}`)
			end
		end
		return out, f
	end
	local function airAbove(level)
		return function(_, y)
			if y > level + 3 then
				return true, false, y - level, math.huge
			end
			return false, true, math.max(0, y - level), math.huge
		end
	end

	it(
		"each touchdown ends its fall and the next is measured from there (two 8-stud falls are not one 16)",
		function()
			local ticks = { { 0, 16 }, { 0.1, 16 }, { 0.2, 16 }, { 0.3, 12 }, { 0.4, 8 } }
			for k = 5, 9 do
				table.insert(ticks, { k / 10, 8 })
			end
			table.insert(ticks, { 1.0, 4 })
			table.insert(ticks, { 1.1, 0 })
			for k = 12, 20 do
				table.insert(ticks, { k / 10, 0 })
			end
			local out = feed(ticks, function(i, y)
				local level = if i <= 10 then 8 else 0
				return airAbove(level)(i, y)
			end)
			expect(out).toEqual({})
			-- the same 16 studs in one fall drop
			local one = { { 0, 16 }, { 0.1, 16 }, { 0.2, 16 }, { 0.3, 12 }, { 0.4, 6 }, { 0.5, 0 } }
			expect(feed(one, airAbove(0))).toEqual({ "6:16" })
		end
	)

	it("the height counts at most the carriers' rise plus the highest ledge under the path", function()
		-- a 3-stud jump, then 14 studs below the apex, over ground that only stepped down a stud at a time
		local ticks =
			{ { 0, 20 }, { 0.1, 20 }, { 0.2, 20 }, { 0.3, 23 }, { 0.4, 19 }, { 0.5, 13 }, { 0.6, 9 } }
		local function stairs(ledge)
			return function(_, y)
				local air = y > 12
				return air, not air and y < 10, 0, ledge
			end
		end
		expect(feed(ticks, stairs(1))).toEqual({}) -- min(14, 3 + 1)
		expect(feed(ticks, stairs(11))).toEqual({ "7:14" }) -- min(14, 3 + 11): a ledge
	end)

	it("a freeze in mid-air longer than SETTLE keeps the fall open up to AIR_HOLD", function()
		for _, frozen in { 1.3, 2.0, 2.9 } do
			local ticks = { { 0, 20 }, { 0.1, 20 }, { 0.2, 20 }, { 0.3, 15 }, { 0.4, 10 } }
			local t = 0.4
			for _ = 1, math.floor(frozen * 10 + 0.5) do
				t += 0.1
				table.insert(ticks, { t, 10 })
			end
			table.insert(ticks, { t + 0.1, 0 })
			table.insert(ticks, { t + 0.2, 0 })
			local out = feed(ticks, airAbove(0))
			expect(`{frozen}: {#out}`).toBe(`{frozen}: 1`)
		end
		-- past AIR_HOLD the open fall is decided on what was seen (10 studs: no), and the rest is a new 10-stud fall
		local ticks = { { 0, 20 }, { 0.1, 20 }, { 0.2, 20 }, { 0.3, 15 }, { 0.4, 10 } }
		for k = 5, 40 do
			table.insert(ticks, { k / 10, 10 })
		end
		table.insert(ticks, { 4.1, 0 })
		expect(feed(ticks, airAbove(0))).toEqual({})
	end)

	it("pending: an open fall in the air is measured to the ground under it", function()
		local f = Landing.new(30, 0)
		local function step(t, y)
			return Landing.step(f, t, y, true, 50, p, function()
				return true, false, y, math.huge -- in the air over ground at 0
			end, nil, nil, nil)
		end
		step(0.1, 27)
		expect(Landing.pending(f, p)).toBe(30) -- 3 studs fallen at 30 studs/s, 27 more to the ground under it
		local g = Landing.new(5, 0)
		Landing.step(g, 0.1, 2, true, 50, p, function()
			return true, false, 2, math.huge
		end)
		expect(Landing.pending(g, p)).toBe(nil) -- a 5-stud fall
	end)
end)
