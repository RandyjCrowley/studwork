local Visibility = require(script.Parent.Visibility)

-- core-v1.3.1 (R19): the currency / rate / mailbox visibility moved with their assertions to the
-- economy and mail modules' client/State.spec.luau (each module gates its own widget).
local function enabled(list)
	return function(name)
		return table.find(list, name) ~= nil
	end
end

local goal = function()
	return "x"
end

describe("Hud.Visibility", function()
	it("shows the goal with any module set", function()
		expect(Visibility.of(enabled({ "Economy", "Rebirth" }), { nextGoal = goal })).toEqual({ goal = true })
		local shown = Visibility.of(enabled({}), { nextGoal = goal })
		expect(shown.goal).toBe(true) -- game-defined goal text works with any module set
	end)

	it("hides the goal without nextGoal", function()
		local shown = Visibility.of(enabled({ "Economy" }), { showRate = false })
		expect(shown.goal).toBe(false)
	end)
end)
