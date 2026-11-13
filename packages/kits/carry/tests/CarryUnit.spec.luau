--!nocheck
--[[
	Carry's pure helpers: Blend (multi-carrier target), Clamp (displacement clamp + the worked numbers),
	Codec (the "carry:<id>" string), Box (OBB tests), Throw (launch velocity), Rules (definitions).
	No World, no harness.
]]
local CF = require("packages/kits/carry/Carry/shared/CF.luau")
local Blend = require("packages/kits/carry/Carry/shared/Blend.luau")
local Clamp = require("packages/kits/carry/Carry/shared/Clamp.luau")
local Codec = require("packages/kits/carry/Carry/shared/Codec.luau")
local Box = require("packages/kits/carry/Carry/shared/Box.luau")
local Throw = require("packages/kits/carry/Carry/server/Throw.luau")
local Rules = require("packages/kits/carry/Carry/server/Rules.luau")

local V = vector.create
local function near(a, b, eps)
	expect(vector.magnitude(a - b) < (eps or 1e-5)).toBe(true)
end

local COUCH = { gripPoints = { { -3, 0, 0 }, { 3, 0, 0 }, { -3, 0, 2 }, { 3, 0, 2 } } }
local function hold(x, y, z, r)
	return CF.new(V(x, y, z), r)
end

describe("Blend.targetCF", function()
	it("1 carrier: the hold pose minus the grip, hold orientation, no tilt or stretch", function()
		local def = { gripPoints = { { 0, 1, 0 } } }
		local cf, tilt, stretch = Blend.targetCF({ { index = 1, hold = hold(4, 5, 6) } }, def)
		near(cf.p, V(4, 4, 6))
		expect(tilt < 1e-3).toBe(true)
		expect(stretch).toBe(0)
	end)

	it("2 carriers: the mean position, the grip axis lined up with the carriers' axis", function()
		-- carriers 6 apart along +x, facing -z; grips -3 / +3 along x: identity orientation, no stretch
		local slots = { { index = 1, hold = hold(-3, 3.5, -2.5) }, { index = 2, hold = hold(3, 3.5, -2.5) } }
		local cf, tilt, stretch = Blend.targetCF(slots, COUCH)
		near(cf.p, V(0, 3.5, -2.5))
		near(CF.rotate(cf, V(1, 0, 0)), V(1, 0, 0))
		expect(tilt < 1e-3).toBe(true)
		expect(stretch < 1e-5).toBe(true)
	end)

	it("2 carriers walking a different direction turn the object and keep it upright", function()
		-- carriers on the z axis (6 apart): the object's x axis must now point along z
		local slots = { { index = 1, hold = hold(0, 3.5, -3) }, { index = 2, hold = hold(0, 3.5, 3) } }
		local cf, tilt = Blend.targetCF(slots, COUCH)
		near(CF.rotate(cf, V(1, 0, 0)), V(0, 0, 1))
		expect(tilt < 1e-3).toBe(true)
	end)

	it("a carrier moving 1 stud off stretches by that fraction; tilt follows a raised end", function()
		local slots = { { index = 1, hold = hold(-3, 3.5, -2.5) }, { index = 2, hold = hold(3, 5.5, -2.5) } }
		local _, tilt, stretch = Blend.targetCF(slots, COUCH)
		expect(tilt > 10).toBe(true) -- a 2-stud rise over 6 studs: about 18 degrees
		expect(tilt < 25).toBe(true)
		expect(stretch > 0.9).toBe(true)
	end)

	it("is deterministic and slot-order folded for 3+ carriers (no float drift between runs)", function()
		local slots = {
			{ index = 1, hold = hold(-3, 3.5, 0.1) },
			{ index = 2, hold = hold(3, 3.5, 0.3) },
			{ index = 3, hold = hold(-3, 3.5, 2.2) },
			{ index = 4, hold = hold(3, 3.5, 2.4) },
		}
		local a = Blend.targetCF(slots, COUCH)
		local b = Blend.targetCF(slots, COUCH)
		expect(a.p == b.p).toBe(true)
		for i = 1, 9 do
			expect(a.r[i]).toBe(b.r[i])
		end
	end)

	it("uses only the OCCUPIED slots' grips (a hole in the slot order)", function()
		local slots = { { index = 2, hold = hold(3, 3.5, 0) }, { index = 4, hold = hold(3, 3.5, 4) } }
		local cf = Blend.targetCF(slots, COUCH)
		-- first/last occupied grips: (3,0,0) -> (3,0,2): object z axis along the carriers' z axis
		near(CF.rotate(cf, V(0, 0, 1)), V(0, 0, 1))
	end)
end)

describe("Clamp (carry.md worked numbers, WalkSpeed 16, speedFactor 1)", function()
	local speed = Clamp.objSpeed({ 16 }, 1.35)
	it("object speed is WalkSpeed x 1.35 = 21.60 studs/s; slowest carrier wins", function()
		expect(math.abs(speed - 21.6) < 1e-9).toBe(true)
		expect(math.abs(Clamp.objSpeed({ 16, 10 }, 1.35) - 13.5) < 1e-9).toBe(true)
	end)

	local function step(from, to, dt)
		return Clamp.step(
			from,
			to,
			{ speed = speed, dt = dt, maxDt = 0.5, riseSpeed = 57.5, fallSpeed = 200 }
		)
	end

	it("max step per logic tick is 2.16 studs at dt 0.1, 10.8 at the dt cap", function()
		local p, limited = step(V(0, 0, 0), V(100, 0, 0), 0.1)
		expect(math.abs(p.x - 2.16) < 1e-5).toBe(true)
		expect(limited).toBe(true)
		local q = step(V(0, 0, 0), V(100, 0, 0), 5)
		expect(math.abs(q.x - 10.8) < 1e-5).toBe(true)
	end)

	it("a target inside the step is reached exactly (not limited)", function()
		local p, limited = step(V(0, 0, 0), V(1, 0.2, 1), 0.1)
		near(p, V(1, 0.2, 1))
		expect(limited).toBe(false)
	end)

	it("a 10-stud hop glides at clamp speed and never jumps", function()
		local pos = V(0, 0, 0)
		local ticks = 0
		repeat
			local nextPos = step(pos, V(10, 0, 0), 0.1)
			expect(nextPos.x - pos.x <= 2.16 + 1e-5).toBe(true)
			pos = nextPos
			ticks += 1
		until pos.x >= 10 - 1e-9 or ticks > 20
		expect(ticks).toBe(5)
	end)

	it("limits vertical motion: rise by jumpVelocity x slack, fall by maxFallSpeed", function()
		local up = step(V(0, 0, 0), V(0, 100, 0), 0.1)
		expect(math.abs(up.y - 5.75) < 1e-5).toBe(true)
		local down = step(V(0, 0, 0), V(0, -100, 0), 0.1)
		expect(math.abs(down.y + 20) < 1e-5).toBe(true)
	end)

	it("a 200-stud teleport: 21.6 studs/s however many ticks it takes", function()
		local pos = V(0, 0, 0)
		for _ = 1, 10 do
			local nextPos = step(pos, V(200, 0, 0), 0.1)
			expect(vector.magnitude(nextPos - pos) / 0.1 <= 21.6 + 1e-3).toBe(true)
			pos = nextPos
		end
		expect(pos.x < 25).toBe(true)
	end)

	it("the teleport cap matches Movement's formula at its defaults (13.88 studs at dt 0.1)", function()
		expect(math.abs(Clamp.teleportCap(16, 0.1, 0.6) - 13.88) < 1e-9).toBe(true)
	end)
end)

describe("Codec", function()
	it("round-trips every state, with holes in the slot list", function()
		local text = Codec.encode({
			state = "carried",
			tag = "Couch",
			slots = { [1] = 11, [2] = 12, [4] = 14 },
			wobbleSeed = 7,
		})
		expect(text).toBe("carried|Couch|11,12,,14|7|")
		local d = Codec.decode(text)
		expect(d.state).toBe("carried")
		expect(d.tag).toBe("Couch")
		expect(d.slots[4]).toBe(14)
		expect(d.slots[3]).toBe(nil)
		expect(d.carriers).toEqual({ 11, 12, 14 })
		expect(d.wobbleSeed).toBe(7)
		expect(d.throw).toBe(nil)
	end)

	it("an idle object has no slot text; the throw part exists only while thrown", function()
		expect(Codec.encode({ state = "idle", tag = "Crate", slots = {}, wobbleSeed = 3 })).toBe(
			"idle|Crate||3|"
		)
		local text = Codec.encode({
			state = "thrown",
			tag = "Crate",
			slots = {},
			wobbleSeed = 3,
			throw = { from = 1, to = 2, startedAt = 12.5 },
		})
		expect(text).toBe("thrown|Crate||3|1,2,12.500")
		local d = Codec.decode(text)
		expect(d.throw.from).toBe(1)
		expect(d.throw.to).toBe(2)
		expect(d.throw.startedAt).toBe(12.5)
		-- a throw field on a non-thrown state is not encoded
		local dropped = Codec.encode({
			state = "dropped",
			tag = "Crate",
			slots = {},
			wobbleSeed = 3,
			throw = { from = 1, to = 2, startedAt = 1 },
		})
		expect(dropped).toBe("dropped|Crate||3|")
	end)

	it("rejects malformed text (never raises)", function()
		for _, bad in
			{
				"",
				"carried",
				"bogus|Crate||1|",
				"carried|Crate|x||",
				"carried|Crate||y|",
				"thrown|C||1|1,2",
				5,
				false,
			}
		do
			expect(Codec.decode(bad)).toBe(nil)
		end
	end)
end)

describe("Box", function()
	local cf = CF.new(V(0, 0, 0))
	it("distance to the closest point of the box (0 inside)", function()
		expect(Box.distance(cf, V(2, 2, 2), V(0, 0, 0))).toBe(0)
		expect(math.abs(Box.distance(cf, V(2, 2, 2), V(4, 0, 0)) - 3) < 1e-9).toBe(true)
		expect(math.abs(Box.distance(cf, V(2, 2, 2), V(4, 5, 0)) - 5) < 1e-9).toBe(true) -- 3, 4
	end)

	it("contains grows the box on every side", function()
		expect(Box.contains(cf, V(2, 2, 2), V(1.5, 0, 0))).toBe(false)
		expect(Box.contains(cf, V(2, 2, 2), V(1.5, 0, 0), 0.5)).toBe(true)
	end)

	it("containsBox: all 8 corners, rotated boxes included", function()
		local zone = CF.new(V(0, 0, 0))
		expect(Box.containsBox(zone, V(10, 10, 10), CF.new(V(0, 0, 0)), V(2, 2, 2))).toBe(true)
		expect(Box.containsBox(zone, V(10, 10, 10), CF.new(V(4.5, 0, 0)), V(2, 2, 2))).toBe(false)
		-- a 4x4 box turned 45 degrees about Y reaches 2.83 studs along x
		local turned = CF.fromParts(0, 0, 0, 0.7071, 0, 0.7071, 0, 1, 0, -0.7071, 0, 0.7071)
		expect(Box.containsBox(zone, V(5, 10, 5), turned, V(4, 4, 4))).toBe(false)
		expect(Box.containsBox(zone, V(6, 10, 6), turned, V(4, 4, 4))).toBe(true)
	end)

	it("works against a rotated zone", function()
		local zone = CF.fromParts(0, 0, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0) -- 90 degrees about Y
		expect(Box.contains(zone, V(20, 2, 2), V(0, 0, 8))).toBe(true) -- the long axis now runs along z
		expect(Box.contains(zone, V(20, 2, 2), V(8, 0, 0))).toBe(false)
	end)
end)

describe("Throw.velocity", function()
	it("flies at about throwSpeed toward a standing target and compensates gravity", function()
		local from, target = V(0, 3, 0), V(20, 3, 0)
		local v = Throw.velocity(from, target, V(0, 0, 0), 40, 196.2)
		-- flight time 0.5 s: horizontal 40 studs/s, vertical 0.5 * g * t = 49.05
		expect(math.abs(v.x - 40) < 1e-6).toBe(true)
		expect(math.abs(v.y - 49.05) < 1e-6).toBe(true)
		-- after t seconds under gravity it is at the target
		local t = 0.5
		local y = from.y + v.y * t - 0.5 * 196.2 * t * t
		expect(math.abs(y - 3) < 1e-6).toBe(true)
	end)

	it("leads a moving target", function()
		local v = Throw.velocity(V(0, 3, 0), V(20, 3, 0), V(0, 0, 10), 40, 196.2)
		expect(v.z > 5).toBe(true)
	end)
end)

describe("Rules.normalize", function()
	local cfg = { massClasses = { light = {}, medium = {}, heavy = {} } }
	it("fills the defaults", function()
		local d = Rules.normalize("Crate", {}, cfg, "test")
		expect(d.massClass).toBe("medium")
		expect(d.carriers).toEqual({ min = 1, max = 1 })
		expect(d.gripPoints).toEqual({ { 0, 0, 0 } })
		expect(d.speedPenalty).toBe(0)
		expect(d.fragility).toBe(1)
	end)

	it("refuses bad definitions, naming the caller and the tag", function()
		local function bad(def, text)
			local ok, err = pcall(Rules.normalize, "Thing", def, cfg, "Carry.registerCarriable")
			expect(ok).toBe(false)
			expect(string.find(tostring(err), "Carry.registerCarriable", 1, true) ~= nil).toBe(true)
			expect(string.find(tostring(err), "Thing", 1, true) ~= nil).toBe(true)
			expect(string.find(tostring(err), text, 1, true) ~= nil).toBe(true)
		end
		bad({ massClass = "gigantic" }, "massClass")
		bad({ carriers = { min = 0, max = 1 } }, "carriers")
		bad({ carriers = { min = 3, max = 2 } }, "carriers")
		bad({ carriers = { min = 1, max = 9 }, gripPoints = {} }, "carriers")
		bad({ carriers = { min = 1, max = 2 } }, "gripPoints") -- default grips are one entry
		bad({ speedPenalty = 2 }, "speedPenalty")
		bad({ fragility = -1 }, "fragility")
	end)

	it("a tag may not contain the codec's separators", function()
		expect(pcall(Rules.normalize, "A|B", {}, cfg, "x")).toBe(false)
		expect(pcall(Rules.normalize, "A,B", {}, cfg, "x")).toBe(false)
	end)

	it("merge: later layers win per field, false is kept", function()
		local m = Rules.merge({ a = 1, b = 2 }, nil, { b = false, c = 3 })
		expect(m.a).toBe(1)
		expect(m.b).toBe(false)
		expect(m.c).toBe(3)
	end)
end)
