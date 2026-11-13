--!nocheck
--[[
	CheatSims: Movement cheats that must be caught (planted cases 1-9 and 39-42 of the carry design plan).
	Owner: sims builder (D).

	Each case is run end to end on Scenarios.rig: the REAL Movement and the REAL Carry booted together on FakeWorld with the
	latency model (Movement's own unit-level specs are MovementCheats.spec.luau; these add Carry booted beside it and a
	bystander walking the whole time, so a cheat in one player's samples is not allowed to touch another's).
]]
local S = require("packages/kits/carry/tests/Scenarios.luau")
local V, CF, FakeWorld = S.V, S.CF, S.FakeWorld
local rtt300 = S.jitter.rtt300

-- a legit bystander on its own lane, to prove the cheat's strikes stay on the cheater
local function bystander(rig)
	return rig:player(90, { path = S.walk(V(0, 3, 80), 12), jitter = rtt300, ping = 0.3 })
end

local function reasonsOf(rig, p)
	local out = {}
	for _, s in rig:strikes(p) do
		out[s.reason] = (out[s.reason] or 0) + 1
	end
	return out
end

describe(
	"case 1: 10-stud teleport past a hazard: caught by the volume sweep, not the per-sample cap (from standstill and after walking up to it, 300 ms jitter; a volumeSweep strike and no teleport strike, 10 < 13.88)",
	function()
		local function run(seed, walkingUp, jitter)
			local rig = S.rig({ seed = seed, movement = { volumes = { Hazard = "hazard" } } })
			rig:box(V(0, 3, 0), V(0.5, 8, 30), { "Hazard" }, { canCollide = false })
			local base = if walkingUp then S.walk(V(-40, 3, 0), 16) else S.stand(V(-5, 3, 0))
			local path = S.teleporting(base, if walkingUp then 2.25 else 4, V(10, 0, 0))
			local p = rig:player(1, { path = path, jitter = jitter, ping = 0.3 })
			local b = bystander(rig)
			rig:run(8)
			return rig, p, b
		end

		it("case 1: from standstill", function()
			local rig, p, b = run(1, false, nil)
			local r = reasonsOf(rig, p)
			expect(r.volumeSweep).toBe(1)
			expect(r.teleport).toBeNil()
			expect(#rig:strikes(b)).toBe(0)
		end)

		it(
			"case 1: after walking up to it, no jitter: a volumeSweep strike and no teleport strike",
			function()
				local rig, p = run(1, true, nil)
				local r = reasonsOf(rig, p)
				expect(r.volumeSweep).toBe(1)
				expect(r.teleport).toBeNil()
			end
		)

		-- With 300 ms jitter a freeze-then-catch-up can add up to ~6 studs of legitimate walking to the 10-stud cheat
		-- inside one sample (10 + 4.8 > 13.88): the teleport cap may fire TOO (seen in 3 of 8 seeds). The volume sweep
		-- must catch it in every seed; a teleport strike is allowed only when its own measured value is over its limit.
		it("case 1: after walking up to it, 300 ms jitter, 8 seeds: always the volume sweep", function()
			for seed = 1, 8 do
				local rig, p = run(seed, true, rtt300)
				expect(rig:count(p, "volumeSweep")).toBe(1)
				for _, s in rig:strikes(p) do
					if s.reason == "teleport" then
						expect(s.details.value > s.details.limit).toBe(true)
					end
				end
			end
		end)
	end
)

describe(
	"case 2: in-place teleport with no volume between: caught by the teleport cap (a 25-stud teleport gives a teleport strike)",
	function()
		it("case 2", function()
			local rig = S.rig({ seed = 1 })
			local p = rig:player(1, { path = S.teleporting(S.stand(V(0, 3, 0)), 4, V(25, 0, 0)) })
			local b = bystander(rig)
			rig:run(8)
			expect(rig:count(p, "teleport")).toBe(1)
			expect(#rig:strikes(p)).toBe(1)
			expect(#rig:strikes(b)).toBe(0)
		end)
	end
)

describe(
	"case 3: floating or hovering over a 40-stud gap at constant height: noGround within about 1.5 s",
	function()
		it("case 3", function()
			for seed = 1, 3 do
				local rig = S.rig({ seed = seed, ground = false })
				rig:box(V(-1024, -2, 0), V(2048, 4, 2048)) -- top at y = 0, ends at x = 0
				rig:box(V(1064, -2, 0), V(2048, 4, 2048)) -- starts at x = 40
				local p = rig:player(1, { path = S.walk(V(-20, 3, 0), 16), jitter = rtt300, ping = 0.3 })
				local edgeAt = 20 / 16
				local struckAt = rig:runUntil(5, function()
					return rig:count(p, "noGround") > 0
				end)
				expect(struckAt ~= nil).toBe(true)
				expect(struckAt - edgeAt < 2.4).toBe(true)
				expect(struckAt - edgeAt > 0.9).toBe(true)
			end
		end)
	end
)

describe(
	"case 4: sustained speed hack at 1.5x server WalkSpeed (24 studs/s): a speed strike from the 4 s window at ping 0.3 s, and again with ping inflated to 1.0 s (lag clamped to 0.75)",
	function()
		for _, ping in { 0.3, 1.0 } do
			it(`case 4: ping {ping}`, function()
				for seed = 1, 4 do
					local rig = S.rig({ seed = seed })
					local p = rig:player(1, { path = S.walk(V(0, 3, 0), 24), jitter = rtt300, ping = ping })
					local at = rig:runUntil(10, function()
						return rig:count(p, "speed") > 0
					end)
					expect(at ~= nil).toBe(true)
					expect(at < 8).toBe(true)
				end
			end)
		end
	end
)

describe(
	"case 5: noclip through a 1-stud wall: wallSweep (also when the crossing falls on a skipped sample at everySamples = 2); walking around the end of a thin wall gives no strike (edge margin); a chord that cuts a corner gives no strike (non-parallel faces)",
	function()
		it("case 5: straight through, whichever sample the crossing lands on", function()
			for offset = 0, 5 do
				local rig = S.rig({ seed = offset + 1 })
				rig:box(V(30, 6, 0), V(1, 12, 40))
				local p = rig:player(1, { path = S.walk(V(5 + offset * 0.37, 3, 0), 16) })
				rig:run(3)
				expect(rig:count(p, "wallSweep") >= 1).toBe(true)
				expect(rig:count(p, "teleport")).toBe(0)
			end
		end)

		it("case 5: walking round the end of a thin wall: no strike", function()
			local rig = S.rig({ seed = 2 })
			rig:box(V(30, 6, 0), V(1, 12, 40))
			local pts = { V(5, 3, 0), V(29.5, 3, 0), V(29.5, 3, 20.4), V(31, 3, 20.4), V(40, 3, 20.4) }
			local path = function(s)
				local d, acc = s * 16, 0
				for i = 1, #pts - 1 do
					local len = vector.magnitude(pts[i + 1] - pts[i])
					if d <= acc + len then
						return pts[i] + (pts[i + 1] - pts[i]) * ((d - acc) / len)
					end
					acc += len
				end
				return pts[#pts]
			end
			local p = rig:player(1, { path = path, jitter = rtt300 })
			rig:run(8)
			expect(rig:count(p, "wallSweep")).toBe(0)
		end)

		it("case 5: a chord that cuts a corner: no strike", function()
			local rig = S.rig({ seed = 1 })
			rig:box(V(0, 6, 0), V(10, 12, 10))
			local p = rig:player(1, {
				path = function(s)
					return if s < 3 then V(-5.5, 3, 2) else V(-3, 3, 5.5)
				end,
			})
			rig:run(6)
			expect(rig:count(p, "wallSweep")).toBe(0)
			expect(rig:count(p, "teleport")).toBe(0)
		end)
	end
)

describe(
	"case 6: fly hack: rising 5 studs/s while drifting gives riseSpeed/noGround; the same fly with a forged PlatformStanding or Climbing state and no truss is still caught",
	function()
		it("case 6", function()
			for _, state in { false, "PlatformStanding", "Climbing", "Seated" } do
				local rig = S.rig({ seed = 2 })
				local p = rig:player(1, {
					path = function(s)
						return V(12 * s, 3 + 5 * s, 0)
					end,
					jitter = rtt300,
				})
				if state then
					rig.fw:setState(p, state)
				end
				local at = rig:runUntil(8, function()
					return rig:count(p, "riseSpeed") + rig:count(p, "noGround") > 0
				end)
				expect(at ~= nil).toBe(true)
			end
		end)
	end
)

describe(
	"case 7: entering a noEntry volume gives a volumeSweep strike; crossing a checkpoint between samples fires VolumeCrossed and no strike",
	function()
		it("case 7: noEntry", function()
			local rig = S.rig({ seed = 1, movement = { volumes = { Wall = "noEntry" } } })
			rig:box(V(20, 3, 0), V(8, 8, 8), { "Wall" }, { canCollide = false })
			local p = rig:player(1, { path = S.walk(V(0, 3, 0), 16) })
			rig:run(4)
			expect(rig:count(p, "volumeSweep")).toBe(1)
			expect(rig.strikeLog[1].details.kind).toBe("noEntry")
		end)

		it("case 7: checkpoint", function()
			local rig = S.rig({ seed = 1, movement = { volumes = { Gate = "checkpoint" } } })
			local gate = rig:box(V(20, 3, 0), V(0.2, 8, 8), { "Gate" }, { canCollide = false })
			local p = rig:player(1, { path = S.walk(V(0, 3, 0), 16) })
			rig:run(4)
			expect(#rig:strikes(p)).toBe(0)
			expect(#rig.crossLog).toBe(1)
			expect(rig.crossLog[1].kind).toBe("checkpoint")
			expect(rig.crossLog[1].volume).toBe(gate)
		end)
	end
)

describe(
	'case 8: 200-stud teleport with responses.teleport = "strike": exactly one teleport strike (no storm), lastValid stays put then advances after 3 clean samples; at log: still exactly one strike recorded and lastValid follows (trust kept)',
	function()
		local function tele(response)
			local cfg = if response then { responses = { teleport = response } } else {}
			local rig = S.rig({ seed = 1, movement = cfg })
			local p = rig:player(1, { path = S.teleporting(S.stand(V(0, 3, 0)), 4, V(200, 0, 0)) })
			return rig, p
		end

		it("case 8: strike", function()
			local rig, p = tele("strike")
			rig:runUntil(8, function()
				return #rig:strikes(p) > 0
			end)
			expect(#rig:strikes(p)).toBe(1)
			local cf, trusted = rig.mv.lastValid(p)
			expect(trusted).toBe(false)
			expect(cf.p.x).toBeNear(0, 0.01)
			rig:run(0.7)
			local cf2, back = rig.mv.lastValid(p)
			expect(back).toBe(true)
			expect(cf2.p.x).toBeNear(200, 0.01)
			expect(#rig:strikes(p)).toBe(1)
		end)

		it("case 8: log", function()
			local rig, p = tele(nil)
			rig:runUntil(8, function()
				return #rig:strikes(p) > 0
			end)
			local cf, trusted = rig.mv.lastValid(p)
			expect(trusted).toBe(true)
			expect(cf.p.x).toBeNear(200, 0.01)
			rig:run(2)
			expect(#rig:strikes(p)).toBe(1)
		end)
	end
)

describe(
	"case 9: a cheat during an open anchor: a server teleport is pending and the client moves 40 studs elsewhere: a strike against the pre-move base (the anchor is not a free window)",
	function()
		it("case 9", function()
			local rig = S.rig({ seed = 1 })
			local p = rig:player(1, { path = S.stand(V(0, 3, 0)) })
			rig:run(3)
			rig.fw:setPath(p, S.teleporting(S.stand(V(0, 3, 0)), rig.fw.now + 0.05, V(0, 0, 40)))
			rig.fw:serverMove(p, CF.new(V(100, 3, 0)))
			rig:run(2)
			expect(rig:count(p, "teleport") >= 1).toBe(true)
		end)
	end
)

describe(
	"case 39: respawn used as a teleport: reset the character, teleport 60 studs as the new character arrives, stand still: must strike teleport (details.respawn = true when the cheat replicates before the first sample); variants: keep wandering (strikes at maxSettleSeconds); 30 studs past a checkpoint (strike); 200 studs straight down (strike); at 300 ms and at 20 ms",
	function()
		local function respawnCheat(baseLatency, cheat, seed)
			local rig = S.rig({
				seed = seed,
				movement = { volumes = { Gate = "checkpoint" } },
				fw = { baseLatency = baseLatency },
			})
			rig:box(V(15, 3, 0), V(0.2, 8, 10), { "Gate" }, { canCollide = false })
			local spawn = V(0, 5, 0)
			local p = rig:player(1, { path = S.stand(spawn), baseLatency = baseLatency })
			rig:run(2)
			rig.fw:kill(p)
			rig:run(0.5)
			rig.fw:removeCharacter(p)
			rig.fw:spawnCharacter(p, spawn, { path = cheat })
			rig:run(8)
			return rig, p
		end

		for _, latency in { 0.15, 0.01 } do
			local tag = if latency > 0.1 then "300 ms" else "20 ms"
			it(`case 39: 60 studs as the character arrives, standing still ({tag})`, function()
				for seed = 1, 3 do
					local rig, p = respawnCheat(latency, S.stand(V(60, 5, 0)), seed)
					expect(rig:count(p, "teleport") >= 1).toBe(true)
				end
			end)
			it(`case 39: wandering never settles ({tag})`, function()
				local wander = function(s)
					return V(40 + 8 * math.sin(s * 3), 5, 8 * math.cos(s * 3))
				end
				local rig, p = respawnCheat(latency, wander, 1)
				expect(rig:count(p, "teleport") >= 1).toBe(true)
			end)
			it(`case 39: 30 studs past a checkpoint ({tag})`, function()
				local rig, p = respawnCheat(latency, S.stand(V(30, 5, 0)), 2)
				expect(rig:count(p, "teleport") >= 1).toBe(true)
			end)
			it(`case 39: 200 studs straight down ({tag})`, function()
				local rig, p = respawnCheat(latency, S.stand(V(0, -195, 0)), 3)
				expect(rig:count(p, "teleport") >= 1).toBe(true)
			end)
		end

		it("case 39: details.respawn is set when the cheat replicates before the first sample", function()
			local hits = 0
			for seed = 1, 6 do
				local rig, p = respawnCheat(0.01, S.stand(V(60, 5, 0)), seed)
				for _, s in rig:strikes(p) do
					if s.details.respawn then
						hits += 1
					end
				end
			end
			expect(hits >= 1).toBe(true)
		end)
	end
)

describe(
	"case 40: teleport straight down 60 and 200 studs from standing (through a floor): teleport with details.descent = true",
	function()
		for _, drop in { 60, 200 } do
			it(`case 40: {drop} studs`, function()
				local rig = S.rig({ seed = 1 })
				local p = rig:player(1, { path = S.teleporting(S.stand(V(0, 3, 0)), 4, V(0, -drop, 0)) })
				rig:run(5.5)
				expect(rig:count(p, "teleport", function(s)
					return s.details.descent == true
				end)).toBe(1)
			end)
		end
	end
)

describe(
	"case 41: trust rule: at responses.volumeSweep = strike, walking through a hazard records a volumeSweep strike and lastValid stays trusted; a noEntry crossing makes it untrusted; a log teleport or speed strike never makes it untrusted",
	function()
		it("case 41: hazard at strike keeps trust", function()
			local rig = S.rig({
				seed = 1,
				movement = { volumes = { Lava = "hazard" }, responses = { volumeSweep = "strike" } },
			})
			rig:box(V(20, 3, 0), V(2, 8, 8), { "Lava" }, { canCollide = false })
			local p = rig:player(1, { path = S.walk(V(0, 3, 0), 16) })
			rig:run(2.5)
			expect(rig:count(p, "volumeSweep")).toBe(1)
			expect(rig:trusted(p)).toBe(true)
		end)

		it("case 41: noEntry at strike revokes trust", function()
			local rig =
				S.rig({ seed = 1, movement = { volumes = { Wall = "noEntry" }, response = "strike" } })
			rig:box(V(20, 3, 0), V(2, 8, 8), { "Wall" }, { canCollide = false })
			local p = rig:player(1, { path = S.walk(V(0, 3, 0), 16) })
			rig:runUntil(4, function()
				return rig:count(p, "volumeSweep") > 0
			end)
			expect(rig:trusted(p)).toBe(false)
		end)

		it("case 41: a log teleport or speed strike never makes it untrusted", function()
			local rig = S.rig({ seed = 1 })
			local path = S.teleporting(FakeWorld.paths.line(V(0, 3, 0), V(24, 0, 0)), 3, V(0, 0, 60))
			local p = rig:player(1, { path = path })
			local untrusted = false
			rig:run(12, function()
				if rig.mv.lastValid(p) and not rig:trusted(p) then
					untrusted = true
				end
			end)
			expect(rig:count(p, "teleport") >= 1).toBe(true)
			expect(rig:count(p, "speed") >= 1).toBe(true)
			expect(untrusted).toBe(false)
		end)
	end
)

describe(
	"case 42: hover still in the air over a gap (walk out, stop): noGround, so the cheap path's still skip does not apply to an airborne player",
	function()
		it("case 42", function()
			for seed = 1, 3 do
				local rig = S.rig({ seed = seed, ground = false })
				rig:box(V(-1024, -2, 0), V(2048, 4, 2048))
				rig:box(V(1064, -2, 0), V(2048, 4, 2048))
				local p = rig:player(1, {
					path = function(s)
						return V(math.min(-10 + 16 * s, 10), 3, 0)
					end,
					jitter = rtt300,
					ping = 0.3,
				})
				local at = rig:runUntil(8, function()
					return rig:count(p, "noGround") > 0
				end)
				expect(at ~= nil).toBe(true)
			end
		end)
	end
)
