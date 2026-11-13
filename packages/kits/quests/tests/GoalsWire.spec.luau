--!nocheck
-- Goals server wiring: named {x, y, z} positions reach the wire as arrays; a goal whose funnel step
-- isn't in the game's analytics.funnel logs one boot warning (ctx.gameConfig.analytics).
local G = require("packages/kits/quests/tests/GoalsHelpers.luau")
local Goals = G.Goals

local function warningsWith(h, text)
	local n = 0
	for _, w in h:warnings() do
		if string.find(w, text, 1, true) then
			n += 1
		end
	end
	return n
end

describe("Goals wire targets", function()
	it("a named position is sent as an array (current view and extra.goal)", function()
		local h = G.boot({
			chain = {
				{ id = "go", check = { call = true }, target = { position = { x = 1, y = 2, z = 3 } } },
			},
		})
		local goals = h:use(Goals)
		local p = h:addPlayer({ userId = 1 })
		h:tick(1)
		expect(goals.current(p).target).toEqual({ position = { 1, 2, 3 } })
		expect(G.extraGoal(h, p).target).toEqual({ position = { 1, 2, 3 } })
	end)

	it("an array position is unchanged, and a setNext answer's named position is converted too", function()
		local h = G.boot({
			chain = { { id = "go", check = { call = true }, target = { position = { 4, 5, 6 } } } },
		})
		local goals = h:use(Goals)
		local p = h:addPlayer({ userId = 2 })
		h:tick(1)
		expect(goals.current(p).target).toEqual({ position = { 4, 5, 6 } })
		goals.setNext(function()
			return { text = "game.next", target = { position = { x = 7, y = 8, z = 9 } } }
		end)
		goals.complete(p, "go")
		h:tick(2)
		expect(goals.current(p).target).toEqual({ position = { 7, 8, 9 } })
	end)
end)

describe("Goals funnel boot warning", function()
	local CHAIN = {
		{ id = "a", check = { call = true }, funnel = "Listed" },
		{ id = "b", check = { call = true }, funnel = "NotListed" },
	}

	it("warns once for each step missing from analytics.funnel", function()
		local h = G.boot({ chain = CHAIN, funnel = { "Joined", "Listed" } })
		h:use(Goals)
		expect(warningsWith(h, "goal 'b': funnel step 'NotListed' is not in GameConfig.analytics.funnel")).toBe(
			1
		)
		expect(warningsWith(h, "goal 'a'")).toBe(0)
	end)

	it("no warning when every step is listed", function()
		local h = G.boot({ chain = CHAIN, funnel = { "Joined", "Listed", "NotListed" } })
		h:use(Goals)
		expect(warningsWith(h, "funnel step")).toBe(0)
	end)
end)
