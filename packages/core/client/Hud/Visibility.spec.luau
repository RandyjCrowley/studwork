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
			mailbox = false,
		})
	end)

	it("shows the mailbox slot only with Mail", function()
		expect(Visibility.of(enabled({ "Mail" }), {}).mailbox).toBe(true)
		expect(Visibility.of(enabled({ "Economy" }), {}).mailbox).toBe(false)
	end)

	it("counts mailbox entries", function()
		expect(Visibility.mailboxCount({ mailbox = { {}, {}, {} } })).toBe(3)
		expect(Visibility.mailboxCount({})).toBe(0)
		expect(Visibility.mailboxCount({ mailbox = "bad" })).toBe(0)
		expect(Visibility.mailboxCount(nil)).toBe(0)
	end)

	it("hides currency and rate without Economy", function()
		local shown = Visibility.of(enabled({}), { nextGoal = goal })
		expect(shown.currency).toBe(false)
		expect(shown.rate).toBe(false)
		expect(shown.goal).toBe(true) -- game-defined goal text works with any module set
	end)

	it("hides the goal without nextGoal, and the rate when showRate = false", function()
		local shown = Visibility.of(enabled({ "Economy" }), { showRate = false })
		expect(shown.currency).toBe(true)
		expect(shown.rate).toBe(false)
		expect(shown.goal).toBe(false)
	end)
end)
