--!nocheck
--[[
	FakeWorld self-check: the latency model (in order, freezes), the analytic casts, counters, tags,
	server moves (stale samples first), spawns, simple physics and the kill plane. The kit's other specs
	trust this file's behaviour.
]]
local FakeWorld = require("packages/kits/carry/tests/FakeWorld.luau")

local V = vector.create
local P1 = { name = "p1" }
local P2 = { name = "p2" }

local function line(speed)
	return FakeWorld.paths.line(V(0, 3, 0), V(speed, 0, 0))
end

describe("FakeWorld latency model", function()
	it("shows the client path one baseLatency late, in order", function()
		local fw = FakeWorld.new({ seed = 3 })
		fw:addPlayer(P1, { path = line(16) })
		fw:run(nil, 3)
		local p, cf = fw.world.rootOf(P1)
		expect(cf ~= nil).toBe(true)
		-- no jitter: lag is base 0.15 + 0..0.05 + the 1/60 send step
		local truth = fw:truePosition(P1)
		local lag = (truth.x - p.x) / 16
		expect(lag >= 0.14).toBe(true)
		expect(lag <= 0.22).toBe(true)
		-- facing: walking +X, so -Z (forward) points along +X
		expect(vector.dot(vector.normalize(V(1, 0, 0)), V(-cf.r[3], -cf.r[6], -cf.r[9])) > 0.99).toBe(true)
	end)

	it("never goes back in time and holds the view during a freeze, then catches up", function()
		local fw = FakeWorld.new({ seed = 5 })
		fw:addPlayer(P1, { path = line(16), jitter = FakeWorld.jitter.rtt300 })
		local last = -math.huge
		local longestHold = 0
		local heldSince = nil
		for _ = 1, 60 * 30 do
			fw:advance(1 / 60)
			local s = fw:viewTime(P1)
			expect(s >= last).toBe(true)
			if s == last then
				heldSince = heldSince or fw.now
				longestHold = math.max(longestHold, fw.now - heldSince)
			else
				heldSince = nil
			end
			last = s
		end
		expect(longestHold >= 0.1).toBe(true) -- the model froze at least once in 30 s
		-- an explicit freeze of 0.4 s holds the view, then it jumps forward
		local before = fw:viewTime(P1)
		fw:freeze(P1, 0.4)
		fw:advance(0.3)
		expect(fw:viewTime(P1) - before <= 0.2 + 1e-9).toBe(true)
		fw:advance(0.6)
		expect(fw:viewTime(P1) - before >= 0.7).toBe(true)
	end)

	it("is deterministic for a seed", function()
		local function run()
			local fw = FakeWorld.new({ seed = 9 })
			fw:addPlayer(P1, { path = line(16), jitter = FakeWorld.jitter.rtt300 })
			fw:run(nil, 20)
			return fw:viewTime(P1)
		end
		expect(run()).toBe(run())
	end)

	it("a hitch frame advances the world clock at once and the harness ticks once", function()
		local fw = FakeWorld.new()
		fw:addPlayer(P1, { path = line(16) })
		local ticks = {}
		local h = {
			tick = function(_, dt)
				table.insert(ticks, dt)
			end,
		}
		fw:hitch(h, 0.45)
		expect(fw.now).toBe(0.45)
		expect(ticks).toEqual({ 0.45 })
		fw:run(h, 1)
		expect(#ticks).toBe(61)
	end)
end)

describe("FakeWorld server moves, spawns, humanoid", function()
	it(
		"fires onServerMove at once; the client adopts the move one latency later (stale samples first)",
		function()
			local fw = FakeWorld.new()
			fw:addPlayer(P1, { path = FakeWorld.paths.stand(V(0, 3, 0)) })
			local seen = {}
			fw.world.onServerMove(P1, function(cf)
				table.insert(seen, cf.p)
			end)
			fw:advance(1)
			fw.world.setRootCFrame(P1, require("packages/kits/carry/Carry/shared/CF.luau").new(V(50, 3, 0)))
			expect(#seen).toBe(1)
			expect(fw.cframeWrites).toBe(1)
			fw:advance(0.1)
			expect(fw.world.rootOf(P1).x).toBe(0) -- stale: the client has not got the move yet
			fw:advance(0.5)
			expect(fw.world.rootOf(P1).x).toBe(50)
		end
	)

	it("spawns a new character at the server placement, then the client's path arrives", function()
		local fw = FakeWorld.new()
		fw:addPlayer(P1, { path = FakeWorld.paths.stand(V(0, 3, 0)) })
		local events, atAdded = {}, nil
		fw.world.onCharacter(P1, function(event)
			table.insert(events, event)
			if event == "added" then
				atAdded = fw.world.rootOf(P1)
			end
		end)
		fw:advance(1)
		fw:kill(P1)
		expect(fw.world.humanoidFacts(P1).alive).toBe(false)
		fw:respawn(P1, V(10, 3, 10), { path = FakeWorld.paths.stand(V(70, 3, 10)) })
		expect(events).toEqual({ "died", "removing", "added" })
		expect(atAdded).toEqual(V(10, 3, 10))
		fw:advance(0.1)
		expect(fw.world.rootOf(P1)).toEqual(V(10, 3, 10)) -- nothing has arrived from the new character yet
		fw:advance(0.5)
		expect(fw.world.rootOf(P1)).toEqual(V(70, 3, 10)) -- the respawn-as-a-teleport cheat shows up
		fw:removeCharacter(P1)
		expect(fw.world.rootOf(P1)).toBeNil()
		expect(fw.world.humanoidFacts(P1)).toBeNil()
	end)

	it("reports humanoid facts, ping, seats with and without a weld, kicks", function()
		local fw = FakeWorld.new({ ping = 0.2 })
		fw:addPlayer(P1, { walkSpeed = 24, jumpVelocity = 55 })
		fw:addPlayer(P2, { ping = 0.05 })
		local f = fw.world.humanoidFacts(P1)
		expect(f.walkSpeed).toBe(24)
		expect(f.jumpVelocity).toBe(55)
		fw.world.setWalkSpeed(P1, 12)
		expect(fw.world.humanoidFacts(P1).walkSpeed).toBe(12)
		expect(fw.world.ping(P1)).toBe(0.2)
		expect(fw.world.ping(P2)).toBe(0.05)
		local seat =
			fw:addPart({ name = "Seat", position = V(0, 3, 0), size = V(2, 1, 2), className = "Seat" })
		fw:seat(P1, seat, { weld = false })
		expect(fw.world.seatOf(P1)).toBeNil()
		fw:seat(P1, seat)
		expect(fw.world.seatOf(P1)).toBe(seat)
		fw.world.kick(P1, "bye")
		expect(fw.kicked[P1]).toBe("bye")
		expect(#fw.world.players()).toBe(2)
	end)
end)

describe("FakeWorld parts, casts, tags, physics", function()
	it("casts hit the nearest collidable box, with normal and distance, and count calls", function()
		local RC = { respectCanCollide = true }
		local fw = FakeWorld.new({ ground = 0 })
		local wall = fw:addPart({ name = "Wall", position = V(10, 5, 0), size = V(1, 10, 20) })
		local ghost =
			fw:addPart({ name = "Ghost", position = V(5, 5, 0), size = V(1, 10, 20), canCollide = false })
		local hit = fw.world.cast(V(0, 5, 0), V(20, 0, 0), RC)
		expect(hit.instance).toBe(wall)
		expect(hit.distance).toBe(9.5)
		expect(hit.normal).toEqual(V(-1, 0, 0))
		expect(fw.world.cast(V(0, 5, 0), V(5, 0, 0), RC)).toBeNil() -- too short
		expect(fw.world.cast(V(0, 5, 0), V(20, 0, 0), { exclude = { wall }, respectCanCollide = true })).toBeNil()
		local down = fw.world.cast(V(3, 6, 3), V(0, -12, 0), RC)
		expect(down.position).toEqual(V(3, 0, 3))
		expect(down.normal).toEqual(V(0, 1, 0))
		expect(fw.casts).toBe(4)
		-- the ghost is not hit, so a block cast sideways stops at the wall's grown face
		local block = fw.world.blockcast(
			require("packages/kits/carry/Carry/shared/CF.luau").new(V(0, 5, 0)),
			V(2, 2, 2),
			V(20, 0, 0),
			RC
		)
		expect(block.instance).toBe(wall)
		expect(block.distance).toBe(8.5)
		expect(fw.blockcasts).toBe(1)
		fw:resetCounters()
		expect(fw.casts + fw.blockcasts + fw.cframeWrites).toBe(0)
		expect(ghost.canCollide).toBe(false)
		-- the engine's default (RespectCanCollide off): a non-colliding but queryable part IS hit; canQuery off never is
		expect(fw.world.cast(V(0, 5, 0), V(20, 0, 0), {}).instance).toBe(ghost)
		fw.world.setQuery(ghost, false)
		expect(ghost.canQuery).toBe(false)
		expect(fw.world.cast(V(0, 5, 0), V(20, 0, 0), {}).instance).toBe(wall)
		fw.world.setQuery(wall, false)
		expect(fw.world.cast(V(0, 5, 0), V(20, 0, 0), {})).toBeNil()
		fw.world.setQuery(wall, true)
		-- ignoredBy: a box that a collision group does not collide with
		local door = fw:addPart({
			name = "Door",
			position = V(3, 5, 0),
			size = V(1, 10, 20),
			ignoredBy = { Characters = true },
		})
		expect(fw.world.cast(V(0, 5, 0), V(20, 0, 0), { collisionGroup = "Characters" }).instance).toBe(wall)
		expect(fw.world.cast(V(0, 5, 0), V(20, 0, 0), {}).instance).toBe(door)
		-- collision-group pairs: a part in a group that doesn't collide with the cast's group is skipped
		local gate = fw:addPart({
			name = "Gate",
			position = V(2, 5, 0),
			size = V(1, 10, 20),
			collisionGroup = "Doors",
		})
		expect(fw.world.cast(V(0, 5, 0), V(20, 0, 0), { collisionGroup = "Players" }).instance).toBe(gate)
		fw:setCollidable("Doors", "Players", false)
		expect(fw:collidable("Players", "Doors")).toBe(false)
		expect(fw.world.cast(V(0, 5, 0), V(20, 0, 0), { collisionGroup = "Players" }).instance).toBe(door)
		expect(fw.world.cast(V(0, 5, 0), V(20, 0, 0), {}).instance).toBe(gate) -- no group in the opts: not filtered
	end)

	it("tags fire added/removed, tagged lists, destroy untags, setCFrame counts", function()
		local fw = FakeWorld.new()
		local added, removed = {}, {}
		local offAdd = fw.world.onTagAdded("Zone", function(p)
			table.insert(added, p)
		end)
		fw.world.onTagRemoved("Zone", function(p)
			table.insert(removed, p)
		end)
		local a = fw:addPart({ name = "A", tags = { "Zone" } })
		local b = fw:addPart({ name = "B" })
		fw:tag(b, "Zone")
		expect(#fw.world.tagged("Zone")).toBe(2)
		offAdd()
		fw:tag(fw:addPart({ name = "C" }), "Zone")
		expect(added).toEqual({ a, b })
		fw:untag(a, "Zone")
		fw:destroy(b)
		expect(#removed).toBe(2)
		expect(#fw.world.tagged("Zone")).toBe(1)
		local cf = require("packages/kits/carry/Carry/shared/CF.luau").new(V(1, 2, 3))
		fw.world.setCFrame(a, cf)
		expect(fw.cframeWrites).toBe(1)
		local c, size = fw.world.boundsOf(a)
		expect(c).toBe(cf)
		expect(size).toEqual(V(4, 4, 4))
		fw.world.setAttribute(a, "CarryObjectId", "7")
		expect(a:GetAttribute("CarryObjectId")).toBe("7")
	end)

	it("moves a tagged platform on `motion`, and reports a conveyor's surface velocity", function()
		local fw = FakeWorld.new()
		local CFm = require("packages/kits/carry/Carry/shared/CF.luau")
		local plat = fw:addPart({
			name = "Plat",
			tags = { "MovingPlatform" },
			motion = function(t)
				return CFm.new(V(30 * t, 0, 0))
			end,
		})
		local belt = fw:addPart({ name = "Belt", surfaceVelocity = V(5, 0, 0) })
		fw:advance(2)
		expect(plat.cf.p.x).toBe(60)
		expect(fw.world.surfaceVelocityOf(belt)).toEqual(V(5, 0, 0))
		expect(fw.cframeWrites).toBe(0) -- scripted motion is not a module write
	end)

	it(
		"an unanchored part falls, lands and rests on a floor; with CanCollide off it falls through; below killY the engine destroys it",
		function()
			local fw = FakeWorld.new({ ground = 0, killY = -100 })
			local box =
				fw:addPart({ name = "Box", position = V(0, 10, 0), size = V(2, 2, 2), anchored = false })
			fw:advance(2)
			expect(box.cf.p.y).toBe(1)
			expect(fw.world.velocityOf(box)).toEqual(V(0, 0, 0))
			local ghost = fw:addPart({
				name = "Ghost",
				position = V(5, 10, 0),
				size = V(2, 2, 2),
				anchored = false,
				canCollide = false,
			})
			fw:advance(2)
			expect(ghost.cf.p.y < -50).toBe(true)
			fw:advance(1)
			expect(fw.destroyed[1]).toBe(ghost)
			expect(#fw.world.tagged("x")).toBe(0)
			-- a thrown part keeps its horizontal velocity until it lands
			local ball =
				fw:addPart({ name = "Ball", position = V(0, 5, 0), size = V(1, 1, 1), anchored = false })
			fw.world.setVelocity(ball, V(10, 0, 0))
			fw:advance(0.1)
			expect(ball.cf.p.x > 0.9).toBe(true)
			fw.world.anchor(ball)
			local y = ball.cf.p.y
			fw:advance(1)
			expect(ball.cf.p.y).toBe(y)
		end
	)
end)
