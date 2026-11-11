--!nocheck
-- The client view-model (pure): tools/test examples/modules/session-leaderboard
local View = require("examples/modules/session-leaderboard/client/View.luau")

describe("SessionLeaderboard View.summary", function()
	local slice = {
		data = { best = 12 },
		extra = {
			earned = 30,
			top = {
				{ userId = 2, name = "Bo", earned = 50 },
				{ userId = 1, name = "Ann", earned = 30 },
				{ userId = 3, name = "Cy", earned = 10 },
			},
		},
	}

	it("ranks rows, marks the local player and keeps best >= this session", function()
		local s = View.summary(slice, 1)
		expect(#s.rows).toBe(3)
		expect(s.rows[1].name).toBe("Bo")
		expect(s.rows[2].isYou).toBe(true)
		expect(s.yourRank).toBe(2)
		expect(s.earned).toBe(30)
		expect(s.best).toBe(30)
	end)

	it("limits rows but still finds your rank", function()
		local s = View.summary(slice, 3, 2)
		expect(#s.rows).toBe(2)
		expect(s.yourRank).toBe(3)
	end)

	it("an empty or missing slice is all zeros", function()
		for _, empty in { {}, { data = {}, extra = {} }, nil } do
			local s = View.summary(empty, 1)
			expect(s.earned).toBe(0)
			expect(s.best).toBe(0)
			expect(#s.rows).toBe(0)
			expect(s.yourRank).toBeNil()
		end
	end)
end)
