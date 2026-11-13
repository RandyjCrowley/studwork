--!nocheck
--[[
	Carry's client-side pure parts: the state readers (client/State.luau) over the replicated "carry:<id>"
	strings, and the cosmetic wobble spring (client/Wobble.luau). The bindings, widget and the visual
	offset need the engine: a Studio and manual check.
]]
local State = require("packages/kits/carry/Carry/client/State.luau")
local Wobble = require("packages/kits/carry/Carry/client/Wobble.luau")

local function stateWith(extra)
	return { modules = { Carry = { extra = extra } } }
end

describe("Carry client State", function()
	local state = stateWith({
		["carry:1"] = "carried|Crate|7|12|",
		["carry:2"] = "gathering|Couch|8,,9|40|",
		["carry:3"] = "thrown|Crate||5|1,2,3.000",
		["carry:x"] = "garbage",
		["other"] = "carried|Crate|7|1|",
	})

	it("reads an object's state and carrier user ids", function()
		local s, carriers = State.stateOf(state, "1")
		expect(s).toBe("carried")
		expect(carriers).toEqual({ 7 })
		local s2, c2 = State.stateOf(state, "2")
		expect(s2).toBe("gathering")
		expect(c2).toEqual({ 8, 9 })
	end)

	it("a missing key reads as idle; garbage reads as idle too", function()
		expect(State.stateOf(state, "99")).toBe("idle")
		expect(State.stateOf(state, "x")).toBe("idle")
		expect(State.stateOf({}, "1")).toBe("idle")
		expect(State.stateOf(nil, "1")).toBe("idle")
	end)

	it("lists the keys and finds the object a user holds a slot on (carried or gathering only)", function()
		expect(State.ids(state)).toEqual({ "1", "2", "3", "x" })
		expect((State.carrying(state, 7))).toBe("1")
		expect((State.carrying(state, 9))).toBe("2")
		expect((State.carrying(state, 1))).toBe(nil) -- thrown: the thrower holds nothing
		expect((State.carrying(state, 42))).toBe(nil)
		local _, info = State.carrying(state, 8)
		expect(info.tag).toBe("Couch")
		expect(info.wobbleSeed).toBe(40)
	end)

	it("a thrown object carries the throw part", function()
		local info = State.info(state, "3")
		expect(info.throw.from).toBe(1)
		expect(info.throw.to).toBe(2)
	end)
end)

describe("Carry client Wobble", function()
	local CFG = { enabled = true, maxDegrees = 9, hz = 2.2, damping = 0.6 }

	local function run(w, accelOf, seconds)
		local peak, angle, phase = 0, 0, 0
		for i = 1, seconds * 60 do
			angle, phase = Wobble.step(w, accelOf(i / 60), 1 / 60)
			peak = math.max(peak, math.abs(angle))
		end
		return peak, angle, phase
	end

	it("no motion, no wobble", function()
		local w = Wobble.new(CFG, 5)
		local peak = run(w, function()
			return 0
		end, 3)
		expect(peak).toBe(0)
	end)

	it("a sudden acceleration sways the object, within maxDegrees, then damps out", function()
		local w = Wobble.new(CFG, 5)
		local peak = run(w, function(t)
			return if t < 0.2 then 40 else 0
		end, 1)
		expect(peak > 1).toBe(true)
		expect(peak <= CFG.maxDegrees).toBe(true)
		local _, angle = run(w, function()
			return 0
		end, 8)
		expect(math.abs(angle) < 0.2).toBe(true)
	end)

	it("the phase is seeded by wobbleSeed and advances", function()
		local a, b = Wobble.new(CFG, 100), Wobble.new(CFG, 600)
		expect(a.phase ~= b.phase).toBe(true)
		local _, _, p1 = run(a, function()
			return 0
		end, 0.5)
		expect(p1 ~= Wobble.new(CFG, 100).phase).toBe(true)
	end)

	it("is stable through a long frame (a hitch) and when disabled", function()
		local w = Wobble.new(CFG, 1)
		local angle = Wobble.step(w, 500, 5)
		expect(math.abs(angle) <= CFG.maxDegrees).toBe(true)
		local off = Wobble.new({ enabled = false, maxDegrees = 9, hz = 2.2, damping = 0.6 }, 1)
		expect((Wobble.step(off, 500, 1 / 60))).toBe(0)
	end)
end)
