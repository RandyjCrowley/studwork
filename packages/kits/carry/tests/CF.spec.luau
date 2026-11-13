--!nocheck
-- CF (the carry kit's CFrame math): mul/inverse/pointTo, lerp, lookAlong.
local CF = require("packages/kits/carry/Carry/shared/CF.luau")

local V = vector.create

local function near(a: vector, b: vector, eps: number?)
	expect(vector.magnitude(a - b) < (eps or 1e-6)).toBe(true)
end

-- a 90 degree turn about +Y: local -Z (forward) maps to world -X
local TURN = CF.fromParts(0, 0, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0)

describe("CF", function()
	it("pointTo applies the rotation then the position", function()
		local a = CF.new(V(10, 0, 0), TURN.r)
		near(CF.pointTo(a, V(0, 0, -1)), V(9, 0, 0))
	end)

	it("mul then inverse is the identity", function()
		local a = CF.new(V(1, 2, 3), TURN.r)
		local b = CF.new(V(-4, 5, 6))
		local c = CF.mul(a, b)
		local back = CF.mul(CF.inverse(a), c)
		near(back.p, b.p)
		for i = 1, 9 do
			expect(math.abs(back.r[i] - b.r[i]) < 1e-9).toBe(true)
		end
		local id = CF.mul(a, CF.inverse(a))
		near(id.p, V(0, 0, 0))
	end)

	it("lookAlong points -Z along the direction and keeps up near world up", function()
		local cf = CF.lookAlong(V(0, 0, 0), V(0, 0, -5))
		near(CF.lookVector(cf), V(0, 0, -1))
		near(CF.upVector(cf), V(0, 1, 0))
		local east = CF.lookAlong(V(0, 0, 0), V(1, 0, 0))
		near(CF.lookVector(east), V(1, 0, 0))
		near(CF.upVector(east), V(0, 1, 0))
		-- straight up: still a valid rotation
		local up = CF.lookAlong(V(0, 0, 0), V(0, 1, 0))
		near(CF.lookVector(up), V(0, 1, 0))
	end)

	it("lerp moves the position linearly and turns by the shortest arc", function()
		local a = CF.new(V(0, 0, 0))
		local b = CF.new(V(10, 0, 0), TURN.r)
		near(CF.lerp(a, b, 0).p, V(0, 0, 0))
		near(CF.lerp(a, b, 1).p, V(10, 0, 0))
		near(CF.lerp(a, b, 0.5).p, V(5, 0, 0))
		near(CF.lookVector(CF.lerp(a, b, 1)), V(-1, 0, 0), 1e-6)
		-- half way between forward (-Z) and -X is 45 degrees
		local half = CF.lookVector(CF.lerp(a, b, 0.5))
		near(half, V(-math.sqrt(0.5), 0, -math.sqrt(0.5)), 1e-6)
	end)
end)
