--!nocheck
--[[
	Carry's anti-cheat and client-trust cases (planted cases 21-24, 33, 44): a teleporting carrier never
	moves the object faster than the clamp and never delivers; trust follows Movement's frozen rule; the
	agreement check scales with WalkSpeed. FakeWorld with the probe's latency model; Movement is the
	stand-in in CarryFakeMovement.luau (Movement's own sims are builder C's).
]]
local CarryKit = require("packages/kits/carry/tests/CarryKit.luau")
local FakeWorld = require("packages/kits/carry/tests/FakeWorld.luau")
local CF = require("packages/kits/carry/Carry/shared/CF.luau")

local V = CarryKit.V
local CLAMP_SPEED = 21.6 * 1.02 -- WalkSpeed 16 x 1.35, plus a hair for float32

local function dropReasons(k)
	local out = {}
	for _, e in k:events("Dropped") do
		table.insert(out, e.args[2])
	end
	return out
end

describe("case 21: teleport into the delivery zone", function()
	local function scenario(o)
		local k = CarryKit.new({
			movement = o.movement,
			paths = { FakeWorld.paths.teleportAt(FakeWorld.paths.stand(V(0, 3, 0)), 2, V(100, 0, 0)) },
		})
		k:zone(V(100, 5, 0), V(20, 10, 20))
		local crate = k:crate()
		k:run(0.3)
		expect(k.carry.pickUp(k.p[1], crate)).toBe(true)
		local top = k:topSpeed(crate, 0.1)
		k:run(6, function(t)
			if o.untrust and t > 1.9 then
				k.mv.trusted[k.p[1]] = false
			end
		end)
		expect(#k:events("Delivered")).toBe(0)
		expect(crate.cf.p.x < 15).toBe(true) -- the object stayed near where it was
		expect(k.carry.stateOf(crate) ~= "delivered").toBe(true)
		local _ = top
		return k
	end

	it("Movement off: no Delivered", function()
		local k = scenario({})
		expect(dropReasons(k)[1]).toBe("teleport")
	end)

	it("Movement on at log (the carrier stays trusted): no Delivered", function()
		scenario({ movement = true })
	end)

	it(
		'Movement on at responses.teleport = "strike" (the carrier is also untrusted): no Delivered',
		function()
			local k = scenario({ movement = true, untrust = true })
			expect(dropReasons(k)[1]).toBe("teleport")
		end
	)
end)

describe("case 22: teleport-pick-up-teleport-back", function()
	-- the carrier stands 50 studs away, hops next to the crate for [2, 3.5) and back
	local function hop(s)
		if s >= 2 and s < 3.5 then
			return V(0, 3, 0)
		end
		return V(50, 3, 0)
	end

	it('Movement at responses.teleport = "strike": refused (untrusted/disagree/tooFar)', function()
		local k = CarryKit.new({ movement = true, paths = { hop } })
		local crate = k:crate()
		k:run(2.05, function(t)
			if t > 1.95 then
				k.mv.trusted[k.p[1]] = false -- the strike that the teleport earns
			end
		end)
		k:run(0.6)
		local ok, why = k.carry.pickUp(k.p[1], crate)
		expect(ok).toBe(false)
		expect(why == "untrusted" or why == "disagree" or why == "tooFar").toBe(true)
		expect(k.carry.stateOf(crate)).toBe("idle")
	end)

	for _, movement in { false, true } do
		it(
			`Movement {if movement then "on at log" else "off"}: the next tick releases the slot, one clamp step at most`,
			function()
				local k = CarryKit.new({ movement = movement, paths = { hop } })
				local crate = k:crate()
				k:run(2.7)
				local ok = k.carry.pickUp(k.p[1], crate)
				expect(ok).toBe(true)
				local start = crate.cf.p
				local top = k:topSpeed(crate, 3)
				expect(top <= CLAMP_SPEED).toBe(true)
				expect(dropReasons(k)).toEqual({ "teleport" })
				expect(vector.magnitude(crate.cf.p - start) < 8).toBe(true) -- never taken across the map
				expect(k.carry.isCarrying(k.p[1])).toBe(nil)
			end
		)
	end
end)

describe("case 23: a sole carrier teleports 200 studs", function()
	for _, movement in { false, true } do
		it(
			`Movement {if movement then "on" else "off"}: the slot is released and the object never exceeds the clamp`,
			function()
				local k = CarryKit.new({
					movement = movement,
					paths = { FakeWorld.paths.teleportAt(FakeWorld.paths.stand(V(0, 3, 0)), 2, V(200, 0, 0)) },
				})
				local crate = k:crate()
				k:run(0.3)
				expect(k.carry.pickUp(k.p[1], crate)).toBe(true)
				local top = k:topSpeed(crate, 5)
				expect(top <= CLAMP_SPEED).toBe(true)
				expect(dropReasons(k)).toEqual({ "teleport" })
				expect(crate.cf.p.x < 10).toBe(true)
				expect(crate.canCollide).toBe(true)
			end
		)
	end
end)

describe("case 24: legitimate carriers on a 300 ms connection with jitter", function()
	for seed = 1, 3 do
		it(`a sole carrier walks 60 s with zero releases (seed ${seed})`, function()
			local k = CarryKit.new({
				seed = seed,
				movement = seed == 3,
				jitter = FakeWorld.jitter.rtt300,
				ping = 0.3,
				paths = { FakeWorld.paths.line(V(0, 3, 0), V(12, 0, 0)) },
			})
			local crate = k:crate()
			k:run(0.3)
			expect(k.carry.pickUp(k.p[1], crate)).toBe(true)
			k:run(60)
			expect(dropReasons(k)).toEqual({})
			expect(k.carry.stateOf(crate)).toBe("carried")
			expect(crate.cf.p.x > 600).toBe(true) -- it really came along
		end)
	end

	it("two carriers walk 60 s with no stretch drop", function()
		local k = CarryKit.new({
			players = 2,
			jitter = FakeWorld.jitter.rtt300,
			ping = 0.3,
			paths = {
				FakeWorld.paths.line(V(-3, 3, 0), V(0, 0, -10)),
				FakeWorld.paths.line(V(3, 3, 0), V(0, 0, -10)),
			},
		})
		local couch = k:couch()
		k:run(0.3)
		expect(k.carry.pickUp(k.p[1], couch)).toBe(true)
		expect(k.carry.pickUp(k.p[2], couch)).toBe(true)
		expect(k.carry.stateOf(couch)).toBe("carried")
		k:run(60)
		expect(dropReasons(k)).toEqual({})
		expect(#k.carry.holders(couch)).toBe(2)
	end)
end)

describe("case 33: disqualification and trust (Carry with Movement)", function()
	local function carrying(config)
		local k = CarryKit.new({ movement = true, players = 1, config = config })
		local crate = k:crate()
		k:run(0.3)
		expect(k.carry.pickUp(k.p[1], crate)).toBe(true)
		return k, crate
	end

	it("runDisqualified mode: RunDisqualified drops the object (disqualified)", function()
		local k, crate = carrying()
		k.mv.fire("RunDisqualified", k.p[1], "run1", "speed")
		expect(k.carry.stateOf(crate)).toBe("dropped")
		expect(dropReasons(k)).toEqual({ "disqualified" })
	end)

	it(
		"strike mode: a teleport failure at response log drops nothing, neither the subscription nor untrustedCarrier",
		function()
			local k, crate = carrying({ dropRules = { carrierDisqualified = "strike" } })
			k.mv.fire("Strike", k.p[1], "teleport", { response = "log" })
			k:run(1)
			expect(k.carry.stateOf(crate)).toBe("carried") -- a log strike never revokes trust either
			expect(dropReasons(k)).toEqual({})
		end
	)

	it('strike mode: the same failure at response "strike" drops it (disqualified)', function()
		local k, crate = carrying({ dropRules = { carrierDisqualified = "strike" } })
		k.mv.fire("Strike", k.p[1], "teleport", { response = "strike" })
		expect(k.carry.stateOf(crate)).toBe("dropped")
		expect(dropReasons(k)).toEqual({ "disqualified" })
	end)

	it(
		"runDisqualified mode: a hazard crossing at volumeSweep = strike does not drop (trust kept); a noEntry crossing does (teleport)",
		function()
			local k, crate = carrying()
			k.mv.fire("Strike", k.p[1], "volumeSweep", { response = "strike", kind = "hazard" })
			k:run(1)
			expect(k.carry.stateOf(crate)).toBe("carried")
			-- the noEntry crossing: Movement's lastValid now reports untrusted
			k.mv.trusted[k.p[1]] = false
			k:run(0.3)
			expect(k.carry.stateOf(crate)).toBe("dropped")
			local events = k:events("Dropped")
			expect(events[1].args[2]).toBe("teleport")
			expect(events[1].args[3]).toBe(k.p[1])
		end
	)

	it("off mode ignores both signals", function()
		local k, crate = carrying({ dropRules = { carrierDisqualified = "off" } })
		k.mv.fire("RunDisqualified", k.p[1], "run1", "speed")
		k.mv.fire("Strike", k.p[1], "teleport", { response = "strike" })
		expect(k.carry.stateOf(crate)).toBe("carried")
	end)

	it("untrustedCarrier = false keeps carrying an untrusted carrier", function()
		local k, crate = carrying({ dropRules = { untrustedCarrier = false } })
		k.mv.trusted[k.p[1]] = false
		k:run(1)
		expect(k.carry.stateOf(crate)).toBe("carried")
	end)

	it("a carrier with no Movement sample yet cannot pick up (untrusted)", function()
		local k = CarryKit.new({ movement = true })
		local crate = k:crate()
		local ok, why = k.carry.pickUp(k.p[1], crate)
		expect(ok).toBe(false)
		expect(why).toBe("untrusted")
	end)

	it("releasePlayer works with Movement absent, and with any reason string", function()
		local k = CarryKit.new({})
		local crate = k:crate()
		k:run(0.3)
		expect(k.carry.pickUp(k.p[1], crate)).toBe(true)
		k.carry.releasePlayer(k.p[1], "disqualified")
		expect(dropReasons(k)).toEqual({ "disqualified" })
		k.carry.releasePlayer(k.p[1], "nothing held") -- a no-op
		expect(#k:events("Dropped")).toBe(1)
	end)
end)

describe("case 44: a game speed boost and Carry's agreement check", function()
	it('WalkSpeed 32 with 300 ms jitter: no "disagree" for pick-up or hand-off', function()
		local k = CarryKit.new({
			movement = true,
			players = 2,
			walkSpeed = 32,
			jitter = FakeWorld.jitter.rtt300,
			ping = 0.3,
			paths = {
				FakeWorld.paths.line(V(0, 3, 0), V(32, 0, 0)),
				FakeWorld.paths.line(V(0, 3, 3), V(32, 0, 0)),
			},
		})
		local crate = k:crate()
		local disagree, tries, oks, maxGap = 0, 0, 0, 0
		k:run(1)
		for _ = 1, 50 do
			k:run(0.5)
			local rawP = k.fw.world.rootOf(k.p[1])
			local cf = k.mv.samples[k.p[1]]
			if cf ~= nil then
				maxGap = math.max(maxGap, vector.magnitude(rawP - cf.p))
			end
			k.carry.reset(crate, CF.new(rawP))
			local ok, why = k.carry.pickUp(k.p[1], crate)
			tries += 1
			if why == "disagree" then
				disagree += 1
			end
			if ok then
				oks += 1
				local ok2, why2 = k.carry.handOff(k.p[1], crate, k.p[2])
				if why2 == "disagree" then
					disagree += 1
				end
				if not ok2 then
					k.carry.drop(k.p[1], crate)
				end
			end
		end
		expect(disagree).toBe(0)
		expect(oks > 10).toBe(true)
		expect(maxGap > 13.2).toBe(true) -- the gaps that would have been refused at the WalkSpeed 16 limit
		expect(maxGap < 24.4).toBe(true)
	end)
end)
