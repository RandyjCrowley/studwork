local State = require(script.Parent.State)

local state = {
	loaded = true,
	modules = {
		Leaderboards = {
			extra = {
				boards = {
					weekly = {
						period = "weekly",
						periodId = "18995",
						endsAt = 100,
						title = "Leaderboards.board.weekly",
						rows = { { rank = 1, userId = 5, name = "Ann", value = 90 } },
						updatedAt = 50,
					},
					best = { period = "allTime", title = "Leaderboards.board.best", rows = {}, updatedAt = 0 },
				},
				mine = { weekly = { value = 40, rank = 3 }, best = { value = 7 } },
			},
		},
		Other = { extra = { boards = { nope = {} } } },
	},
}

describe("Leaderboards client State", function()
	it("lists the board ids sorted and reads each entry", function()
		expect(State.ids(state)).toEqual({ "best", "weekly" })
		expect(State.entry(state, "weekly").periodId).toBe("18995")
		expect(State.entry(state, "nope")).toBe(nil)
		expect(State.rows(state, "weekly")[1].name).toBe("Ann")
		expect(State.rows(state, "best")).toEqual({})
		expect(State.rows(state, "nope")).toEqual({})
	end)

	it("reads the player's own value and rank", function()
		expect(State.mine(state, "weekly")).toEqual({ value = 40, rank = 3 })
		expect(State.mine(state, "best").rank).toBe(nil)
		expect(State.mine(state, "nope")).toBe(nil)
	end)

	it("all() joins entry and own line in id order", function()
		local all = State.all(state)
		expect(#all).toBe(2)
		expect(all[1].id).toBe("best")
		expect(all[2].mine.value).toBe(40)
	end)

	it("handles an unloaded, empty or module-less state", function()
		for _, s in { {}, { loaded = false, modules = {} }, { modules = { Leaderboards = {} } }, "x" } do
			expect(State.ids(s)).toEqual({})
			expect(State.rows(s, "best")).toEqual({})
			expect(State.mine(s, "best")).toBe(nil)
		end
	end)
end)
