--!nocheck
-- Goals funnel steps (docs/framework/kits/quests.md, Goals "Funnel steps"): each goal's step is
-- logged once per player (h.fake.analytics), also out of order and after a rejoin; an out-of-order
-- ackGoal is refused (a client can't log ack steps early).
local G = require("packages/kits/quests/tests/GoalsHelpers.luau")
local Goals = G.Goals

local CHAIN = {
	{ id = "first", check = { call = true }, funnel = "First" },
	{ id = "open", check = { ack = true }, widget = "Quests.button", funnel = "Opened" },
	{ id = "last", check = { call = true }, funnel = "Last" },
}

describe("Goals funnel", function()
	it("logs every goal's step exactly once, in tx.after of the update that marked it", function()
		local h = G.boot({ chain = CHAIN })
		local goals = h:use(Goals)
		local p = h:addPlayer({ userId = 1 })
		goals.complete(p, "first")
		expect(G.funnels(h, p)).toEqual({}) -- queued: nothing written yet
		h:tick(1)
		expect(G.funnels(h, p)).toEqual({ "First" })
		expect(h:action(p, Goals, "ackGoal", "open")).toBe(true)
		expect(G.funnels(h, p)).toEqual({ "First", "Opened" })
		goals.complete(p, "last")
		goals.complete(p, "last") -- a second call before the tick: still one step
		h:tick(3)
		expect(G.funnels(h, p)).toEqual({ "First", "Opened", "Last" })
		-- the framework numbers the steps by their place in analytics.funnel
		for _, a in h.fake.analytics do
			if a.kind == "funnel" and a.name == "Last" then
				expect(a.index).toBe(4)
			end
		end
	end)

	it("out of order: a later goal's step is logged when it is done, and never again", function()
		local h = G.boot({ chain = CHAIN })
		local goals = h:use(Goals)
		local p = h:addPlayer({ userId = 2 })
		goals.complete(p, "last")
		h:tick(1)
		expect(G.funnels(h, p)).toEqual({ "Last" })
		goals.complete(p, "first")
		h:tick(1)
		h:action(p, Goals, "ackGoal", "open")
		h:tick(1)
		expect(G.funnels(h, p)).toEqual({ "Last", "First", "Opened" })
	end)

	it("after a rejoin nothing is logged twice", function()
		local h = G.boot({ chain = CHAIN })
		local goals = h:use(Goals)
		local p = h:addPlayer({ userId = 3 })
		goals.complete(p, "first")
		h:tick(1)
		h:rejoin(p, { secondsAway = 120 })
		h:tick(2)
		expect(h:use(Goals).current(p).id).toBe("open")
		h:action(p, Goals, "ackGoal", "open")
		h:use(Goals).complete(p, "last")
		h:tick(1)
		h:rejoin(p, { secondsAway = 3600 })
		h:tick(5)
		local steps = G.funnels(h, p)
		expect(G.count(steps, "First")).toBe(1)
		expect(G.count(steps, "Opened")).toBe(1)
		expect(G.count(steps, "Last")).toBe(1)
	end)

	it("refuses an out-of-order ackGoal (not the current goal), a non-ack goal and an unknown id", function()
		local h = G.boot({ chain = CHAIN })
		local p = h:addPlayer({ userId = 4 })
		local ok, result = h:action(p, Goals, "ackGoal", "open")
		expect(ok).toBe(true) -- routed
		expect(result).toBe(false) -- refused: "first" is current
		expect(select(2, h:action(p, Goals, "ackGoal", "first"))).toBe(false) -- a call goal
		expect(select(2, h:action(p, Goals, "ackGoal", "nope"))).toBe(false)
		h:tick(1)
		expect(G.funnels(h, p)).toEqual({})
		expect(h:use(Goals).current(p).id).toBe("first")
		h:use(Goals).complete(p, "first")
		h:tick(1)
		expect(select(2, h:action(p, Goals, "ackGoal", "open"))).toBe(true)
		expect(select(2, h:action(p, Goals, "ackGoal", "open"))).toBe(false) -- already done
		expect(G.funnels(h, p)).toEqual({ "First", "Opened" })
	end)

	it("a step missing from analytics.funnel is dropped by the framework, the goal still moves", function()
		local h = G.boot({ chain = CHAIN, funnel = { "Joined", "First" } })
		local goals = h:use(Goals)
		local p = h:addPlayer({ userId = 5 })
		goals.complete(p, "first")
		h:tick(1)
		h:action(p, Goals, "ackGoal", "open")
		expect(G.funnels(h, p)).toEqual({ "First" })
		expect(goals.current(p).id).toBe("last")
	end)
end)
