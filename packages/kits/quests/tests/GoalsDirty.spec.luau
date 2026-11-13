--!nocheck
-- Goals dirty marks (docs/framework/kits/quests.md, "How the chain moves"): a signal marks the
-- player for a re-check only when it can change one of the player's not-done goals, so a busy
-- game's per-tick CurrencyChanged and Progressed cost a lookup, not a check. A registered source's
-- read count shows whether a check ran (every check reads every not-done goal).
local G = require("packages/kits/quests/tests/GoalsHelpers.luau")
local F = G.F
local Goals, Economy, Quests = G.Goals, G.Economy, G.Quests

local function goal(id, check)
	return { id = id, check = check, funnel = "Step_" .. id }
end

describe("Goals dirty marks", function()
	it("CurrencyChanged marks the player only when the new balance can meet an open currency goal", function()
		local source = F.valueSource({ goals = true, quests = false })
		local h = G.boot({
			probes = { source },
			chain = {
				goal("v", { source = "testValue", atLeast = 3 }),
				goal("coins", { source = "currency", atLeast = 100 }),
				goal("named", { source = "currency", atLeast = 120, params = { currency = "Coins" } }),
			},
		})
		local p = h:addPlayer({ userId = 1 })
		local econ = h:use(Economy)
		h:tick(1) -- the load check
		local reads = source.reads
		econ.grant(p, 50, "test")
		h:tick(1)
		expect(source.reads).toBe(reads) -- below every atLeast: no check
		econ.grant(p, 60, "test") -- 110: coins can be met (out of order)
		h:tick(1)
		expect(source.reads > reads).toBe(true)
		expect(G.funnels(h, p)).toEqual({ "Step_coins" })
		reads = source.reads
		econ.grant(p, 5, "test") -- 115: the only open currency goal needs 120
		h:tick(1)
		expect(source.reads).toBe(reads)
		econ.grant(p, 5, "test") -- 120 Coins: the named goal
		h:tick(1)
		expect(G.funnels(h, p)).toEqual({ "Step_coins", "Step_named" })
		expect(h:use(Goals).current(p).id).toBe("v")
	end)

	it("Quests signals mark the player only for an open goal on that quest", function()
		local states = {
			q1 = { status = "active", values = { 0 } },
			q3 = { status = "active", values = { 1 } },
			q4 = { status = "active", values = { 0 } },
		}
		local fake = G.fakeQuests(states)
		local source = F.valueSource({ goals = true, quests = false })
		local h = G.boot({
			modules = { Quests, Goals },
			servers = { Quests = fake },
			probes = { source },
			chain = {
				goal("v", { source = "testValue", atLeast = 3 }),
				goal("obj3", { quest = "q3", objective = 1 }),
				goal("done4", { quest = "q4" }),
			},
		})
		local p = h:addPlayer({ userId = 2 })
		h:tick(1)
		local reads = source.reads
		fake.fired.Progressed:Fire(p, { "q1" }) -- no goal names q1
		fake.fired.Completed:Fire(p, "q1")
		fake.fired.Progressed:Fire(p, { "q4" }) -- q4's goal is complete-only: progress can't meet it
		h:tick(1)
		expect(source.reads).toBe(reads)
		states.q3 = { status = "active", values = { 3 } }
		fake.fired.Progressed:Fire(p, { "q1", "q3" })
		h:tick(1)
		expect(source.reads > reads).toBe(true)
		expect(G.funnels(h, p)).toEqual({ "Step_obj3" })
		reads = source.reads
		fake.fired.Progressed:Fire(p, { "q3" }) -- obj3 is done now: nothing open on q3
		h:tick(1)
		expect(source.reads).toBe(reads)
		states.q4 = { status = "complete", values = { 3 } }
		fake.fired.Completed:Fire(p, "q4")
		h:tick(1)
		expect(G.funnels(h, p)).toEqual({ "Step_obj3", "Step_done4" })
	end)

	it("a goals reset forgets what was done: the open goals' signals count again", function()
		local source = F.valueSource({ goals = true, quests = false })
		local h = G.boot({
			probes = { source },
			isStudio = true, -- goals reset is Studio-only
			chain = {
				goal("v", { source = "testValue", atLeast = 3 }),
				goal("coins", { source = "currency", atLeast = 10 }),
			},
		})
		local p = h:addPlayer({ userId = 3 })
		local econ = h:use(Economy)
		h:tick(1)
		econ.grant(p, 10, "test")
		h:tick(1)
		expect(G.funnels(h, p)).toEqual({ "Step_coins" })
		local reads = source.reads
		econ.grant(p, 1, "test") -- coins is done: a currency change marks nothing
		econ.spend(p, econ.balance(p), "test")
		h:tick(1)
		expect(source.reads).toBe(reads)
		h:console("goals", "reset", tostring(p.UserId))
		h:tick(1) -- the reset's own check (balance 0: coins is open)
		reads = source.reads
		econ.grant(p, 5, "test")
		h:tick(1)
		expect(source.reads).toBe(reads)
		econ.grant(p, 5, "test") -- 10: coins can be met again
		h:tick(1)
		expect(source.reads > reads).toBe(true)
		expect(h:use(Goals).current(p).id).toBe("v")
	end)
end)
