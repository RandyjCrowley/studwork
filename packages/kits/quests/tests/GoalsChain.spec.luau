--!nocheck
-- Goals: how the chain moves (docs/framework/kits/quests.md, Goals "How the chain moves"): the
-- current goal is the first not done; out-of-order completion; ChainDone once; Goals.complete from
-- inside a game tx is queued and lands on the next tick; signals only mark the player dirty and a
-- player is checked at most once per tick.
local G = require("packages/kits/quests/tests/GoalsHelpers.luau")
local F = G.F
local Goals = G.Goals

local function chain()
	return {
		{ id = "a", check = { call = true }, funnel = "StepA" },
		{ id = "b", check = { call = true }, funnel = "StepB" },
		{ id = "c", check = { source = "testValue", atLeast = 5 }, funnel = "StepC" },
	}
end

local function boot(extra)
	local source = F.valueSource({ goals = true, quests = false })
	local opts = { chain = chain(), probes = { source } }
	for k, v in extra or {} do
		opts[k] = v
	end
	if opts.probes ~= nil and not table.find(opts.probes, source) then
		table.insert(opts.probes, source)
	end
	return G.boot(opts), source
end

describe("Goals chain", function()
	it("the current goal is the first one not done; out-of-order goals are done at once", function()
		local h = boot()
		local goals = h:use(Goals)
		local log = G.signalLog(h)
		local p = h:addPlayer({ userId = 1 })
		expect(goals.current(p).id).toBe("a")

		expect(goals.complete(p, "b")).toBe(true) -- out of order
		h:tick(1)
		expect(goals.current(p).id).toBe("a") -- the pointer stays on a
		expect(G.funnels(h, p)).toEqual({ "StepB" }) -- logged when it was done
		expect(#log.changed).toBe(0)

		expect(goals.complete(p, "a")).toBe(true)
		h:tick(1)
		expect(goals.current(p).id).toBe("c") -- skips the done b
		expect(goals.current(p).index).toBe(3)
		expect(log.changed).toEqual({ { id = "c", prev = "a" } })
		expect(select(2, goals.complete(p, "b"))).toBe("done")
		expect(select(2, goals.complete(p, "nope"))).toBe("unknown_goal")
	end)

	it("ChainDone fires once; the finished chain stays finished", function()
		local h, source = boot()
		local goals = h:use(Goals)
		local log = G.signalLog(h)
		local p = h:addPlayer({ userId = 2 })
		goals.complete(p, "a")
		goals.complete(p, "b")
		h:tick(1)
		source:set(p, 9)
		h:tick(1)
		expect(goals.current(p)).toBeNil()
		expect(log.done).toBe(1)
		expect(log.changed[#log.changed]).toEqual({ id = nil, prev = "c" })
		source:set(p, 10)
		h:tick(3)
		expect(log.done).toBe(1)
		expect(select(2, goals.complete(p, "a"))).toBe("done")
		h:rejoin(p, { secondsAway = 60 })
		h:tick(2)
		expect(log.done).toBe(1)
		expect(h:use(Goals).current(p)).toBeNil()
		expect(G.funnels(h, p)).toEqual({ "StepA", "StepB", "StepC" })
	end)

	it("Goals.complete inside a game's own tx is queued (no nested tx) and lands on the next tick", function()
		local probe = G.txProbe()
		local h = boot({ probes = { probe } })
		local goals = h:use(Goals)
		local p = h:addPlayer({ userId = 3 })
		local txOk, ok, why = h:use(probe.ref).inTx(p, "a")
		expect(txOk).toBe(true) -- the game's tx committed: complete never opened a tx
		expect(ok).toBe(true)
		expect(why).toBeNil()
		expect(goals.current(p).id).toBe("a") -- not yet written
		h:tick(1)
		expect(goals.current(p).id).toBe("b")
		expect(G.funnels(h, p)).toEqual({ "StepA" })
	end)

	it("a signal only marks the player dirty: at most one check per player per tick", function()
		local h, source = boot()
		local p = h:addPlayer({ userId = 4 })
		h:tick(1) -- the load check
		local before = source.reads
		for _ = 1, 50 do
			source:fire(p) -- 50 changes inside one second
		end
		expect(source.reads).toBe(before) -- no check on the signal itself
		h:tick(1)
		expect(source.reads).toBe(before + 1) -- one check for the one not-done source goal
		h:tick(3)
		expect(source.reads).toBe(before + 1) -- idle: no polling with a changed signal
	end)

	it("one tx per batch: several goals done in the same tick are written together", function()
		local h, source = boot()
		local goals = h:use(Goals)
		local log = G.signalLog(h)
		local p = h:addPlayer({ userId = 5 })
		goals.complete(p, "a")
		goals.complete(p, "b")
		source:set(p, 5)
		h:tick(1)
		expect(goals.current(p)).toBeNil()
		expect(log.done).toBe(1)
		expect(#log.changed).toBe(1) -- a -> nil in one step
		expect(G.funnels(h, p)).toEqual({ "StepA", "StepB", "StepC" })
	end)

	it("replicates extra.goal when the current goal changes", function()
		local h = boot()
		local p = h:addPlayer({ userId = 6 })
		h:tick(1)
		local wire = G.extraGoal(h, p)
		expect(wire.id).toBe("a")
		expect(wire.i).toBe(1)
		expect(wire.n).toBe(3)
		expect(wire.next).toBe(false)
		expect(wire.hidden).toBe(false)
		h:use(Goals).complete(p, "a")
		h:tick(1)
		expect(G.extraGoal(h, p).id).toBe("b")
	end)

	it("skip hides the goal (saved) and keeps tracking; refused when not skippable", function()
		local h = boot()
		local goals = h:use(Goals)
		local p = h:addPlayer({ userId = 7 })
		expect(goals.skip(p, true)).toBe(true)
		expect(goals.current(p).hidden).toBe(true)
		goals.complete(p, "a")
		h:tick(1)
		expect(goals.current(p).id).toBe("b") -- still tracked while hidden
		expect(G.funnels(h, p)).toEqual({ "StepA" })
		h:rejoin(p, { secondsAway = 10 })
		expect(h:use(Goals).current(p).hidden).toBe(true)
		local ok = h:action(p, Goals, "skipGoals", false)
		expect(ok).toBe(true)
		expect(h:use(Goals).current(p).hidden).toBe(false)

		local h2 = boot({ goals = { skippable = false } })
		local q = h2:addPlayer({ userId = 8 })
		expect(h2:use(Goals).skip(q, true)).toBe(false)
		expect(h2:use(Goals).current(q).hidden).toBe(false)
	end)
end)
