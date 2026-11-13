--!nocheck
--[[
	Reruns the designfix-2 confirming probes against the REAL Movement part (not the standalone pure-Luau
	parts/validator.luau model): the three core cases the orchestrator asks for, plus a seeded sweep of the
	N1/N2/N4 fixes, on packages/kits/carry/tests/FakeWorld.luau.
]]
local Rig = require("packages/kits/carry/tests/MovementRig.luau")
local V, FakeWorld = Rig.V, Rig.FakeWorld
local rtt300 = FakeWorld.jitter.rtt300

describe("designfix-2 probes rerun against the real Movement part", function()
	it("(a) 300ms RTT + jitter + hitches, walking, 60 seeds x 60 s: 0 strikes", function()
		local strikes = 0
		for seed = 1, 60 do
			local rig = Rig.new({ seed = seed })
			local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 16), jitter = rtt300, ping = 0.3 })
			local r = Rig.lcg(seed + 500)
			local nextHitch = 10 + r() * 10
			local t = 0
			while t < 60 do
				if rig.fw.now >= nextHitch then
					rig:hitch(0.45)
					t += 0.45
					nextHitch = rig.fw.now + 15 + r() * 10
				else
					rig:run(1 / 60)
					t += 1 / 60
				end
			end
			strikes += #rig:strikesOf(p)
		end
		print(`(a) 60 seeds x 60 s walking: {strikes} strikes`)
		expect(strikes).toBe(0)
	end)

	it(
		"(b) 10-stud teleport past a 0.5-stud hazard: caught by the volume sweep 50/50, teleport cap alone 0/50",
		function()
			local caughtBySweep, caughtByCap = 0, 0
			for seed = 1, 50 do
				local rig = Rig.new({ seed = seed, config = { volumes = { Hazard = "hazard" } } })
				rig:box(V(0, 3, 0), V(0.5, 8, 30), { "Hazard" }, { canCollide = false })
				local path = FakeWorld.paths.teleportAt(FakeWorld.paths.stand(V(-5, 3, 0)), 4, V(10, 0, 0))
				local p = rig:player(1, { path = path })
				rig:run(8)
				if rig:count(p, "volumeSweep") > 0 then
					caughtBySweep += 1
				end
				if rig:count(p, "teleport") > 0 then
					caughtByCap += 1
				end
			end
			print(`(b) volume sweep caught {caughtBySweep}/50, teleport cap alone caught {caughtByCap}/50`)
			expect(caughtBySweep).toBe(50)
			expect(caughtByCap).toBe(0)
		end
	)

	it("(c) sustained 1.5x speed hack, ping 0.3 and 1.0: caught by the speed window 50/50 each", function()
		for _, ping in { 0.3, 1.0 } do
			local caught = 0
			local worst = 0
			for seed = 1, 50 do
				local rig = Rig.new({ seed = seed })
				local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 24), jitter = rtt300, ping = ping })
				local at = rig:runUntil(10, function()
					return rig:count(p, "speed") > 0
				end)
				if at ~= nil then
					caught += 1
					worst = math.max(worst, at)
				end
			end
			print(`(c) 1.5x hack at ping {ping}: caught {caught}/50, worst {worst} s`)
			expect(caught).toBe(50)
		end
	end)

	it(
		"N1 stop-and-go walker, ping 0.05 and 0.30, 60 seeds x 60 s each: 0 strikes (the window lag floor)",
		function()
			for _, ping in { 0.05, 0.3 } do
				local strikes = 0
				for seed = 1, 60 do
					local rig = Rig.new({ seed = seed })
					local p = rig:player(
						1,
						{ path = Rig.stopAndGo(seed, V(0, 3, 0), 16, 60), jitter = rtt300, ping = ping }
					)
					rig:run(60)
					strikes += #rig:strikesOf(p)
				end
				print(`N1 stop-and-go walker, ping {ping}, 60 seeds x 60 s: {strikes} strikes`)
				expect(strikes).toBe(0)
			end
		end
	)

	it(
		"N4 the descent bound: 60, 80, 200-stud straight-down teleports caught 50/50 each; a 500-stud fall arc is not",
		function()
			for _, drop in { 60, 80, 200 } do
				local caught = 0
				for seed = 1, 50 do
					local rig = Rig.new({ seed = seed })
					local path =
						FakeWorld.paths.teleportAt(FakeWorld.paths.stand(V(0, 3, 0)), 4, V(0, -drop, 0))
					local p = rig:player(1, { path = path })
					rig:run(5.5)
					local hit = false
					for _, s in rig:strikesOf(p) do
						if s.reason == "teleport" and s.details.descent then
							hit = true
						end
					end
					if hit then
						caught += 1
					end
				end
				print(`N4 {drop}-stud straight-down teleport: caught {caught}/50`)
				expect(caught).toBe(50)
			end
			local strikes = 0
			for seed = 1, 50 do
				local rig = Rig.new({ seed = seed, ground = false })
				rig:box(V(-1024, -2, 0), V(2048, 4, 2048))
				rig:box(V(1024 + 10, -502, 0), V(2048, 4, 2048))
				local p = rig:player(
					1,
					{ path = Rig.ledge(V(-20, 3, 0), 16, 0, 500), jitter = rtt300, ping = 0.05 }
				)
				rig:run(10)
				strikes += #rig:strikesOf(p)
			end
			print(`N4 control: a legit 500-stud fall arc: {strikes} strikes`)
			expect(strikes).toBe(0)
		end
	)

	it("N2 respawn-used-as-teleport: struck 50/50 at 300ms and 20ms; a legit respawn is 0/50", function()
		for _, latency in { 0.15, 0.01 } do
			local struck = 0
			for seed = 1, 50 do
				local rig = Rig.new({ seed = seed, fw = { baseLatency = latency } })
				local spawn = V(0, 5, 0)
				local p = rig:player(1, { path = FakeWorld.paths.stand(spawn), baseLatency = latency })
				rig:run(2)
				rig.fw:kill(p)
				rig:run(0.5)
				rig.fw:removeCharacter(p)
				rig.fw:spawnCharacter(p, spawn, { path = FakeWorld.paths.stand(V(60, 5, 0)) })
				rig:run(8)
				if rig:count(p, "teleport") >= 1 then
					struck += 1
				end
			end
			print(`N2 respawn-teleport cheat at baseLatency {latency}: struck {struck}/50`)
			expect(struck).toBe(50)
		end
		local strikes, arrivals = 0, 0
		for seed = 1, 50 do
			local rig = Rig.new({ seed = seed })
			local spawn = V(0, 5, 0)
			local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 16), jitter = rtt300, ping = 0.3 })
			rig:run(5)
			rig.fw:kill(p)
			rig:run(5)
			rig.fw:removeCharacter(p)
			rig.fw:spawnCharacter(p, spawn, { path = Rig.spawnWalk(spawn, 3, 16, rig.fw.now) })
			local arrived = rig:runUntil(3, function()
				return select(2, rig.api.lastValid(p)) == true
			end)
			if arrived ~= nil then
				arrivals += 1
			end
			rig:run(5)
			strikes += #rig:strikesOf(p)
		end
		print(`N2 legit respawn: {strikes} strikes, {arrivals}/50 arrivals`)
		expect(strikes).toBe(0)
		expect(arrivals).toBe(50)
	end)

	it(
		"N3 the trust rule: a log teleport never revokes trust; a strike response does; a hazard at strike doesn't",
		function()
			do
				local rig = Rig.new({ seed = 1 })
				local path = FakeWorld.paths.teleportAt(FakeWorld.paths.stand(V(0, 3, 0)), 4, V(25, 0, 0))
				local p = rig:player(1, { path = path })
				rig:run(6)
				local _, trusted = rig.api.lastValid(p)
				expect(rig:count(p, "teleport")).toBe(1)
				expect(trusted).toBe(true)
			end
			do
				local rig = Rig.new({ seed = 1, config = { response = "strike" } })
				local path = FakeWorld.paths.teleportAt(FakeWorld.paths.stand(V(0, 3, 0)), 4, V(25, 0, 0))
				local p = rig:player(1, { path = path })
				rig:run(4.5)
				local _, trusted = rig.api.lastValid(p)
				expect(trusted).toBe(false)
				rig:run(1)
				local _, back = rig.api.lastValid(p)
				expect(back).toBe(true)
			end
			do
				local rig = Rig.new({
					seed = 1,
					config = { volumes = { Lava = "hazard" }, responses = { volumeSweep = "strike" } },
				})
				rig:box(V(20, 3, 0), V(2, 8, 8), { "Lava" }, { canCollide = false })
				local p = rig:player(1, { path = Rig.walk(V(0, 3, 0), 16) })
				rig:run(2.5)
				expect(rig:count(p, "volumeSweep")).toBe(1)
				local _, trusted = rig.api.lastValid(p)
				expect(trusted).toBe(true)
			end
		end
	)

	it(
		"N5 agreeStuds: raw root vs accepted stays within 2 + max(16, WalkSpeed) x 0.7 at 300ms+jitter+hitches",
		function()
			for _, walk in { 16, 32 } do
				local limit = 2 + math.max(16, walk) * 0.7
				local worst = 0
				local rig = Rig.new({ seed = 2 })
				local p = rig:player(
					1,
					{ path = Rig.walk(V(0, 3, 0), walk), jitter = rtt300, ping = 0.3, walkSpeed = walk }
				)
				local nextHitch = 12
				for _ = 1, 60 * 60 do
					if rig.fw.now >= nextHitch then
						rig:hitch(0.45)
						nextHitch = rig.fw.now + 15
					else
						rig:run(1 / 60)
					end
					local cf, trusted = rig.api.lastValid(p)
					local raw = rig.fw.world.rootOf(p)
					if cf ~= nil and trusted and raw ~= nil then
						worst = math.max(worst, vector.magnitude(raw - cf.p))
					end
				end
				print(`N5 WalkSpeed {walk}: max gap {worst} <= {limit}`)
				expect(worst <= limit).toBe(true)
				expect(#rig:strikesOf(p)).toBe(0)
			end
		end
	)
end)
