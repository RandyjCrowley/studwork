--!nocheck
--[[
	Movement cheats that MUST be caught: planted cases 1-9 and 39-42 (design plan), against the REAL Movement part
	on FakeWorld with the latency model of the design probe. Responses are left at the default `log` unless a case
	says otherwise (a logged failure is still recorded and still fires Strike).
]]
local Rig = require("packages/kits/carry/tests/MovementRig.luau")
local V, FakeWorld, CF = Rig.V, Rig.FakeWorld, Rig.CF
local rtt300 = FakeWorld.jitter.rtt300

local function reasonsOf(rig, p)
	local out = {}
	for _, s in rig:strikesOf(p) do
		out[s.reason] = (out[s.reason] or 0) + 1
	end
	return out
end

describe(
	"case 1: 10-stud teleport past a hazard is caught by the volume sweep, not the per-sample cap",
	function()
		local function run(seed, walkingUp, jitter)
			local rig = Rig.new({ seed = seed, config = { volumes = { Hazard = "hazard" } } })
			rig:box(V(0, 3, 0), V(0.5, 8, 30), { "Hazard" }, { canCollide = false })
			local base = if walkingUp then Rig.walk(V(-40, 3, 0), 16) else FakeWorld.paths.stand(V(-5, 3, 0))
			-- walking: the client is at x = -4 at s = 2.25
			local path = FakeWorld.paths.teleportAt(base, if walkingUp then 2.25 else 4, V(10, 0, 0))
			local p = rig:player(1, { path = path, jitter = jitter, ping = 0.3 })
			rig:run(8)
			return rig, p
		end

		it("from standstill: a volumeSweep strike and no teleport strike (10 < 13.88)", function()
			local rig, p = run(1, false, nil)
			local r = reasonsOf(rig, p)
			expect(r.volumeSweep).toBe(1)
			expect(r.teleport).toBeNil()
			expect(rig.strikeLog[1].details.kind).toBe("hazard")
			expect(rig.strikeLog[1].details.response).toBe("log")
		end)

		it("after walking up to it, 300 ms jitter: caught by the volume sweep in every seed", function()
			for seed = 1, 6 do
				local rig, p = run(seed, true, rtt300)
				expect(rig:count(p, "volumeSweep") >= 1).toBe(true)
			end
		end)

		it(
			"the same crossing with the volume sweep off the map is NOT caught by the teleport cap alone",
			function()
				local rig = Rig.new({ seed = 2 })
				local path = FakeWorld.paths.teleportAt(FakeWorld.paths.stand(V(-5, 3, 0)), 4, V(10, 0, 0))
				local p = rig:player(1, { path = path })
				rig:run(8)
				expect(#rig:strikesOf(p)).toBe(0)
			end
		)
	end
)

describe("case 2: in-place teleport with no volume between is caught by the teleport cap", function()
	it("a 25-stud teleport gives exactly one teleport strike", function()
		local rig = Rig.new({ seed = 1 })
		local path = FakeWorld.paths.teleportAt(FakeWorld.paths.stand(V(0, 3, 0)), 4, V(25, 0, 0))
		local p = rig:player(1, { path = path, jitter = nil })
		rig:run(8)
		expect(rig:count(p, "teleport")).toBe(1)
		expect(#rig:strikesOf(p)).toBe(1)
		local s = rig:strikesOf(p)[1]
		expect(s.details.value > s.details.limit).toBe(true)
		expect(s.details.limit).toBeNear(13.88, 0.01)
	end)
end)

describe("case 3: floating over a 40-stud gap at constant height: noGround", function()
	it(
		"caught within about 1.5 s of the player leaving the ledge (never over the gap's whole width)",
		function()
			for seed = 1, 4 do
				local rig = Rig.new({ seed = seed, ground = false })
				rig:box(V(-1024, -2, 0), V(2048, 4, 2048)) -- top at y = 0, ends at x = 0
				rig:box(V(1064, -2, 0), V(2048, 4, 2048)) -- starts at x = 40
				local p = rig:player(1, { path = Rig.walk(V(-20, 3, 0), 16), jitter = rtt300, ping = 0.3 })
				local edgeAt = 20 / 16 -- the client crosses x = 0
				local struckAt = rig:runUntil(5, function()
					return rig:count(p, "noGround") > 0
				end)
				expect(struckAt ~= nil).toBe(true)
				expect(struckAt - edgeAt < 2.4).toBe(true) -- 1.3-1.5 s plus the view's lag and the freeze
				expect(struckAt - edgeAt > 0.9).toBe(true) -- never a false positive on the way off the ledge
			end
		end
	)
end)

describe("case 4: a sustained speed hack at 1.5x server WalkSpeed is caught by the 4 s window", function()
	for _, ping in { 0.3, 1.0 } do
		it(`24 studs/s with WalkSpeed 16 at reported ping {ping}: a speed strike`, function()
			local worst = 0
			for seed = 1, 6 do
				local rig = Rig.new({ seed = seed })
				local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 24), jitter = rtt300, ping = ping })
				local at = rig:runUntil(10, function()
					return rig:count(p, "speed") > 0
				end)
				expect(at ~= nil).toBe(true)
				worst = math.max(worst, at)
			end
			expect(worst < 8).toBe(true)
		end)
	end
end)

describe("case 5: noclip through a 1-stud wall: wallSweep", function()
	local function wallRig(seed)
		local rig = Rig.new({ seed = seed })
		rig:box(V(30, 6, 0), V(1, 12, 40)) -- a thin solid wall across the path
		return rig
	end

	it(
		"walking straight through is caught, whichever sample the crossing lands on (everySamples = 2)",
		function()
			for offset = 0, 7 do
				local rig = wallRig(offset + 1)
				local p = rig:player(1, { path = Rig.walk(V(5 + offset * 0.37, 3, 0), 16) })
				rig:run(3)
				expect(rig:count(p, "wallSweep") >= 1).toBe(true)
				expect(rig:count(p, "teleport")).toBe(0)
			end
		end
	)

	it("with everySamples = 1 the same noclip is caught too", function()
		local rig = Rig.new({ seed = 3, config = { wallSweep = { everySamples = 1 } } })
		rig:box(V(30, 6, 0), V(1, 12, 40))
		local p = rig:player(1, { path = Rig.walk(V(5, 3, 0), 16) })
		rig:run(3)
		expect(rig:count(p, "wallSweep") >= 1).toBe(true)
	end)

	it("walking round the end of a thin wall gives no strike (the edge margin)", function()
		for seed = 1, 4 do
			local rig = wallRig(seed)
			-- along +X to x = 27, round the wall's end at z = +20 (hugging it), then +X past the wall
			local path = function(s)
				local pts = { V(5, 3, 0), V(29.5, 3, 0), V(29.5, 3, 20.4), V(31, 3, 20.4), V(40, 3, 20.4) }
				local d = s * 16
				local acc = 0
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
		end
	end)

	it("a chord that cuts a corner gives no strike (the faces are not parallel)", function()
		local rig = Rig.new({ seed = 1 })
		rig:box(V(0, 6, 0), V(10, 12, 10)) -- a pillar: x, z in -5..5
		-- the client steps from (-5.5, 2) round the pillar's corner to (-3, 5.5): the chord clips it
		local path = function(s)
			return if s < 3 then V(-5.5, 3, 2) else V(-3, 3, 5.5)
		end
		local p = rig:player(1, { path = path })
		rig:run(6)
		expect(rig:count(p, "wallSweep")).toBe(0)
		expect(rig:count(p, "teleport")).toBe(0)
	end)
end)

describe("case 6: fly hack", function()
	local function fly(state)
		local rig = Rig.new({ seed = 2 })
		local path = function(s)
			return V(12 * s, 3 + 5 * s, 0)
		end
		local p = rig:player(1, { path = path, jitter = rtt300 })
		if state then
			rig.fw:setState(p, state)
		end
		local at = rig:runUntil(8, function()
			return rig:count(p, "riseSpeed") + rig:count(p, "noGround") > 0
		end)
		return rig, p, at
	end

	it("rising 5 studs/s while drifting 12 studs/s: riseSpeed or noGround", function()
		local _, _, at = fly(nil)
		expect(at ~= nil).toBe(true)
	end)

	it(
		"the same fly with a forged PlatformStanding or Climbing state and no truss is still caught",
		function()
			for _, state in { "PlatformStanding", "Climbing", "Seated" } do
				local _, _, at = fly(state)
				expect(at ~= nil).toBe(true)
			end
		end
	)
end)

describe("case 7: volumes", function()
	it("entering a noEntry volume gives a volumeSweep strike (kind noEntry)", function()
		local rig = Rig.new({ seed = 1, config = { volumes = { Wall = "noEntry" } } })
		rig:box(V(20, 3, 0), V(8, 8, 8), { "Wall" }, { canCollide = false })
		local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 16) })
		rig:run(4)
		expect(rig:count(p, "volumeSweep")).toBe(1)
		expect(rig.strikeLog[1].details.kind).toBe("noEntry")
	end)

	it("crossing a checkpoint between samples fires VolumeCrossed and no strike", function()
		local rig = Rig.new({ seed = 1, config = { volumes = { Gate = "checkpoint" } } })
		local gate = rig:box(V(20, 3, 0), V(0.2, 8, 8), { "Gate" }, { canCollide = false })
		local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 16) })
		rig:run(4)
		expect(#rig:strikesOf(p)).toBe(0)
		expect(#rig.crossLog).toBe(1)
		expect(rig.crossLog[1].kind).toBe("checkpoint")
		expect(rig.crossLog[1].volume).toBe(gate)
	end)

	it("a hazard fires VolumeCrossed too, and registerVolume adds a tag at runtime", function()
		local rig = Rig.new({ seed = 1 })
		rig.api.registerVolume("Lava", "hazard")
		rig:box(V(20, 3, 0), V(2, 8, 8), { "Lava" }, { canCollide = false })
		local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 16) })
		rig:run(4)
		expect(rig:count(p, "volumeSweep")).toBe(1)
		expect(rig.crossLog[1].kind).toBe("hazard")
	end)

	it(
		"a player who stays inside a volume strikes once (the entering sample), not on every sample",
		function()
			local rig = Rig.new({ seed = 1, config = { volumes = { Lava = "hazard" } } })
			rig:box(V(40, 3, 0), V(60, 8, 20), { "Lava" }, { canCollide = false })
			local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 16) })
			rig:run(6)
			expect(rig:count(p, "volumeSweep")).toBe(1)
		end
	)
end)

describe("case 8: a 200-stud teleport", function()
	local function tele(response)
		local cfg = if response then { responses = { teleport = response } } else {}
		local rig = Rig.new({ seed = 1, config = cfg })
		local path = FakeWorld.paths.teleportAt(FakeWorld.paths.stand(V(0, 3, 0)), 4, V(200, 0, 0))
		local p = rig:player(1, { path = path })
		return rig, p
	end

	it(
		'at responses.teleport = "strike": exactly one strike, lastValid stays put, then advances after 3 clean samples',
		function()
			local rig, p = tele("strike")
			rig:runUntil(8, function()
				return #rig:strikesOf(p) > 0
			end)
			expect(#rig:strikesOf(p)).toBe(1)
			local cf, trusted = rig.api.lastValid(p)
			expect(trusted).toBe(false)
			expect(cf.p.x).toBeNear(0, 0.01) -- stays where the last good sample was
			rig:run(0.15)
			local _, still = rig.api.lastValid(p)
			expect(still).toBe(false) -- fewer than 3 clean samples
			rig:run(0.5)
			local cf2, back = rig.api.lastValid(p)
			expect(back).toBe(true)
			expect(cf2.p.x).toBeNear(200, 0.01)
			expect(#rig:strikesOf(p)).toBe(1) -- no storm
		end
	)

	it("at log: still exactly one strike recorded, and lastValid follows (trust kept)", function()
		local rig, p = tele(nil)
		rig:runUntil(8, function()
			return #rig:strikesOf(p) > 0
		end)
		local cf, trusted = rig.api.lastValid(p)
		expect(trusted).toBe(true)
		expect(cf.p.x).toBeNear(200, 0.01)
		rig:run(2)
		expect(#rig:strikesOf(p)).toBe(1)
		expect(rig:strikesOf(p)[1].response).toBe("log")
	end)
end)

describe("case 9: a cheat during an open anchor is not free", function()
	it(
		"a server teleport is pending and the client moves 40 studs elsewhere: a strike against the pre-move base",
		function()
			local rig = Rig.new({ seed = 1 })
			local p = rig:player(1, { path = FakeWorld.paths.stand(V(0, 3, 0)) })
			rig:run(3)
			-- the client cheats (+40 z) 0.05 s after the server's move; the move reaches it 0.15 s later
			rig.fw:setPath(
				p,
				FakeWorld.paths.teleportAt(FakeWorld.paths.stand(V(0, 3, 0)), rig.fw.now + 0.05, V(0, 0, 40))
			)
			rig.fw:serverMove(p, CF.new(V(100, 3, 0)))
			rig:run(2)
			expect(rig:count(p, "teleport") >= 1).toBe(true)
		end
	)
end)

describe("case 39: a respawn used as a teleport is a strike", function()
	local function respawnCheat(baseLatency, cheat, seed)
		local rig = Rig.new({
			seed = seed,
			config = { volumes = { Gate = "checkpoint" } },
			fw = { baseLatency = baseLatency },
		})
		rig:box(V(15, 3, 0), V(0.2, 8, 10), { "Gate" }, { canCollide = false })
		local spawn = V(0, 5, 0)
		local p = rig:player(1, { path = FakeWorld.paths.stand(spawn), baseLatency = baseLatency })
		rig:run(2)
		rig.fw:kill(p)
		rig:run(0.5)
		rig.fw:removeCharacter(p)
		rig.fw:spawnCharacter(p, spawn, { path = cheat })
		rig:run(8)
		return rig, p
	end
	local function struck(rig, p)
		return rig:count(p, "teleport") >= 1
	end

	for _, latency in { 0.15, 0.01 } do
		local tag = if latency > 0.1 then "300 ms" else "20 ms"
		it(`teleport 60 studs as the new character arrives, stand still, at {tag}: strikes`, function()
			for seed = 1, 4 do
				local rig, p = respawnCheat(latency, FakeWorld.paths.stand(V(60, 5, 0)), seed)
				expect(struck(rig, p)).toBe(true)
			end
		end)

		it(`keep wandering (never settles), at {tag}: strikes at the latest at maxSettleSeconds`, function()
			local wander = function(s)
				return V(40 + 8 * math.sin(s * 3), 5, 8 * math.cos(s * 3))
			end
			local rig, p = respawnCheat(latency, wander, 1)
			expect(struck(rig, p)).toBe(true)
		end)

		it(`30 studs past a checkpoint, at {tag}: strikes (no free crossing)`, function()
			local rig, p = respawnCheat(latency, FakeWorld.paths.stand(V(30, 5, 0)), 2)
			expect(struck(rig, p)).toBe(true)
		end)

		it(`200 studs straight down, at {tag}: strikes`, function()
			local rig, p = respawnCheat(latency, FakeWorld.paths.stand(V(0, -195, 0)), 3)
			expect(struck(rig, p)).toBe(true)
		end)
	end

	it(
		"the respawn envelope strikes with details.respawn when the cheat replicates before the first sample",
		function()
			local hits = 0
			for seed = 1, 6 do
				local rig, p = respawnCheat(0.01, FakeWorld.paths.stand(V(60, 5, 0)), seed)
				for _, s in rig:strikesOf(p) do
					if s.details.respawn then
						hits += 1
					end
				end
			end
			expect(hits >= 1).toBe(true)
		end
	)
end)

describe(
	"case 40: teleport straight down through a floor is a teleport strike with details.descent",
	function()
		for _, drop in { 60, 80, 200 } do
			it(`{drop} studs from standing`, function()
				local rig = Rig.new({ seed = 1 })
				local path = FakeWorld.paths.teleportAt(FakeWorld.paths.stand(V(0, 3, 0)), 4, V(0, -drop, 0))
				local p = rig:player(1, { path = path })
				rig:run(5.5)
				local n = 0
				for _, s in rig:strikesOf(p) do
					if s.reason == "teleport" and s.details.descent then
						n += 1
					end
				end
				expect(n).toBe(1)
			end)
		end
	end
)

describe("case 41: the trust rule", function()
	local function trusted(rig, p)
		local _, t = rig.api.lastValid(p)
		return t
	end

	it("at responses.volumeSweep = strike, a hazard records a strike and lastValid stays trusted", function()
		local rig = Rig.new({
			seed = 1,
			config = { volumes = { Lava = "hazard" }, responses = { volumeSweep = "strike" } },
		})
		rig:box(V(20, 3, 0), V(2, 8, 8), { "Lava" }, { canCollide = false })
		local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 16) })
		rig:run(2.5)
		expect(rig:count(p, "volumeSweep")).toBe(1)
		expect(trusted(rig, p)).toBe(true)
	end)

	it(
		"a noEntry crossing at strike makes the player untrusted (and trust returns after 3 clean samples)",
		function()
			local rig =
				Rig.new({ seed = 1, config = { volumes = { Wall = "noEntry" }, response = "strike" } })
			rig:box(V(20, 3, 0), V(2, 8, 8), { "Wall" }, { canCollide = false })
			local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 16) })
			rig:runUntil(4, function()
				return rig:count(p, "volumeSweep") > 0
			end)
			expect(trusted(rig, p)).toBe(false)
			rig:run(1)
			expect(trusted(rig, p)).toBe(true)
		end
	)

	it("a log teleport or speed strike never makes the player untrusted", function()
		local rig = Rig.new({ seed = 1 }) -- every response log
		local path = FakeWorld.paths.teleportAt(FakeWorld.paths.line(V(0, 3, 0), V(24, 0, 0)), 3, V(0, 0, 60))
		local p = rig:player(1, { path = path })
		local untrustedSeen = false
		rig:run(12, function()
			if rig.api.lastValid(p) and not trusted(rig, p) then
				untrustedSeen = true
			end
		end)
		expect(rig:count(p, "teleport") >= 1).toBe(true)
		expect(rig:count(p, "speed") >= 1).toBe(true)
		expect(untrustedSeen).toBe(false)
	end)

	it("every integrity check at strike revokes trust (teleport, speed)", function()
		local rig = Rig.new({ seed = 1, config = { response = "strike" } })
		local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 24) })
		local sawUntrusted = false
		rig:run(10, function()
			local cf, t = rig.api.lastValid(p)
			if cf ~= nil and not t then
				sawUntrusted = true
			end
		end)
		expect(rig:count(p, "speed") >= 1).toBe(true)
		expect(sawUntrusted).toBe(true)
	end)
end)

describe(
	"case 42: hovering STILL in the air over a gap is caught (the cheap path does not skip the arc)",
	function()
		it("walk out over a 40-stud gap, stop, hover: noGround", function()
			for seed = 1, 4 do
				local rig = Rig.new({ seed = seed, ground = false })
				rig:box(V(-1024, -2, 0), V(2048, 4, 2048))
				rig:box(V(1064, -2, 0), V(2048, 4, 2048))
				local path = function(s)
					return V(math.min(-10 + 16 * s, 10), 3, 0)
				end
				local p = rig:player(1, { path = path, jitter = rtt300, ping = 0.3 })
				local at = rig:runUntil(8, function()
					return rig:count(p, "noGround") > 0
				end)
				expect(at ~= nil).toBe(true)
			end
		end)
	end
)
