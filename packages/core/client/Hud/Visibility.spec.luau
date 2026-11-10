local Visibility = require(script.Parent.Visibility)

local function enabled(list)
	return function(name)
		return table.find(list, name) ~= nil
	end
end

local goal = function()
	return "x"
end

describe("Hud.Visibility", function()
	it("shows everything with Economy and Rebirth", function()
		expect(Visibility.of(enabled({ "Economy", "Rebirth" }), { nextGoal = goal })).toEqual({
			currency = true,
			rate = true,
			goal = true,
		})
	end)

	it("hides currency and rate without Economy", function()
		local shown = Visibility.of(enabled({}), { nextGoal = goal })
		expect(shown.currency).toBe(false)
		expect(shown.rate).toBe(false)
		expect(shown.goal).toBe(false)
	end)

	it("hides the goal without Rebirth, and the rate when showRate = false", function()
		local shown = Visibility.of(enabled({ "Economy" }), { nextGoal = goal, showRate = false })
		expect(shown.currency).toBe(true)
		expect(shown.rate).toBe(false)
		expect(shown.goal).toBe(false)
	end)
end)
