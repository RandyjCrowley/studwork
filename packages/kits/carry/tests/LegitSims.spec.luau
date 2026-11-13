--!nocheck
--[[
	LegitSims: Movement legitimate play that must NOT strike (planted cases 10-20, 43 of the carry design plan; case 44 is in
	CarrySims.spec.luau with the other Carry-agreement cases). Owner: sims builder (D).

	Each case runs on Scenarios.rig (the REAL Movement and the REAL Carry booted together) with the probe's latency model:
	300 ms RTT, freeze-then-catch-up spikes of 0.1-0.3 s (0.5 s one in five) and 0.45 s server hitches. Every case asserts ZERO
	strikes at the shipped defaults. A handful of seeds per case here; Movement's own specs and the 60-seed probe rerun
	(MovementProbesRerun.spec.luau) are the wide sweeps.
]]
local S = require("packages/kits/carry/tests/Scenarios.luau")
local V, CF = S.V, S.CF
local rtt300 = S.jitter.rtt300

local function noStrikes(rig, p)
	expect(table.concat(rig:reasons(p), ",")).toBe("")
end

describe(
	"case 10: 300 ms RTT with jitter (0.1-0.3 s freezes, 0.5 s spikes) and 0.45 s server hitches, walking: zero strikes, and catch-up burst calls are skipped",
	function()
		it("case 10: zero strikes, 4 seeds x 60 s", function()
			for seed = 1, 4 do
				local rig = S.rig({ seed = seed })
				local p = rig:player(1, { path = S.walk(V(0, 3, 0), 16), jitter = rtt300, ping = 0.3 })
				rig:runWithHitches(60, seed)
				noStrikes(rig, p)
			end
		end)

		it(
			"case 10: after a hitch the burst of catch-up calls takes no sample closer than half a period",
			function()
				local rig = S.rig({ seed = 2, isStudio = true })
				local p = rig:player(1, { path = S.walk(V(0, 3, 0), 16), ping = 0.3 })
				rig:run(2)
				rig:hitch(0.45)
				rig:run(0.5)
				local out = rig.h:console("movement", "samples", "1", "20")
				local seen = 0
				for dt in string.gmatch(out, "dt=([%d%.]+)") do
					seen += 1
					expect(tonumber(dt) >= 0.05).toBe(true)
				end
				expect(seen >= 10).toBe(true)
				noStrikes(rig, p)
			end
		)
	end
)

describe("case 11: jumping every 1.2-2.5 s at reported ping 0.3 and 0.05: zero strikes", function()
	for _, ping in { 0.3, 0.05 } do
		it(`case 11: ping {ping}`, function()
			for seed = 1, 3 do
				local rig = S.rig({ seed = seed })
				local p =
					rig:player(1, { path = S.jumper(seed, V(0, 3, 0), 16), jitter = rtt300, ping = ping })
				rig:runWithHitches(40, seed)
				noStrikes(rig, p)
			end
		end)
	end
end)

describe(
	"case 12: walking off a ledge of 10, 20, 60 and 500 studs (the fall arc and the descent bound): zero strikes",
	function()
		for _, drop in { 10, 20, 60, 500 } do
			it(`case 12: {drop} studs`, function()
				for seed = 1, 2 do
					local rig = S.rig({ seed = seed, ground = false })
					rig:box(V(-1024, -2, 0), V(2048, 4, 2048)) -- the upper floor, top y = 0, ends at x = 0
					rig:box(V(1024, -drop - 2, 0), V(2048, 4, 2048)) -- the lower floor, starts at x = 0
					local p = rig:player(
						1,
						{ path = S.ledge(V(-20, 3, 0), 16, 0, drop), jitter = rtt300, ping = 0.3 }
					)
					rig:runWithHitches(12 + math.sqrt(2 * drop / S.G), seed)
					noStrikes(rig, p)
				end
			end)
		end
	end
)

describe(
	"case 13: riding a tagged moving platform at 30 studs/s while walking across it, then jumping off (the grace window); also a conveyor (an anchored part with surface velocity)",
	function()
		local function platformRig(seed)
			local rig = S.rig({ seed = seed, ground = false, movement = { volumes = { Plat = "platform" } } })
			rig:box(V(0, -20, 0), V(8192, 4, 8192)) -- the far-below catch for a jump off
			S.platform(rig, "Plat", 30, 4)
			return rig
		end

		it("case 13: walking across a platform moving at 30 studs/s", function()
			for seed = 1, 3 do
				local rig = platformRig(seed)
				local p = rig:player(
					1,
					{ path = S.platformRider(V(0, 8, 0), 30, 8, 6), jitter = rtt300, ping = 0.3 }
				)
				rig:runWithHitches(30, seed)
				noStrikes(rig, p)
			end
		end)

		it("case 13: jumping off sideways keeps the platform's speed for the grace window", function()
			for seed = 1, 3 do
				local rig = platformRig(seed)
				local jumpAt, fall = 6, 0.82
				local p = rig:player(1, {
					path = function(s)
						if s < jumpAt then
							return V(30 * s, 8, 0)
						end
						local u = math.min(s - jumpAt, fall)
						local y = math.max(8 + 50 * u - 0.5 * S.G * u * u, -17)
						return V(30 * jumpAt + 30 * u + 16 * math.max(0, s - jumpAt - fall), y, 14 * u)
					end,
					jitter = rtt300,
					ping = 0.3,
				})
				rig:run(14)
				noStrikes(rig, p)
			end
		end)

		it("case 13: a conveyor", function()
			for seed = 1, 3 do
				local rig =
					S.rig({ seed = seed, ground = false, movement = { volumes = { Belt = "platform" } } })
				rig:box(V(0, 4, 0), V(4000, 2, 20), { "Belt" }, { surfaceVelocity = V(30, 0, 0) })
				local p = rig:player(1, { path = S.walk(V(0, 8, 0), 30), jitter = rtt300, ping = 0.3 })
				rig:run(30)
				noStrikes(rig, p)
			end
		end)
	end
)

describe(
	"case 14: death with Players.RespawnTime = 5: samples on the dead body are ignored, the new character's first sample inside the respawn envelope of the spawn ends the window (trusted), the player walks away at once: no strike; also at 20 ms ping",
	function()
		for _, latency in { 0.15, 0.01 } do
			local tag = if latency > 0.1 then "300 ms" else "20 ms"
			it(`case 14: {tag}`, function()
				for seed = 1, 3 do
					local rig = S.rig({ seed = seed, fw = { baseLatency = latency } })
					local spawn = V(0, 5, 0)
					local p = rig:player(1, {
						path = S.walk(V(0, 3, 0), 16),
						jitter = rtt300,
						ping = 0.3,
						baseLatency = latency,
					})
					rig:run(5)
					rig.fw:kill(p)
					local cf, trusted = rig.mv.lastValid(p)
					expect(cf).toBeNil()
					expect(trusted).toBe(false)
					rig:run(5) -- RespawnTime
					rig.fw:removeCharacter(p)
					rig.fw:spawnCharacter(p, spawn, { path = S.spawnWalk(spawn, 3, 16, rig.fw.now) })
					local arrived = rig:runUntil(3, function()
						return select(2, rig.mv.lastValid(p)) == true
					end)
					expect(arrived ~= nil).toBe(true)
					rig:run(5)
					noStrikes(rig, p)
				end
			end)
		end
	end
)

describe(
	"case 15: a Plot-style character:PivotTo on spawn, and mid-session, by code that does not know Movement exists: an anchor through onServerMove, no strike, and never a yank back to the spawn",
	function()
		it("case 15: on spawn", function()
			for seed = 1, 3 do
				local rig = S.rig({ seed = seed })
				local p = rig:player(1, { path = S.walk(V(0, 3, 0), 16), jitter = rtt300, ping = 0.3 })
				rig:run(3)
				rig.fw:kill(p)
				rig:run(2)
				rig.fw:removeCharacter(p)
				rig.fw:spawnCharacter(p, V(0, 5, 0))
				rig.fw:serverMove(p, CF.new(V(300, 5, 300)))
				rig:run(5)
				noStrikes(rig, p)
				expect(rig.fw.cframeWrites).toBe(0)
				local cf, trusted = rig.mv.lastValid(p)
				expect(trusted).toBe(true)
				expect(cf.p.x).toBeNear(300, 1)
			end
		end)

		it("case 15: mid-session", function()
			for seed = 1, 3 do
				local rig = S.rig({ seed = seed })
				local p = rig:player(1, { path = S.walk(V(0, 3, 0), 16), jitter = rtt300, ping = 0.3 })
				rig:run(4)
				rig.fw:serverMove(p, CF.new(V(0, 3, 500)))
				rig:run(6)
				noStrikes(rig, p)
				expect(rig.fw.cframeWrites).toBe(0)
				expect(math.abs(select(1, rig.mv.lastValid(p)).p.z - 500) < 8).toBe(true)
			end
		end)
	end
)

describe(
	"case 16: Movement.teleport a long distance: the anchor clears near the target; then the stale-sample case: old-position samples arrive first and pass against the pre-move base",
	function()
		it("case 16", function()
			for seed = 1, 3 do
				local rig = S.rig({ seed = seed })
				local p = rig:player(1, { path = S.walk(V(0, 3, 0), 16), jitter = rtt300, ping = 0.3 })
				rig:run(4)
				rig.mv.teleport(p, CF.new(V(0, 3, 400)))
				rig:run(6)
				noStrikes(rig, p)
				expect(rig.fw.cframeWrites).toBe(1) -- exactly Movement's own write, never re-issued
				expect(rig:trusted(p)).toBe(true)
				expect(math.abs(select(1, rig.mv.lastValid(p)).p.z - 400) < 8).toBe(true)
			end
		end)
	end
)

describe(
	"case 17: a real seat (a server SeatWeld) moved fast by game code: no strike, checked relative to the seat; the Seated state with no weld gets no exemption",
	function()
		local function seatRig(weld)
			local rig = S.rig({ seed = 2, ground = false })
			local seat = rig:box(V(0, 3, 0), V(4, 1, 4), nil, {
				motion = function(t)
					return CF.new(V(60 * t, 3, 0))
				end,
			})
			local p = rig:player(1, {
				path = function(s)
					return V(60 * s, 3, 0)
				end,
				jitter = rtt300,
				ping = 0.3,
			})
			rig.fw:seat(p, seat, { weld = weld })
			rig.fw:setState(p, "Seated")
			return rig, p
		end

		it("case 17: welded", function()
			local rig, p = seatRig(true)
			rig:run(20)
			noStrikes(rig, p)
		end)

		it("case 17: no weld", function()
			local rig, p = seatRig(false)
			rig:run(20)
			expect(rig:count(p, "speed") + rig:count(p, "teleport") >= 1).toBe(true)
		end)
	end
)

describe(
	"case 18: climbing a TrussPart: no strike; Climbing with no truss nearby gets no exemption",
	function()
		local function climb(withTruss)
			local rig = S.rig({ seed = 1 })
			if withTruss then
				rig:box(V(0, 100, -2), V(1, 200, 1), nil, { className = "TrussPart" })
			end
			local p = rig:player(1, {
				path = function(s)
					return V(0, 3 + 8 * s, 0)
				end,
				jitter = rtt300,
				ping = 0.3,
			})
			rig.fw:setState(p, "Climbing")
			rig:run(12)
			return rig, p
		end

		it("case 18: next to a truss", function()
			local rig, p = climb(true)
			noStrikes(rig, p)
		end)

		it("case 18: no truss", function()
			local rig, p = climb(false)
			expect(rig:count(p, "riseSpeed") + rig:count(p, "noGround") >= 1).toBe(true)
		end)
	end
)

describe(
	"case 19: a game speed boost (server WalkSpeed 32) gives no strike, because the cap follows WalkSpeed",
	function()
		it("case 19", function()
			for seed = 1, 3 do
				local rig = S.rig({ seed = seed })
				local p = rig:player(1, {
					path = S.walk(V(0, 3, 0), 32),
					jitter = rtt300,
					ping = 0.3,
					walkSpeed = 32,
				})
				rig:runWithHitches(40, seed)
				noStrikes(rig, p)
			end
		end)
	end
)

describe(
	"case 20: the flag turned off then on mid-session: a fresh baseline and no teleport strike",
	function()
		it("case 20", function()
			local rig = S.rig({
				seed = 1,
				movement = { flag = "movementOn" },
				flags = { movementOn = { default = true } },
				isStudio = true,
			})
			local p = rig:player(1, { path = S.teleporting(S.stand(V(0, 3, 0)), 8, V(200, 0, 0)) })
			rig:run(3)
			expect(rig:trusted(p)).toBe(true)
			rig.h:console("flags set movementOn false")
			rig:run(1)
			local cf, trusted = rig.mv.lastValid(p)
			expect(cf).toBeNil()
			expect(trusted).toBe(false)
			rig:run(8) -- the 200-stud move happens while the flag is off
			rig.h:console("flags set movementOn true")
			rig:run(2)
			noStrikes(rig, p)
			local cf3, t3 = rig.mv.lastValid(p)
			expect(t3).toBe(true)
			expect(cf3.p.x).toBeNear(200, 0.01)
		end)
	end
)

describe(
	"case 43: stop-and-go at low ping: stand 4.5-6 s, walk 1-3 s, reported ping 0.05 with 0.5 s freezes, for 60 s: zero strikes (the empty-window case); also on a 30 studs/s platform",
	function()
		it("case 43: on the ground", function()
			for seed = 1, 3 do
				local rig = S.rig({ seed = seed })
				local p = rig:player(1, {
					path = S.stopAndGo(seed, V(0, 3, 0), 16, 60),
					jitter = S.jitter.spiky,
					ping = 0.05,
				})
				rig:runWithHitches(60, seed)
				noStrikes(rig, p)
			end
		end)

		it("case 43: on a 30 studs/s platform", function()
			for seed = 1, 3 do
				local rig =
					S.rig({ seed = seed, ground = false, movement = { volumes = { Plat = "platform" } } })
				S.platform(rig, "Plat", 30, 4)
				local inner = S.stopAndGo(seed, V(0, 8, 0), 8, 30)
				local p = rig:player(1, {
					path = function(s)
						local q = inner(s)
						return V(q.x + 30 * s, q.y, 0)
					end,
					jitter = S.jitter.spiky,
					ping = 0.05,
				})
				rig:run(30)
				noStrikes(rig, p)
			end
		end)
	end
)
