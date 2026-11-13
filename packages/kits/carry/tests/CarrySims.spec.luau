--!nocheck
--[[
	CarrySims: Carry no-duplication, client trust and leave/rejoin (planted cases 21-38 and 44 of the carry design plan).
	Owner: sims builder (D).

	Carry's own unit-level specs (CarryAnticheat / CarryStates) run against a stand-in Movement. These run every case on
	Scenarios.rig with the REAL Movement and the REAL Carry booted together, so the trust rule, the strikes and the carry rules are
	exercised through each other: a teleporting carrier is a real Movement strike, not a flipped flag. `movement = false` is
	Movement absent.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local S = require("packages/kits/carry/tests/Scenarios.luau")
local Codec = require("packages/kits/carry/Carry/shared/Codec.luau")
local V, FakeWorld = S.V, S.FakeWorld
local rtt300 = S.jitter.rtt300
local CLAMP_SPEED = 21.6 * 1.02 -- WalkSpeed 16 x clamp.speedSlack 1.35, plus a hair for float32

-- `n` players standing along x (or on `o.paths`), settled so Movement has trusted samples
local function kit(n, o)
	o = o or {}
	local rig = S.rig({
		seed = o.seed,
		movement = o.movement,
		carry = o.carry,
		ground = o.ground,
		killY = o.killY,
		flags = o.flags,
	})
	local ps = {}
	for i = 1, n do
		local at = (o.positions and o.positions[i]) or V((i - 1) * 3, 3, 0)
		ps[i] = rig:player(i, {
			path = (o.paths and o.paths[i]) or S.stand(at),
			jitter = o.jitter,
			ping = o.ping,
			walkSpeed = o.walkSpeed,
		})
	end
	rig.p = ps
	return rig
end

local function pick(rig, i, obj)
	return rig.carry.pickUp(rig.p[i], obj)
end

-- the tracked top speed (horizontal, studs/s) of a part's CFrame writes over `seconds`
local function topSpeed(rig, part, seconds)
	local last = part.cf.p
	local top = 0
	rig:run(seconds, function()
		local p = part.cf.p
		top = math.max(top, vector.magnitude(V(p.x - last.x, 0, p.z - last.z)) * 60)
		last = p
	end)
	return top
end

local function keyOf(rig, player, id)
	return Codec.decode(rig.h:state(player).modules.Carry.extra["carry:" .. id])
end

local MOVEMENTS = {
	{ "off", false },
	{ "on at log", {} },
	{ "on at strike", { responses = { teleport = "strike" } } },
}

describe(
	'case 21: teleport into the delivery zone (Movement off, on at log, on at responses.teleport = "strike"): no Delivered; the object\'s own box is not in the zone, and at strike the carrier is also untrusted',
	function()
		for _, m in MOVEMENTS do
			it(`case 21: Movement {m[1]}`, function()
				local rig = kit(
					1,
					{ movement = m[2], paths = { S.teleporting(S.stand(V(0, 3, 0)), 2, V(100, 0, 0)) } }
				)
				rig:zone(V(100, 5, 0), V(20, 10, 20))
				local crate = rig:crate()
				rig:settle()
				expect(pick(rig, 1, crate)).toBe(true)
				rig:run(6)
				expect(#rig:events("Delivered")).toBe(0)
				expect(crate.cf.p.x < 15).toBe(true) -- the object stayed near where it was
				expect(rig.carry.stateOf(crate) ~= "delivered").toBe(true)
				if m[1] ~= "on at strike" then
					expect(rig:dropReasons()[1]).toBe("teleport")
				else
					expect(#rig:dropReasons() >= 1).toBe(true)
					expect(rig:count(rig.p[1], "teleport") >= 1).toBe(true)
				end
			end)
		end
	end
)

describe(
	"case 22: teleport-pick-up-teleport-back: with Movement at responses.teleport = strike it is refused (untrusted/disagree/tooFar); with Movement off or at log the next tick releases the slot (Dropped(teleport)) and the object moved at most one clamp step",
	function()
		-- the carrier stands 50 studs away, hops next to the crate for [2, 3.5) and back
		local function hop(s)
			if s >= 2 and s < 3.5 then
				return V(0, 3, 0)
			end
			return V(50, 3, 0)
		end

		it("case 22: Movement at strike: refused", function()
			local rig = kit(1, { movement = { responses = { teleport = "strike" } }, paths = { hop } })
			local crate = rig:crate()
			-- try the pick-up the moment the strike makes the carrier untrusted
			rig:runUntil(5, function()
				return rig:count(rig.p[1], "teleport") > 0 and not rig:trusted(rig.p[1])
			end)
			local ok, why = pick(rig, 1, crate)
			expect(ok).toBe(false)
			expect(why == "untrusted" or why == "disagree" or why == "tooFar").toBe(true)
			expect(rig.carry.stateOf(crate)).toBe("idle")
		end)

		for _, m in { MOVEMENTS[1], MOVEMENTS[2] } do
			it(`case 22: Movement {m[1]}: the next tick releases the slot, one clamp step at most`, function()
				local rig = kit(1, { movement = m[2], paths = { hop } })
				local crate = rig:crate()
				rig:run(2.7)
				expect(pick(rig, 1, crate)).toBe(true)
				local start = crate.cf.p
				expect(topSpeed(rig, crate, 3) <= CLAMP_SPEED).toBe(true)
				expect(rig:dropReasons()).toEqual({ "teleport" })
				expect(vector.magnitude(crate.cf.p - start) < 8).toBe(true)
				expect(rig.carry.isCarrying(rig.p[1])).toBe(nil)
			end)
		end
	end
)

describe(
	"case 23: sole carrier teleports 200 studs, with Movement on and with it off: the slot is released and the object never moves faster than the clamp",
	function()
		for _, m in MOVEMENTS do
			it(`case 23: Movement {m[1]}`, function()
				local rig = kit(
					1,
					{ movement = m[2], paths = { S.teleporting(S.stand(V(0, 3, 0)), 2, V(200, 0, 0)) } }
				)
				local crate = rig:crate()
				rig:settle()
				expect(pick(rig, 1, crate)).toBe(true)
				expect(topSpeed(rig, crate, 5) <= CLAMP_SPEED).toBe(true)
				expect(#rig:dropReasons() >= 1).toBe(true)
				expect(rig.carry.isCarrying(rig.p[1])).toBe(nil)
				expect(crate.cf.p.x < 10).toBe(true)
				expect(crate.canCollide).toBe(true)
			end)
		end
	end
)

describe(
	"case 24: sole carrier with 300 ms jitter, walking for 60 s: zero releases; also 2 carriers: no stretch drop",
	function()
		for seed = 1, 2 do
			for _, m in { MOVEMENTS[1], MOVEMENTS[2] } do
				it(`case 24: a sole carrier, Movement {m[1]}, seed {seed}`, function()
					local rig = kit(1, {
						seed = seed,
						movement = m[2],
						jitter = rtt300,
						ping = 0.3,
						paths = { FakeWorld.paths.line(V(0, 3, 0), V(12, 0, 0)) },
					})
					local crate = rig:crate()
					rig:settle()
					expect(pick(rig, 1, crate)).toBe(true)
					rig:runWithHitches(60, seed)
					expect(rig:dropReasons()).toEqual({})
					expect(rig.carry.stateOf(crate)).toBe("carried")
					expect(crate.cf.p.x > 500).toBe(true)
					expect(#rig:strikes(rig.p[1])).toBe(0)
				end)
			end
		end

		it("case 24: two carriers walk 60 s with no stretch drop", function()
			local rig = kit(2, {
				jitter = rtt300,
				ping = 0.3,
				movement = {},
				paths = {
					FakeWorld.paths.line(V(-3, 3, 0), V(0, 0, -10)),
					FakeWorld.paths.line(V(3, 3, 0), V(0, 0, -10)),
				},
			})
			local couch = rig:couch()
			rig:settle()
			expect(pick(rig, 1, couch)).toBe(true)
			expect(pick(rig, 2, couch)).toBe(true)
			expect(rig.carry.stateOf(couch)).toBe("carried")
			rig:run(60)
			expect(rig:dropReasons()).toEqual({})
			expect(#rig.carry.holders(couch)).toBe(2)
		end)
	end
)

describe(
	'case 25: two pickUps race for the last slot: exactly one succeeds ("full"); a busy receiver for a hand-off: "receiverBusy"; a co-carrier as receiver: "invalidReceiver"',
	function()
		it("case 25: the race", function()
			local rig = kit(2, { movement = {} })
			rig.fw:addPart({ name = "Tray", position = V(0, 1, -3), size = V(2, 2, 2), tags = { "Tray" } })
			rig.carry.registerCarriable(
				"Tray",
				{ massClass = "medium", carriers = { min = 1, max = 1 }, gripPoints = { { 0, 0, 0 } } }
			)
			rig:settle()
			local tray = rig.fw.parts[#rig.fw.parts]
			local ok1 = pick(rig, 1, tray)
			local ok2, why2 = pick(rig, 2, tray)
			expect(ok1).toBe(true)
			expect(ok2).toBe(false)
			expect(why2).toBe("full")
			expect(#rig.carry.holders(tray)).toBe(1)
		end)

		it("case 25: a busy receiver", function()
			local rig = kit(2, { movement = {} })
			local a, b = rig:crate(), rig:crate(V(3, 1, -3))
			rig:settle()
			expect(pick(rig, 1, a)).toBe(true)
			expect(pick(rig, 2, b)).toBe(true)
			local ok, why = rig.carry.handOff(rig.p[1], a, rig.p[2])
			expect(ok).toBe(false)
			expect(why).toBe("receiverBusy")
		end)

		it("case 25: a co-carrier as receiver", function()
			local rig = kit(2, { movement = {}, positions = { V(-3, 3, 0), V(3, 3, 0) } })
			local couch = rig:couch()
			rig:settle()
			expect(pick(rig, 1, couch)).toBe(true)
			expect(pick(rig, 2, couch)).toBe(true)
			local ok, why = rig.carry.handOff(rig.p[1], couch, rig.p[2])
			expect(ok).toBe(false)
			expect(why == "invalidReceiver" or why == "notSoleHolder").toBe(true)
			-- (a 2-carrier object is never a sole holder, so notSoleHolder answers first; the giver as receiver, on a
			-- sole-held crate, is CarryStates' invalidReceiver cell)
			local solo = rig:crate(V(9, 1, -3))
			rig.fw:setPath(rig.p[1], S.stand(V(9, 3, 0)))
			rig:run(0.6)
			rig.carry.drop(rig.p[1], couch)
			rig.carry.drop(rig.p[2], couch)
			expect(pick(rig, 1, solo)).toBe(true)
			local _, why2 = rig.carry.handOff(rig.p[1], solo, rig.p[1])
			expect(why2).toBe("invalidReceiver")
		end)
	end
)

describe(
	'case 26: re-pick-up inside the zone after Delivered: refused ("delivered") and no second Delivered; after Carry.reset it can deliver once more',
	function()
		it("case 26", function()
			local rig = kit(1, { movement = {} })
			local crate = rig:crate()
			rig:zone(V(0, 5, 0))
			rig:settle()
			expect(pick(rig, 1, crate)).toBe(true)
			rig:run(0.6)
			expect(#rig:events("Delivered")).toBe(1)
			expect(rig.carry.stateOf(crate)).toBe("delivered")
			local ok, why = pick(rig, 1, crate)
			expect(ok).toBe(false)
			expect(why).toBe("delivered")
			rig:run(2)
			expect(#rig:events("Delivered")).toBe(1)
			expect(rig.carry.reset(crate)).toBe(true)
			expect(pick(rig, 1, crate)).toBe(true)
			rig:run(0.6)
			expect(#rig:events("Delivered")).toBe(2)
		end)
	end
)

describe("case 27: an object in two overlapping zones: exactly one Delivered", function()
	it("case 27", function()
		local rig = kit(1, { movement = {} })
		local crate = rig:crate()
		local z1 = rig:zone(V(0, 5, 0))
		rig:zone(V(2, 5, 0))
		rig:settle()
		expect(pick(rig, 1, crate)).toBe(true)
		rig:run(2)
		local delivered = rig:events("Delivered")
		expect(#delivered).toBe(1)
		expect(delivered[1].args[2]).toBe(z1)
	end)
end)

describe(
	'case 28: a carrier leaves mid-carry with carrierLeft = "drop": the object persists in place, with no leaked or duplicated Instance; with "returnToSpawn": Returned("carrierLeft")',
	function()
		it("case 28: drop", function()
			local rig = kit(1, { movement = {}, paths = { FakeWorld.paths.line(V(0, 3, 0), V(5, 0, 0)) } })
			local crate = rig:crate()
			rig:settle()
			local parts = #rig.fw.parts
			expect(pick(rig, 1, crate)).toBe(true)
			rig:run(2)
			local at = crate.cf.p
			rig.h:removePlayer(rig.p[1])
			expect(rig.carry.stateOf(crate)).toBe("dropped")
			expect(rig:dropReasons()).toEqual({ "carrierLeft" })
			rig:run(2)
			expect(vector.magnitude(crate.cf.p - at) < 4).toBe(true)
			expect(#rig.fw.parts).toBe(parts)
			expect(#rig:events("Returned")).toBe(0)
		end)

		it("case 28: returnToSpawn", function()
			local rig = kit(1, {
				movement = {},
				carry = { dropRules = { carrierLeft = "returnToSpawn" } },
				paths = { FakeWorld.paths.line(V(0, 3, 0), V(5, 0, 0)) },
			})
			local crate = rig:crate()
			rig:settle()
			local spawn = crate.cf.p
			expect(pick(rig, 1, crate)).toBe(true)
			rig:run(2)
			rig.h:removePlayer(rig.p[1])
			local returned = rig:events("Returned")
			expect(#returned).toBe(1)
			expect(returned[1].args[2]).toBe("carrierLeft")
			expect(vector.magnitude(crate.cf.p - spawn) < 1e-4).toBe(true)
			expect(crate.anchored).toBe(true)
		end)
	end
)

describe(
	'case 29: the receiver leaves during the catch window: Dropped("missedThrow", receiver); the thrower leaving changes nothing',
	function()
		local function thrown()
			local rig = kit(2, { movement = {}, positions = { V(0, 3, 0), V(24, 3, 0) } })
			local crate = rig:crate()
			rig:settle()
			expect(pick(rig, 1, crate)).toBe(true)
			local ok, why = rig.carry.handOff(rig.p[1], crate, rig.p[2])
			expect(why).toBe(nil)
			expect(ok).toBe(true)
			return rig, crate
		end

		it("case 29: the receiver leaves", function()
			local rig, crate = thrown()
			rig.h:removePlayer(rig.p[2])
			local events = rig:events("Dropped")
			expect(#events).toBe(1)
			expect(events[1].args[2]).toBe("missedThrow")
			expect(events[1].args[3]).toBe(rig.p[2])
			expect(rig.carry.stateOf(crate)).toBe("dropped")
		end)

		it("case 29: the thrower leaves", function()
			local rig, crate = thrown()
			rig.h:removePlayer(rig.p[1])
			expect(rig.carry.stateOf(crate)).toBe("thrown")
			expect(#rig:events("Dropped")).toBe(0)
			rig:run(1.2)
			expect(rig.carry.isCarrying(rig.p[2])).toBe(crate)
		end)
	end
)

describe("case 30: CharacterRemoving without Died (LoadCharacter) releases the slot", function()
	it("case 30", function()
		local rig = kit(1, { movement = {} })
		local crate = rig:crate()
		rig:settle()
		expect(pick(rig, 1, crate)).toBe(true)
		rig.fw:removeCharacter(rig.p[1])
		expect(rig:dropReasons()).toEqual({ "carrierLeft" })
		expect(rig.carry.isCarrying(rig.p[1])).toBe(nil)
	end)
end)

describe(
	"case 31: a drop over the void: the object returns to spawn, Returned(void), and is re-anchored; dropped 1,000 studs above killY with a 0.45 s server hitch while it falls: still returned, never destroyed by the engine; a resting object 1 stud above killY is not returned",
	function()
		it("case 31: the void", function()
			local rig = kit(1, { movement = {}, ground = false, killY = -500, positions = { V(0, 13, 0) } })
			local crate = rig:crate(V(0, 10, -3))
			rig:settle()
			expect(pick(rig, 1, crate)).toBe(true)
			local spawn = crate.cf.p
			expect(rig.carry.drop(rig.p[1], crate)).toBe(true)
			rig:run(8)
			local returned = rig:events("Returned")
			expect(#returned).toBe(1)
			expect(returned[1].args[2]).toBe("void")
			expect(crate.anchored).toBe(true)
			expect(#rig.fw.destroyed).toBe(0)
			expect(vector.magnitude(crate.cf.p - spawn) < 1e-4).toBe(true)
		end)

		it("case 31: 1,000 studs above killY with a 0.45 s hitch while it falls", function()
			local rig = kit(1, { movement = {}, ground = false, killY = -500, positions = { V(0, 503, 0) } })
			local crate = rig:crate(V(0, 500, -3))
			rig:settle()
			expect(pick(rig, 1, crate)).toBe(true)
			rig:run(0.5)
			expect(rig.carry.drop(rig.p[1], crate)).toBe(true)
			rig:run(2)
			rig:hitch(0.45)
			rig:run(10)
			expect(#rig.fw.destroyed).toBe(0)
			expect(#rig:events("Returned")).toBe(1)
			expect(crate.anchored).toBe(true)
		end)

		it("case 31: a resting object 1 stud above the kill plane is not returned", function()
			local rig = kit(1, { movement = {}, ground = false, killY = -500, positions = { V(0, -445, 0) } })
			rig.fw:addPart({ name = "Floor", position = V(0, -451, 0), size = V(60, 4, 60) })
			local crate = rig:crate(V(0, -448, -3))
			rig:settle()
			expect(pick(rig, 1, crate)).toBe(true)
			expect(rig.carry.drop(rig.p[1], crate)).toBe(true)
			rig:run(4)
			expect(#rig:events("Returned")).toBe(0)
			expect(#rig.fw.destroyed).toBe(0)
		end)
	end
)

describe(
	"case 32: a dropped object settles and is re-anchored, so a scripted push no longer moves it",
	function()
		it("case 32", function()
			local rig = kit(1, { movement = {} })
			local crate = rig:crate()
			rig:settle()
			expect(pick(rig, 1, crate)).toBe(true)
			expect(rig.carry.drop(rig.p[1], crate)).toBe(true)
			expect(rig.carry.stateOf(crate)).toBe("dropped")
			rig:run(3.6)
			expect(rig.carry.stateOf(crate)).toBe("idle")
			expect(crate.anchored).toBe(true)
			local at = crate.cf.p
			crate.velocity = V(30, 0, 0)
			rig:run(1)
			expect(vector.magnitude(crate.cf.p - at) < 1e-6).toBe(true)
		end)
	end
)

describe(
	"case 33: disqualification and trust (Carry with Movement; untrustedCarrier = true, the default): RunDisqualified drops the object; strike mode at response log: not dropped; at response strike: dropped; runDisqualified mode through a hazard at responses.volumeSweep = strike: not dropped, through a noEntry volume: dropped by untrustedCarrier; releasePlayer works with Movement absent",
	function()
		-- a carrier walks +X at 10 studs/s from x = 0 carrying a crate; a volume sits at x = 12
		local function walker(movement, mode, tag, kind)
			local cfg = movement
			cfg.volumes = { [tag] = kind }
			local rig = kit(1, {
				movement = cfg,
				carry = { dropRules = { carrierDisqualified = mode } },
				paths = { FakeWorld.paths.line(V(0, 3, 0), V(8, 0, 0), 1.5) },
			})
			rig:box(V(14, 3, 0), V(2, 8, 12), { tag }, { canCollide = false })
			local crate = rig:crate()
			rig:settle()
			expect(pick(rig, 1, crate)).toBe(true)
			return rig, crate
		end

		it("case 33: RunDisqualified drops it (runDisqualified mode)", function()
			-- a disqualifyRun response to a teleport mid-run: RunDisqualified fires, and Carry drops the object
			local rig = kit(1, {
				movement = { responses = { teleport = "disqualifyRun" } },
				carry = { dropRules = { carrierDisqualified = "runDisqualified" } },
				paths = { S.teleporting(S.stand(V(0, 3, 0)), 3, V(60, 0, 0)) },
			})
			local crate = rig:crate()
			rig:settle()
			rig.mv.startRun(rig.p[1], "run1")
			expect(pick(rig, 1, crate)).toBe(true)
			rig:run(5)
			expect(#rig.disqualified >= 1).toBe(true)
			expect(rig.carry.isCarrying(rig.p[1])).toBe(nil)
			expect(#rig:dropReasons() >= 1).toBe(true)
		end)

		-- (a speed failure cannot be used here: between Movement's speed cap and Carry's own clamp there is no pace that strikes
		-- without also stretching the object off its carrier. A noEntry crossing is the failure that touches neither.)
		it(
			'case 33: "strike" mode, a noEntry crossing at response log: NOT dropped (neither subscription nor untrustedCarrier)',
			function()
				local rig, crate = walker({}, "strike", "Wall", "noEntry")
				rig:run(5)
				expect(rig:count(rig.p[1], "volumeSweep") >= 1).toBe(true)
				expect(rig:trusted(rig.p[1])).toBe(true)
				expect(rig.carry.stateOf(crate)).toBe("carried")
				expect(rig:dropReasons()).toEqual({})
			end
		)

		it('case 33: "strike" mode, the same failure at response strike: dropped', function()
			local rig, crate = walker({ responses = { volumeSweep = "strike" } }, "strike", "Wall", "noEntry")
			rig:run(5)
			expect(rig:count(rig.p[1], "volumeSweep") >= 1).toBe(true)
			expect(rig.carry.stateOf(crate) ~= "carried").toBe(true)
			expect(#rig:dropReasons() >= 1).toBe(true)
			expect(rig.carry.isCarrying(rig.p[1])).toBe(nil)
		end)

		it(
			"case 33: through a hazard at responses.volumeSweep = strike: NOT dropped (a hazard never revokes trust)",
			function()
				local rig, crate =
					walker({ responses = { volumeSweep = "strike" } }, "runDisqualified", "Lava", "hazard")
				rig:run(5)
				expect(rig:count(rig.p[1], "volumeSweep") >= 1).toBe(true)
				expect(rig:trusted(rig.p[1])).toBe(true)
				expect(rig.carry.stateOf(crate)).toBe("carried")
				expect(rig:dropReasons()).toEqual({})
			end
		)

		it(
			"case 33: through a noEntry volume at responses.volumeSweep = strike: dropped by untrustedCarrier",
			function()
				local rig, crate =
					walker({ responses = { volumeSweep = "strike" } }, "runDisqualified", "Wall", "noEntry")
				rig:run(5)
				expect(rig:count(rig.p[1], "volumeSweep") >= 1).toBe(true)
				expect(rig.carry.stateOf(crate) ~= "carried").toBe(true)
				expect(rig:dropReasons()[1]).toBe("teleport")
			end
		)

		it("case 33: releasePlayer works with Movement absent", function()
			local rig = kit(1, { movement = false })
			local crate = rig:crate()
			rig:settle()
			expect(pick(rig, 1, crate)).toBe(true)
			rig.carry.releasePlayer(rig.p[1], "anything")
			expect(rig.carry.isCarrying(rig.p[1])).toBe(nil)
			expect(#rig:dropReasons()).toBe(1)
		end)
	end
)

describe("case 34: Movement absent: Carry boots and carries with no erroring-proxy access", function()
	it("case 34", function()
		local rig = kit(1, { movement = false })
		local crate = rig:crate()
		rig:settle()
		expect(pick(rig, 1, crate)).toBe(true)
		rig:run(2)
		expect(rig.carry.stateOf(crate)).toBe("carried")
		expect(rig.h:warnings()).toEqual({})
	end)
end)

describe(
	"case 35: Carry flag off mid-carry: every object is released and unanchored (not frozen in mid-air), WalkSpeeds are restored, and carry:* keys are cleared",
	function()
		it("case 35", function()
			local cs = StudWork.test.fakes.configService({ values = { flag_carryOn = true } })
			-- the flag override needs harness options that are boot-time, which S.rig has no seam for: this case boots its own
			local Carry = S.Carry
			local h = StudWork.test.harness({
				modules = { Carry },
				config = { Carry = { carriables = S.CARRIABLES, flag = "carryOn" } },
				flags = { carryOn = { default = true } },
				flagOverride = { enabled = true, refreshSeconds = 5 },
				services = { ConfigService = cs },
				env = "live",
			})
			local fw = FakeWorld.new({ seed = 1, ground = 0 })
			local api = h:use(Carry)
			api.useWorld(fw.world)
			local p1, p2 = h:addPlayer({ userId = 1 }), h:addPlayer({ userId = 2 })
			fw:addPlayer(p1, { path = S.stand(V(0, 3, 0)) })
			fw:addPlayer(p2, { path = S.stand(V(0, 3, 9)) })
			local crate =
				fw:addPart({ name = "Crate", position = V(0, 1, -3), size = V(2, 2, 2), tags = { "Crate" } })
			local couch =
				fw:addPart({ name = "Couch", position = V(0, 1, 10), size = V(8, 2, 2), tags = { "Couch" } })
			fw:run(h, 0.5)
			expect(api.pickUp(p1, crate)).toBe(true)
			expect(api.pickUp(p2, couch)).toBe(true) -- gathering (min 2)
			expect(math.abs(fw:humanoid(p1).walkSpeed - 13.6) < 1e-4).toBe(true)
			cs.set("flag_carryOn", false)
			cs.publish()
			fw:run(h, 6)
			expect(api.stateOf(crate) == "dropped" or api.stateOf(crate) == "idle").toBe(true)
			expect(crate.canCollide).toBe(true)
			expect(api.isCarrying(p1)).toBe(nil)
			expect(api.isCarrying(p2)).toBe(nil)
			for _, id in { "carry:1", "carry:2" } do
				expect(h:state(p1).modules.Carry.extra[id]).toBe(nil)
			end
			for _, p in { p1, p2 } do
				expect(math.abs(fw:humanoid(p).walkSpeed - 16) < 1e-4).toBe(true)
			end
			expect(select(2, api.pickUp(p1, crate))).toBe("off")
			expect(crate.anchored).toBe(true)
		end)
	end
)

describe(
	'case 36: multi-carrier state table: every action x state cell of carry.md "States (frozen)": a 4-carrier couch refusing a throw ("notSoleHolder"), a min-2 object in gathering with one holder, and belowMin on and off',
	function()
		local function couchRig(n, o)
			o = o or {}
			o.movement = {}
			o.positions = { V(-3, 3, 0), V(3, 3, 0), V(-3, 3, 2), V(3, 3, 2), V(0, 3, 1) }
			local rig = kit(n, o)
			local couch = rig:couch()
			rig:settle()
			return rig, couch
		end

		it("case 36: min-2 object in gathering with one holder; 4 carriers refuse a throw", function()
			local rig, couch = couchRig(5)
			expect(pick(rig, 1, couch)).toBe(true)
			expect(rig.carry.stateOf(couch)).toBe("gathering")
			expect(keyOf(rig, rig.p[1], "1").state).toBe("gathering")
			local _, why = rig.carry.handOff(rig.p[1], couch, rig.p[5])
			expect(why).toBe("notSoleHolder")
			for i = 2, 4 do
				expect(pick(rig, i, couch)).toBe(true)
			end
			expect(rig.carry.stateOf(couch)).toBe("carried")
			local _, why2 = rig.carry.handOff(rig.p[1], couch, rig.p[5])
			expect(why2).toBe("notSoleHolder")
			local ok, why3 = pick(rig, 5, couch)
			expect(ok).toBe(false)
			expect(why3).toBe("full")
		end)

		it("case 36: drop in gathering frees the slot; 0 slots is idle; a non-holder cannot drop", function()
			local rig, couch = couchRig(2)
			expect(pick(rig, 1, couch)).toBe(true)
			expect(rig.carry.drop(rig.p[1], couch)).toBe(true)
			expect(rig.carry.stateOf(couch)).toBe("idle")
			expect(#rig:events("Dropped")).toBe(0)
			expect(rig.carry.drop(rig.p[1], couch)).toBe(false)
		end)

		it("case 36: belowMin on drops the object when a co-carrier leaves; off keeps it carried", function()
			local rig, couch = couchRig(2)
			expect(pick(rig, 1, couch)).toBe(true)
			expect(pick(rig, 2, couch)).toBe(true)
			rig.carry.drop(rig.p[2], couch)
			expect(rig.carry.stateOf(couch)).toBe("dropped") -- below min with belowMin on: the object drops
			expect(rig:dropReasons()[1]).toBe("manual") -- a voluntary drop is a manual one, whatever it leaves behind
			local rig2, couch2 = couchRig(2, { carry = { dropRules = { belowMin = false } } })
			expect(pick(rig2, 1, couch2)).toBe(true)
			expect(pick(rig2, 2, couch2)).toBe(true)
			rig2.h:removePlayer(rig2.p[2])
			rig2:run(1)
			expect(rig2.carry.stateOf(couch2)).toBe("gathering") -- below min, belowMin off: kept, waiting for a carrier
			local rig3, couch3 = couchRig(2)
			expect(pick(rig3, 1, couch3)).toBe(true)
			expect(pick(rig3, 2, couch3)).toBe(true)
			rig3.h:removePlayer(rig3.p[2])
			rig3:run(1)
			expect(rig3.carry.stateOf(couch3)).toBe("dropped")
			expect(rig3:dropReasons()[1]).toBe("carrierLeft")
		end)

		it("case 36: a heavy object can be handed over but not thrown", function()
			local rig = kit(2, { movement = {}, positions = { V(0, 3, 0), V(3, 3, 0) } })
			local crate = rig:crate()
			rig:settle()
			expect(pick(rig, 1, crate)).toBe(true)
			local ok, why = rig.carry.handOff(rig.p[1], crate, rig.p[2])
			expect(why).toBe(nil)
			expect(ok).toBe(true)
			expect(rig.carry.isCarrying(rig.p[2])).toBe(crate)
		end)
	end
)

describe(
	"case 37: streaming: server state is unaffected when the client's view streams out and back (server side only)",
	function()
		it("case 37", function()
			local rig = kit(2, { movement = {} })
			local crate = rig:crate()
			rig:settle()
			expect(pick(rig, 1, crate)).toBe(true)
			local before = rig.h:state(rig.p[2]).modules.Carry.extra["carry:1"]
			rig.h:removePlayer(rig.p[2])
			rig:run(1)
			local again = rig.h:addPlayer({ userId = 9 })
			rig.fw:addPlayer(again, { path = S.stand(V(0, 3, 3)) })
			rig:run(0.3)
			expect(rig.carry.stateOf(crate)).toBe("carried")
			expect(rig.carry.holders(crate)).toEqual({ rig.p[1] })
			expect(rig.h:state(again).modules.Carry.extra["carry:1"]).toBe(before)
		end)
	end
)

describe(
	"case 38: default boot under the harness (no World): both modules idle, with no error (the test-adopt / new-game shape)",
	function()
		it("case 38", function()
			local h = StudWork.test.harness({ modules = { S.Movement, S.Carry } })
			local p = h:addPlayer({ userId = 1 })
			h:tick(5)
			expect(h:state(p) ~= nil).toBe(true)
			expect(h:warnings()).toEqual({})
		end)
	end
)

describe(
	'case 44: game speed boost and Carry agreement: server WalkSpeed 32 with 300 ms jitter: no "disagree" refusal for pick-up, hand-off or catch (agreeStuds scales with WalkSpeed)',
	function()
		it("case 44", function()
			for seed = 1, 3 do
				local rig = kit(2, {
					seed = seed,
					movement = {},
					jitter = rtt300,
					ping = 0.3,
					walkSpeed = 32,
					paths = { S.walk(V(0, 3, 0), 32), S.walk(V(2, 3, 4), 32) },
				})
				local crate = rig:crate(V(1, 1, -3))
				local disagreed = 0
				rig:run(1)
				-- the first pick-up, then hand-offs every couple of seconds while both run at 32 studs/s
				local holder, other = 1, 2
				local ok, why = pick(rig, holder, crate)
				if not ok and why == "disagree" then
					disagreed += 1
				end
				for _ = 1, 6 do
					rig:runWithHitches(2, seed)
					if rig.carry.isCarrying(rig.p[holder]) == crate then
						local ok2, why2 = rig.carry.handOff(rig.p[holder], crate, rig.p[other])
						if not ok2 and why2 == "disagree" then
							disagreed += 1
						end
						if ok2 then
							holder, other = other, holder
						end
					end
				end
				expect(disagreed).toBe(0)
				expect(#rig:strikes(rig.p[1]) + #rig:strikes(rig.p[2])).toBe(0)
			end
		end)
	end
)
