local Shake = require(script.Parent.Shake)

describe("Feedback.Shake", function()
	it("is zero outside the active window", function()
		local x, y, r = Shake.offset(1, 0.5, 1, 0)
		expect(x).toBe(0)
		expect(y).toBe(0)
		expect(r).toBe(0)
		x = Shake.offset(-0.1, 0.5, 1, 0)
		expect(x).toBe(0)
		x = Shake.offset(0.1, 0.5, 0, 0)
		expect(x).toBe(0)
	end)
	it("decays: peak magnitude late is below early", function()
		local early, late = 0, 0
		for i = 0, 20 do
			local t = i * 0.005
			local x, y = Shake.offset(t, 0.5, 1, 1)
			early = math.max(early, math.abs(x) + math.abs(y))
			local x2, y2 = Shake.offset(0.4 + t * 0.5, 0.5, 1, 1)
			late = math.max(late, math.abs(x2) + math.abs(y2))
		end
		expect(late).toBeLessThan(early)
		expect(early).toBeLessThanOrEqual(0.35 * 2 + 1e-9)
	end)
	it("only shakes for Legendary and above, growing per tier", function()
		expect(Shake.forRarity(4)).toBeNil()
		local l = Shake.forRarity(5) :: number
		local m = Shake.forRarity(6) :: number
		expect(l).toBeGreaterThan(0)
		expect(m).toBeGreaterThan(l)
		expect(Shake.forRarity(100)).toBe(Shake.MAX_INTENSITY)
	end)
	it("combine stacks and caps", function()
		expect(Shake.combine(1, 1)).toBe(2)
		expect(Shake.combine(2, 2)).toBe(Shake.MAX_INTENSITY)
		expect(Shake.combine(-1, 0.5)).toBe(0.5)
	end)
end)
