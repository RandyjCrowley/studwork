--!nocheck
--[[
	CarryVariant: the carry kit's bench variants (docs/framework/kits/carry.md "Budget"; registered in
	replication.luau). Owner: sims builder (D).

	Variants (one bench tick = ONE SECOND of game time, run as 30 steps of fw:advance(1/30) + h:tick(1/30)):
	  KITS-ALL+carry        the budget target (<= 1.128 ms/tick): the KITS-ALL modules + Carry + Movement. 50 fake players on
	                        scripted paths (one in five jumping), 12 couches x 4 carriers carried continuously, one scripted
	                        10-stud teleport cheat past a hazard every 50 s, 8 tagged volumes.
	  KITS-ALL+carry-FLOOR  the same modules booted, NO characters and NO carries (the floor).
	  KITS-ALL-STEP         KITS-ALL with the same 30-step ticking and no carry: the control for the stepping itself.
	  MOVEMENT-50           50 players at 10 Hz with Carry off, no objects (diagnosis).
	  CARRY-20x4            the literal 20 couches x 4 carriers = 80 players, Movement off; CARRY-80-BASE is the same 80 players
	                        without Carry, so the marginal cost is the difference.

	WHY 30 STEPS and not one h:tick(1): the shared ticker caps catch-up at 10 calls per h:tick, and Carry skips a motion call
	when no game time passed since the last, so one h:tick(1) would run Movement 10 of its 60 calls and Carry's motion 10 of
	its 30. 1/30 s steps run every handler at its real cadence (Movement 60 stagger calls/s, Carry logic 10 Hz, motion 30 Hz).

	WHAT IS MEASURED: Luau only. The bench World is FakeWorld with `cast` and `blockcast` replaced by constant-time stubs that
	count calls (FakeWorld's analytic casts are test scaffolding, not the engine's cost). fw:advance and the first rootOf read of each
	player per step (the scripted client path and latency model) are timed separately (`scaffold`). The engine's price per Raycast / Blockcast / CFrame write is NOT in the number: it needs the
	Studio probe (carry.md "Engine facts" item 2), so the report gives counts per tick and the break-even price.

	Asserts (untimed verification pass, before the timed ticks): Movement samples per bench tick ~ 500, Carry object updates
	~ 120, every object carried, nothing dropped, no per-tick replicate (carry:<id> / movement keys unchanged between ticks).
]]

local Harness = require("../testkit/harness")
local process = require("@lune/process")

local CarryVariant = {}

local STEPS = 30 -- per bench tick
local DT = 1 / STEPS
local V = vector.create
-- name -> { mode, control }. A control runs the same world, players and per-step reads with the modules NOT booted: what
-- the scaffold itself costs (GC included), so `variant - control` is the modules' own Luau cost.
local MODES = {
	["KITS-ALL+carry"] = { "all", false },
	["KITS-ALL+carry-FLOOR"] = { "floor", false },
	["KITS-ALL+carry-CTL"] = { "all", true },
	["KITS-ALL-STEP"] = { "step", false },
	["MOVEMENT-50"] = { "movement", false },
	["MOVEMENT-50-CTL"] = { "movement", true },
	["CARRY-20x4"] = { "carry80", false },
	["CARRY-80-CTL"] = { "carry80", true },
}
CarryVariant.names = {
	"KITS-ALL-STEP",
	"KITS-ALL+carry-FLOOR",
	"KITS-ALL+carry-CTL",
	"KITS-ALL+carry",
	"MOVEMENT-50-CTL",
	"MOVEMENT-50",
	"CARRY-80-CTL",
	"CARRY-20x4",
}
CarryVariant.modes = MODES

-- what the last timed run of each variant counted (printed by CarryVariant.report)
local stats: { [string]: any } = {}
local profile: { [string]: any }? = nil -- CARRY_PROFILE=1: per-World-function time of the fake

local function lib()
	return Harness.require("packages/kits/carry/tests/FakeWorld.luau"),
		Harness.require("packages/kits/carry/tests/Scenarios.luau")
end

-- plan -------------------------------------------------------------------------------------------------------------------

function CarryVariant.plan(name: string)
	local def = assert(MODES[name], "CarryVariant: unknown variant " .. name)
	local mode, control = def[1], def[2]
	local plan: any = { name = name, mode = mode, control = control }
	local FakeWorld, S = lib()
	local Carry, Movement = S.Carry, S.Movement
	local useCarry = (mode == "all" or mode == "floor" or mode == "carry80") and not control
	local useMovement = (mode == "all" or mode == "floor" or mode == "movement") and not control
	local workload = mode == "all" or mode == "movement" or mode == "carry80"
	local groups = if mode == "all" then 12 elseif mode == "carry80" then 20 else 0
	local nPlayers = if mode == "carry80" then 80 else 50

	-- CARRY_BENCH_KNOBS="everySamples=3,skipStuds=8,sampleHz=5,staggerBuckets=1,motionHz=20": the documented cadence knobs (carry.md "Budget"),
	-- applied on top of the shipped defaults for an optimisation pass. Unset = the shipped defaults.
	local knobs: { [string]: number } = {}
	for pair in string.gmatch(process.env.CARRY_BENCH_KNOBS or "", "[^,]+") do
		local k, v = string.match(pair, "^(%w+)=([%d%.]+)$")
		assert(k, "CARRY_BENCH_KNOBS: expected name=number, got " .. pair)
		knobs[k] = tonumber(v)
	end
	plan.knobs = knobs

	-- module list and config the harness boots with
	function plan.extend(modules: { any }, config: any)
		if useMovement then
			table.insert(modules, Movement)
			config.Movement = {
				volumes = { BenchHazard = "hazard", BenchCheck = "checkpoint", BenchNoEntry = "noEntry" },
				sampleHz = knobs.sampleHz,
				staggerBuckets = knobs.staggerBuckets,
				wallSweep = if knobs.everySamples then { everySamples = knobs.everySamples } else nil,
				groundCast = if knobs.skipStuds then { skipStuds = knobs.skipStuds } else nil,
			}
		end
		if useCarry then
			table.insert(modules, Carry)
			config.Carry = {
				carriables = {
					BenchCouch = {
						massClass = "heavy",
						carriers = { min = 4, max = 4 },
						gripPoints = { { -3, 0, 0 }, { 3, 0, 0 }, { -3, 0, 2 }, { 3, 0, 2 } },
					},
				},
				maxObjects = 20,
				motionHz = knobs.motionHz,
			}
		end
	end

	local fw, h, apiPlayers
	local counters = { casts = 0, blockcasts = 0 }
	local scaffold = 0 -- seconds spent in fw:advance during timed steps
	local timedSteps = 0
	local verify = { samples = 0, carryReads = 0, writes = 0, casts = 0, blockcasts = 0, ticks = 0 }

	-- the bench world: FakeWorld, with constant-time counting casts
	local stepNo = 0
	local rootCache: { [any]: any } = {}
	local function benchWorld(world: any, groundInstance: any)
		local w = table.clone(world)
		-- rootOf: FakeWorld evaluates the player's scripted path and latency model on read (~2 us), which is test
		-- scaffolding with no engine analogue (the engine reads a property). It is evaluated at most once per player
		-- per step, timed into `scaffold`, and every further read in that step is a table lookup.
		local fakeRoot = world.rootOf
		w.rootOf = function(player)
			local e = rootCache[player]
			if e == nil then
				e = { step = -1 }
				rootCache[player] = e
			end
			if e.step ~= stepNo then
				local t0 = os.clock()
				e.pos, e.cf = fakeRoot(player)
				e.step = stepNo
				scaffold += os.clock() - t0
			end
			return e.pos, e.cf
		end
		local hit = { instance = groundInstance, position = V(0, 0, 0), normal = V(0, 1, 0), distance = 0 }
		w.cast = function(_origin, _dir, _opts)
			counters.casts += 1
			return nil -- no walls in the bench world
		end
		w.blockcast = function(cf, _size, _dir, _opts)
			counters.blockcasts += 1
			-- the ground: a flat floor at y = 0 below the root (distance = the fall to it, less the block's height)
			hit.distance = math.max(0, cf.p.y - 1)
			return hit
		end
		return w
	end

	-- one bench tick of game time
	function plan.step()
		if fw == nil then
			for _ = 1, STEPS do
				h:tick(DT)
			end
			return
		end
		for _ = 1, STEPS do
			local t0 = os.clock()
			fw:advance(DT)
			stepNo += 1
			scaffold += os.clock() - t0
			if control then
				-- what the modules would read: every player's root at 10 Hz (Movement), carriers' again (Carry)
				local read = plan.bench.rootOf
				for i, p in apiPlayers do
					if
						(stepNo + i) % 3 == 0
						or (groups > 0 and i <= groups * 4 and (stepNo + i + 1) % 3 == 0)
					then
						read(p)
					end
				end
			end
			h:tick(DT)
		end
		timedSteps += 1
	end

	-- characters, objects, volumes ----------------------------------------------------------------------------------------
	local function setup(players: { any })
		fw = FakeWorld.new({ seed = 7 })
		fw:addGround(0, 32768)
		local groundInstance = fw.world.blockcast(
			Harness.require("packages/kits/carry/Carry/shared/CF.luau").new(V(0, 3, 0)),
			V(2, 1, 2),
			V(0, -12, 0),
			{}
		).instance
		local bench = benchWorld(fw.world, groundInstance)

		-- the volumes: 4 hazards, 2 checkpoints, 2 noEntry, all in lanes nobody walks except the scripted cheater's
		local function volume(tag: string, x: number, z: number)
			fw:addPart({ position = V(x, 3, z), size = V(1, 8, 8), tags = { tag }, canCollide = false })
		end
		volume("BenchHazard", 805, -30) -- the cheater's, 10 studs across it
		volume("BenchHazard", 905, -100)
		volume("BenchHazard", 1005, -110)
		volume("BenchHazard", 1105, -120)
		volume("BenchCheck", 905, -130)
		volume("BenchCheck", 1005, -140)
		volume("BenchNoEntry", 1105, -150)
		volume("BenchNoEntry", 1205, -160)

		local objects = {}
		if useCarry then
			for g = 1, groups do
				table.insert(
					objects,
					fw:addPart({
						name = "BenchCouch",
						position = V(0, 1, g * 14 - 2.5),
						size = V(8, 2, 2),
						tags = { "BenchCouch" },
					})
				)
			end
		end

		if mode == "floor" then
			-- booted, no characters: nobody is registered with the world
			plan.bench = bench
			plan.fw = fw
			return bench, objects
		end

		-- players: groups of four around their couch, then the loose ones (cheater, solo jumper)
		local walkSpeed = 6
		local startAt = nil -- the sim time the walk starts (set after the pick-ups)
		local function walker(x, y, z, jump, seed)
			-- stands until `startAt`, then walks +X (jumping every 1.2-2.5 s when asked)
			local jumper = if jump then S.jumper(seed, V(0, y, z), walkSpeed) else nil
			return function(s)
				if startAt == nil or s < startAt then
					return V(x, y, z)
				end
				local u = s - startAt
				if jumper then
					local q = jumper(u)
					return V(x + walkSpeed * u, q.y, z)
				end
				return V(x + walkSpeed * u, y, z)
			end
		end
		local index = 0
		local carriersOf = {}
		for g = 1, groups do
			local gz = g * 14
			local jump = false -- carriers do not jump: a jump tilts a carried couch off (Carry drops it)
			for k = 1, 4 do
				index += 1
				local p = players[index]
				local x = if k % 2 == 1 then -3 else 3
				local z = if k <= 2 then gz else gz + 2
				fw:addPlayer(p, { path = walker(x, 3, z, jump, g), jitter = S.jitter.rtt300, ping = 0.1 })
				carriersOf[g] = carriersOf[g] or {}
				table.insert(carriersOf[g], p)
			end
		end
		-- the loose players: #cheater stands at x = 800, #jumper walks alone
		local cheater = players[nPlayers - 1]
		local jumper = players[nPlayers]
		if mode ~= "carry80" and cheater and jumper then
			-- a 10-stud teleport across the hazard every 50 s, back and forth, starting at 20 s
			fw:addPlayer(cheater, {
				path = function(s)
					local k = if s < 20 then 0 else math.floor((s - 20) / 50) + 1
					return V(800 + 10 * (k % 2), 3, -30)
				end,
				ping = 0.1,
			})
			fw:addPlayer(jumper, { path = walker(0, 3, -60, true, 99), jitter = S.jitter.rtt300, ping = 0.1 })
			index += 2
		end
		-- the rest (movement mode has no groups: everybody walks alone, one in five jumping)
		if mode == "movement" then
			index = 0
			for i = 1, nPlayers - 2 do
				local p = players[i]
				fw:addPlayer(p, {
					path = walker(0, 3, 14 * i, i % 5 == 0, i),
					jitter = S.jitter.rtt300,
					ping = 0.1,
				})
			end
		end
		-- the walk starts once the carriers hold their objects
		plan.setStart = function(t)
			startAt = t
		end
		plan.carriersOf = carriersOf
		plan.objects = objects
		plan.bench = bench
		plan.fw = fw
		plan.cheater = cheater
		return bench, objects
	end

	-- start: called once the harness and its players exist ------------------------------------------------------------------
	function plan.start(harness: any, players: { any })
		h = harness
		apiPlayers = players
		if not workload and mode ~= "floor" then
			return -- KITS-ALL-STEP: no World at all
		end
		local bench, objects = setup(players)
		local carryApi = if useCarry then h:use(Carry) else nil
		local mvApi = if useMovement then h:use(Movement) else nil
		local drops, picks = 0, 0
		if carryApi then
			carryApi.signals.Dropped:Connect(function()
				drops += 1
			end)
			carryApi.signals.PickedUp:Connect(function()
				picks += 1
			end)
		end
		local function install(wm: any, wc: any)
			if mvApi then
				mvApi.useWorld(wm)
			end
			if carryApi then
				carryApi.useWorld(wc)
			end
		end
		-- one table per module, installed once (a useWorld swap releases every carry); the counting wrappers of the
		-- verification pass are swapped into these tables in place and removed again
		local bm, bc = table.clone(bench), table.clone(bench)
		if process.env.CARRY_PROFILE then
			-- per-World-function self time of the fake (a profile run only: the clock calls inflate every call)
			local prof = {}
			profile = prof
			for _, tbl in { bm, bc } do
				for k, f in tbl do
					if type(f) == "function" and k ~= "clock" then
						tbl[k] = function(...)
							local t0 = os.clock()
							local r = table.pack(f(...))
							local e = prof[k] or { n = 0, t = 0 }
							e.n += 1
							e.t += os.clock() - t0
							prof[k] = e
							return table.unpack(r, 1, r.n)
						end
					end
				end
			end
		end
		install(bm, bc)
		if mode == "floor" then
			for _ = 1, 3 * STEPS do
				plan.step()
			end
			return
		end

		-- settle: everyone stands, Movement takes its first samples, then the carries start
		local function advance(seconds: number)
			for _ = 1, math.floor(seconds * STEPS) do
				fw:advance(DT)
				stepNo += 1
				h:tick(DT)
			end
		end
		advance(3)
		if carryApi then
			for g, list in plan.carriersOf do
				for _, p in list do
					local ok, why = carryApi.pickUp(p, objects[g])
					assert(ok, `CarryVariant: pickUp refused ({tostring(why)}) in group {g}`)
				end
			end
		end
		plan.setStart(fw.now + 0.5)
		advance(5)

		-- verification pass (untimed): counting worlds for the two modules, 3 bench ticks
		local counts = { movementReads = 0, carryReads = 0, setCFrame = 0 }
		local plainMoveRoot, plainCarryRoot, plainSet = bm.rootOf, bc.rootOf, bc.setCFrame
		bm.rootOf = function(p)
			counts.movementReads += 1
			return plainMoveRoot(p)
		end
		bc.rootOf = function(p)
			counts.carryReads += 1
			return plainCarryRoot(p)
		end
		bc.setCFrame = function(inst, cf)
			counts.setCFrame += 1
			return plainSet(inst, cf)
		end
		counters.casts, counters.blockcasts = 0, 0
		fw:resetCounters()
		local snapshots, keyCount = {}, 0
		-- every player's carry:<id> / movement extra keys as one string, and how many keys there are
		local function snap(): (string, number)
			local parts, n = {}, 0
			for _, p in apiPlayers do
				local state = h:state(p)
				for _, m in { "Carry", "Movement" } do
					local ex = state and state.modules and state.modules[m] and state.modules[m].extra
					for k, v in ex or {} do
						if type(k) == "string" and (string.sub(k, 1, 6) == "carry:" or k == "movement") then
							table.insert(parts, m .. "/" .. k .. "=" .. tostring(v))
							n += 1
						end
					end
				end
			end
			table.sort(parts)
			return table.concat(parts, "|"), n
		end
		local VERIFY_TICKS = 3
		for i = 1, VERIFY_TICKS do
			for _ = 1, STEPS do
				fw:advance(DT)
				stepNo += 1
				h:tick(DT)
			end
			snapshots[i], keyCount = snap()
		end
		verify.samples = counts.movementReads / VERIFY_TICKS
		verify.carryReads = counts.carryReads / VERIFY_TICKS
		verify.writes = counts.setCFrame / VERIFY_TICKS
		verify.casts = counters.casts / VERIFY_TICKS
		verify.blockcasts = counters.blockcasts / VERIFY_TICKS
		verify.cframeWrites = fw.cframeWrites / VERIFY_TICKS
		verify.replicateStable = snapshots[2] == snapshots[3]
		verify.drops, verify.picks = drops, picks
		verify.keys = keyCount

		if carryApi then
			local expectedObjects = groups
			assert(
				picks == expectedObjects * 4,
				`CarryVariant: {picks} pick-ups, expected {expectedObjects * 4}`
			)
			assert(
				drops == 0,
				`CarryVariant: {drops} objects dropped in the warm-up (the carries must be continuous)`
			)
			for g = 1, groups do
				assert(
					carryApi.stateOf(objects[g]) == "carried",
					`CarryVariant: object {g} is {carryApi.stateOf(objects[g])}`
				)
			end
			-- Carry's object updates: one rootOf per carrier per logic tick (10 Hz): groups x 4 x 10
			-- (with Movement absent Carry reads each carrier's raw root twice per logic tick: its own pose and the
			-- accepted one, which is the same read then)
			local updates = verify.carryReads / (4 * (if mvApi then 1 else 2))
			verify.carryUpdates = updates
			assert(
				updates >= groups * 10 * 0.8 and updates <= groups * 10 * 1.3,
				`CarryVariant: Carry updates per tick {updates}, expected about {groups * 10}`
			)
			assert(
				verify.writes >= groups * (knobs.motionHz or 30) * 0.8,
				`CarryVariant: only {verify.writes} motion writes per tick`
			)
		end
		if mvApi then
			local expectedSamples = (if mode == "all" or mode == "movement" then 50 else 0)
				* (knobs.sampleHz or 10)
			assert(
				verify.samples >= expectedSamples * 0.85 and verify.samples <= expectedSamples * 1.15,
				`CarryVariant: Movement samples per tick {verify.samples}, expected about {expectedSamples}`
			)
		end
		if mode == "all" and not control then
			assert(
				verify.keys > 0,
				"CarryVariant: no carry:<id> key was ever replicated (the replicate check would pass vacuously)"
			)
			assert(
				verify.replicateStable,
				"CarryVariant: carry:/movement keys changed between steady ticks (per-tick replicate)"
			)
		end

		bm.rootOf, bc.rootOf, bc.setCFrame = plainMoveRoot, plainCarryRoot, plainSet
		advance(3)
		counters.casts, counters.blockcasts = 0, 0
		fw:resetCounters()
		scaffold, timedSteps = 0, 0
		plan.counters = counters
		plan.verify = verify
	end

	-- called after the timed ticks of a run: collect what the run counted
	function plan.finish()
		if fw == nil then
			return
		end
		local s = stats[name] or {}
		s.verify = verify
		s.castsPerTick = counters.casts / math.max(1, timedSteps)
		s.blockcastsPerTick = counters.blockcasts / math.max(1, timedSteps)
		s.writesPerTick = fw.cframeWrites / math.max(1, timedSteps)
		s.scaffoldMs = scaffold / math.max(1, timedSteps) * 1000
		s.strikes = 0
		if mode == "all" and not control and plan.cheater then
			s.cheaterStrikes = #h:use(Movement).strikes(plan.cheater)
		end
		stats[name] = s
	end
	return plan
end

-- registration: called from replication.luau with its tables. env: variants, tickFns, order (the lists to extend),
-- bootKits (the KITS-ALL boot with a carry plan hook), apis() (the booted KITS apis), runtimes, diff.
local plans: { [string]: any } = {}
function CarryVariant.register(env: any)
	for _, name in CarryVariant.names do
		table.insert(env.order, name)
		env.variants[name] = function(players)
			local plan = CarryVariant.plan(name)
			plans[name] = plan
			local first = players[1]
			if plan.mode == "carry80" then
				local sync
				sync = CarryVariant.standalone(players, env.diff, plan)
				env.tickFns[name] = function(p, _tick)
					if p == first then
						plan.step()
					end
				end
				return sync
			end
			local sync = env.bootKits(players, true, plan)
			env.tickFns[name] = function(p, _tick)
				-- the KITS-ALL per-player work (one Leaderboards submit), then the stepped tick once
				env.apis().Leaderboards.submit(env.runtimes[p].player, "dailyTouches", 1)
				if p == first then
					plan.step()
				end
			end
			return sync
		end
	end
end

-- standalone boot for CARRY-20x4 / CARRY-80-BASE: only the framework modules the carry kit needs, 80 players.
-- Returns the sync function the bench expects (first PLAYERS players are synced and diffed) and the plan.
function CarryVariant.standalone(players: { any }, diff: any, plan: any)
	Harness.mapGame(nil)
	local ReplicatedStorage = Harness.game:GetService("ReplicatedStorage")
	local StudWork = Harness.require(ReplicatedStorage.Framework)
	local modules, config = {}, {}
	plan.extend(modules, config)
	local h = StudWork.test.harness({ modules = modules, config = config })
	local all = {}
	for i = 1, 80 do
		all[i] = h:addPlayer({ userId = i })
	end
	for i = 1, #players do
		h:fire(all[i], "StateInit")
	end
	plan.start(h, all)
	h:tick(1)
	local last = {}
	return function(i, _p)
		local new = h.fake.synced[all[i]]
		local d = diff(last[i], new)
		last[i] = new
		return d, new
	end
end

function CarryVariant.stats()
	return stats
end

-- prints the carry variants' extra numbers (call after the table)
function CarryVariant.report()
	if profile then
		for k, e in profile do
			print(string.format("PROF %-18s calls %8d  total %8.2f ms", k, e.n, e.t * 1000))
		end
	end
	for _, plan in plans do
		plan.finish()
	end
	local any = false
	for _, name in CarryVariant.names do
		if stats[name] and stats[name].castsPerTick then
			any = true
		end
	end
	if not any then
		return
	end
	print("")
	print(
		"carry variants: engine calls per bench tick (counted, NOT priced: no Studio price in this tool), and the fake world's own scripting cost"
	)
	print("")
	print(
		"| variant | Raycast / tick | Blockcast / tick | CFrame writes / tick | Movement samples / tick | Carry updates / tick | scaffold ms / tick (fw:advance + path reads, in the number above) |"
	)
	print("|---|---:|---:|---:|---:|---:|---:|")
	for _, name in CarryVariant.names do
		local s = stats[name]
		if s and s.castsPerTick then
			local v = s.verify or {}
			print(
				string.format(
					"| %s | %.0f | %.0f | %.0f | %.0f | %.0f | %.3f |",
					name,
					s.castsPerTick,
					s.blockcastsPerTick,
					s.writesPerTick,
					v.samples or 0,
					v.carryUpdates or 0,
					s.scaffoldMs
				)
			)
		end
	end
	local _ = process
end

return CarryVariant
