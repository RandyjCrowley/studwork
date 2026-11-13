--!nocheck
-- Goals quick start (docs/framework/kits/quests.md, "Quick start": Goals with no Quests): a source
-- threshold and a game call, the funnel steps, the hand-over to setNext. No Quests module at all.
local G = require("packages/kits/quests/tests/GoalsHelpers.luau")
local Goals, Economy = G.Goals, G.Economy

local CHAIN = {
	{
		id = "firstCoins",
		check = { source = "currency", atLeast = 50 },
		target = { tag = "CoinSpot" },
		funnel = "FirstCoins",
	},
	{
		id = "buyUpgrade",
		check = { call = true },
		target = { path = "Workspace.Shop.Counter" },
		funnel = "FirstUpgrade",
	},
}

describe("Goals quick start (no Quests)", function()
	it("walks the page's chain: currency, a game call, then what's next", function()
		local h = G.boot({ chain = CHAIN })
		local goals = h:use(Goals)
		local p = h:addPlayer({ userId = 1 })
		local view = goals.current(p)
		expect(view.id).toBe("firstCoins")
		expect(view.index).toBe(1)
		expect(view.count).toBe(2)
		expect(view.text).toBe("Goals.goal.firstCoins")
		expect(view.target).toEqual({ tag = "CoinSpot" })
		expect(view.isNext).toBe(false)
		expect(view.hidden).toBe(false)

		h:use(Economy).grant(p, 50, "test")
		h:tick(1)
		expect(goals.current(p).id).toBe("buyUpgrade")
		expect(G.funnels(h, p)).toEqual({ "FirstCoins" })

		expect(goals.complete(p, "buyUpgrade")).toBe(true)
		h:tick(1)
		expect(goals.current(p)).toBeNil() -- chain done, no provider
		expect(G.funnels(h, p)).toEqual({ "FirstCoins", "FirstUpgrade" })

		goals.setNext(function()
			return { text = "game.next.rebirth", target = { tag = "RebirthPad" } }
		end)
		h:tick(1)
		local nextView = goals.current(p)
		expect(nextView.isNext).toBe(true)
		expect(nextView.id).toBeNil()
		expect(nextView.text).toBe("game.next.rebirth")
		expect(nextView.target).toEqual({ tag = "RebirthPad" })
	end)

	it("boots with no config at all and stays idle", function()
		local h = G.F.harness({ modules = { Goals } })
		local p = h:addPlayer({ userId = 2 })
		h:tick(3)
		expect(h:use(Goals).current(p)).toBeNil()
		expect(h:use(Goals).complete(p, "anything")).toBe(false)
		h:removePlayer(p)
		expect(h:saved(p).goals.v).toBe(0) -- nothing written with an empty chain
	end)

	it("the flag off: nothing evaluated or written, calls refuse disabled", function()
		local h = G.boot({
			chain = CHAIN,
			goals = { flag = "goalsOn" },
			flags = { goalsOn = { default = false } },
		})
		local goals = h:use(Goals)
		local p = h:addPlayer({ userId = 3 })
		expect(goals.current(p)).toBeNil()
		expect(select(2, goals.complete(p, "buyUpgrade"))).toBe("disabled")
		h:use(Economy).grant(p, 60, "test")
		h:tick(2)
		expect(G.funnels(h, p)).toEqual({})
		h:removePlayer(p)
		expect(h:saved(p).goals.v).toBe(0)
	end)
end)
