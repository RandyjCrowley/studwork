--!nocheck
--[[
	Quests progress batching (docs/framework/kits/quests.md, "Batching progress"): no save write per
	increment, the staggered fold, leave and shutdown folds, a completion folded on the next tick,
	amounts, progress from inside a game tx and from inside a reward handler, and increments to an
	ended period's slot quests dropped until the player's rotation.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local K = require("packages/kits/quests/tests/QuestsKit.luau")
local F = K.F
local Quests = K.Quests
local State = require(ReplicatedStorage.Modules.Quests.client.State) -- decodes extra.prog

-- counts the framework transactions (ctx.tx and ctx.data.update both run through runTx)
local function countTx(h)
	local counter = { n = 0 }
	local data = h.runtime.data
	local original = data.runTx
	data.runTx = function(...)
		counter.n += 1
		return original(...)
	end
	return counter
end

local function cfg(extra)
	local c = F.questsConfig()
	c.foldSeconds = 10
	for k, v in extra or {} do
		c[k] = v
	end
	return c
end

describe("Quests progress batching", function()
	it("writes nothing per increment: one fold per player per foldSeconds", function()
		local h, p, q = K.boot({ quests = cfg() })
		local tx = countTx(h)
		for _ = 1, 100 do
			q.progress(p, "jump", 0.01 + 0) -- floored to at least 1 each, capped at the target
		end
		for _ = 1, 50 do
			q.progress(p, "tutorial", 0) -- a bad amount: refused
		end
		expect(tx.n).toBe(0)
		expect(q.state(p, "d4").values).toEqual({ 10 })
		expect(q.state(p, "d4").status).toBe("complete") -- live values
		h:tick(1) -- the completion folds on the next tick: one tx
		expect(tx.n).toBe(1)
		-- non-completing progress waits for the player's fold phase
		q.progress(p, "coin", 1)
		q.progress(p, "coin", 1)
		local n = tx.n
		h:tick(10) -- the player's fold phase comes once in foldSeconds
		expect(tx.n).toBe(n + 1)
		h:tick(10)
		expect(tx.n).toBe(n + 1) -- nothing pending: no tx
	end)

	it("staggers the folds of different players over foldSeconds", function()
		local c = cfg()
		c.quests = {
			a = F.quest("daily", { F.counter("coin", 1000) }),
			b = F.quest("weekly", { F.counter("coin", 1000) }),
		}
		c.daily = { count = 1, rerollsPerSlot = 0 }
		c.weekly = { count = 1, rerollsPerSlot = 0 }
		c.chains = {}
		local h = K.harness({ quests = c })
		local q = h:use(Quests)
		local ps = {}
		for i = 1, 10 do
			ps[i] = h:addPlayer({ userId = i })
		end
		local tx = countTx(h)
		local perTick = {}
		for t = 1, 10 do
			for _, p in ps do
				q.progress(p, "coin", 1)
			end
			local before = tx.n
			h:tick(1)
			perTick[t] = tx.n - before
		end
		local total, max = 0, 0
		for _, n in perTick do
			total += n
			max = math.max(max, n)
		end
		expect(total).toBe(10) -- each player folded once in 10 s
		expect(max <= 2).toBe(true) -- spread, not all on one tick
	end)

	it("folds pending progress on leave and on shutdown", function()
		local store = StudWork.test.memoryStore()
		local h, p, q = K.boot({ quests = cfg(), store = store })
		q.progress(p, "coin", 2)
		h:removePlayer(p)
		local s = K.section(h, p)
		for _, slot in s.day.slots do
			if slot.q == "d1" then
				expect(slot.n).toEqual({ 2 })
			end
		end
		expect(s.week.slots).toBeTruthy()
		local p2 = h:addPlayer({ userId = 1 })
		q.progress(p2, "coin", 1)
		h:shutdown()
		expect(h:saved(p2).quests.prog.rep.n).toEqual({ 3 }) -- 2 before the rejoin + 1 (rep shares "coin")
	end)

	it("refuses bad amounts and floors the rest", function()
		local _, p, q = K.boot({ quests = cfg({ maxAmount = 100 }) })
		expect(q.progress(p, "jump", 0)).toBe(false)
		expect(q.progress(p, "jump", -1)).toBe(false)
		expect(q.progress(p, "jump", 0 / 0)).toBe(false)
		expect(q.progress(p, "jump", math.huge)).toBe(false)
		expect(q.progress(p, "jump", 101)).toBe(false)
		expect(q.progress(p, "jump", "3")).toBe(false)
		expect(q.progress(p, "nobody", 1)).toBe(false) -- nothing matched
		expect(q.progress(p, "jump", 2.9)).toBe(true)
		expect(q.state(p, "d4").values).toEqual({ 2 })
		expect(q.progress(p, "jump", 0.2)).toBe(true)
		expect(q.state(p, "d4").values).toEqual({ 3 })
	end)

	it(
		"fires Completed once, after the fold commits, and Progressed coalesced per replicateSeconds",
		function()
			local h, p, q = K.boot({ quests = cfg() })
			local completed, progressed = {}, {}
			q.signals.Completed:Connect(function(_, id)
				table.insert(completed, id)
			end)
			q.signals.Progressed:Connect(function(player, ids) -- once per send: the ids that moved
				for _, id in ids do
					table.insert(progressed, id .. "=" .. table.concat(q.state(player, id).values, ","))
				end
			end)
			for _ = 1, 4 do
				q.progress(p, "jump", 1)
			end
			expect(#progressed).toBe(0)
			h:tick(1)
			expect(progressed).toEqual({ "d4=4" })
			for _ = 1, 6 do
				q.progress(p, "jump", 1)
			end
			expect(#completed).toBe(0) -- not before the commit
			h:tick(1)
			expect(completed).toEqual({ "d4" })
			h:tick(5)
			expect(completed).toEqual({ "d4" })
			expect(q.progress(p, "jump", 1)).toBe(false) -- complete: nothing moves
		end
	)

	it("is safe inside a game tx and inside a reward handler; the completion lands next tick", function()
		local Probe = StudWork.defineModule({
			name = "TxProbe",
			version = "1.0.0",
			framework = "^1.7.0",
			optional = { Quests },
			data = { key = "txprobe", version = 1, default = { n = 0 } },
		})
		local probePart = {}
		local probeCtx
		probePart.init = function(ctx)
			probeCtx = ctx
			ctx.depsExt[Quests].registerReward("chain", function(_tx, player)
				ctx.deps[Quests].progress(player, "tutorial") -- from inside the claim tx
			end)
		end
		probePart.api = {
			buy = function(player)
				return probeCtx.tx(player, function(tx)
					probeCtx.section(tx).n += 1
					probeCtx.deps[Quests].progress(player, "jump", 10) -- inside the game's own tx
				end)
			end,
		}
		local c = cfg()
		c.quests.d3 = F.quest(
			"daily",
			{ F.counter("shop", 1) },
			{ weight = 2, reward = { F.custom("chain") } }
		)
		local h, p, q = K.boot({ quests = c, probes = { { ref = Probe, part = probePart } } })
		expect(h:use(Probe).buy(p)).toBe(true)
		expect(q.state(p, "d4").status).toBe("complete") -- live
		h:tick(1)
		q.progress(p, "shop")
		h:tick(1)
		expect(q.claim(p, "d3")).toBe(true) -- its handler progresses "tutorial" (oneTime "once")
		expect(q.state(p, "once").values).toEqual({ 1 })
		h:tick(1)
		expect(q.state(p, "once").status).toBe("complete")
		expect(h:warnings()).toEqual({})
	end)

	it("drops increments to the ended period's slot quests until the player's rotation", function()
		local h, p, q = K.boot({ quests = cfg() })
		local before = K.ids(q, p, "daily")
		h.clock += 86400 -- the clock jumps past midnight without a tick
		expect(q.progress(p, "jump", 1)).toBe(false) -- d4 belongs to yesterday's set
		expect(q.progress(p, "tutorial", 1)).toBe(true) -- other kinds are unaffected
		expect(K.ids(q, p, "daily")).toEqual(before) -- active() still shows the saved set
		h:tick(1) -- the rotation deals today's set
		local v = q.active(p)
		expect(v[1].periodId).toBe(19676)
		expect(q.progress(p, "jump", 1) or q.progress(p, "coin", 1) or q.progress(p, "crate", 1)).toBe(true)
	end)

	it("replicateSeconds > 1: each player's sends sit on its own staggered grid, R apart", function()
		local c = cfg({ replicateSeconds = 2 })
		c.quests.far = F.quest("oneTime", { F.counter("far", 1000) })
		local h, p1, q = K.boot({ quests = c })
		local p2 = h:addPlayer({ userId = 2 })
		local sent = { [p1] = {}, [p2] = {} }
		local tick = 0
		q.signals.Progressed:Connect(function(player, ids)
			if table.find(ids, "far") then
				table.insert(sent[player], tick)
			end
		end)
		for i = 1, 12 do
			tick = i
			q.progress(p1, "far", 1)
			q.progress(p2, "far", 1)
			h:tick(1)
		end
		for _, ticks in sent do
			expect(#ticks >= 5).toBe(true) -- about one send per 2 s while progressing
			for i = 2, #ticks do
				expect(ticks[i] - ticks[i - 1] >= 2).toBe(true) -- never closer than replicateSeconds
			end
		end
		-- past the first send the two players are on different phases: never the same tick
		for _, t1 in sent[p1] do
			if t1 > sent[p1][1] then
				expect(table.find(sent[p2], t1)).toBeNil()
			end
		end
		-- the replicated values still include every increment
		expect(State.prog(h:state(p1)).far[1] >= 11).toBe(true)
	end)

	it(
		"extra.prog is one string per send; extra.progIds keeps its wire copy while the set is unchanged",
		function()
			local c = cfg()
			c.quests.far = F.quest("oneTime", { F.counter("far", 1000) })
			c.quests.near = F.quest("oneTime", { F.counter("near", 1000), F.counter("far", 1000) })
			local h, p, q = K.boot({ quests = c })
			local sends = 0
			q.signals.Progressed:Connect(function()
				sends += 1
			end)
			q.progress(p, "far", 1)
			q.progress(p, "near", 1)
			h:tick(1)
			local first = h:state(p).modules.Quests.extra
			local firstIds, firstText = first.progIds, first.prog
			q.progress(p, "far", 1)
			h:tick(1)
			local second = h:state(p).modules.Quests.extra
			expect(second.progIds).toBe(firstIds) -- the same copy: charm-sync's diff skips it
			expect(type(second.prog)).toBe("string")
			expect(second.prog).Not.toBe(firstText)
			local i = table.find(second.progIds, "near")
			expect(string.split(second.prog, ";")[i]).toBe("1,2")
			expect(State.prog(h:state(p)).far).toEqual({ 2 })
			expect(State.prog(h:state(p)).near).toEqual({ 1, 2 })
			expect(sends).toBe(2)
			h:tick(1) -- nothing moved: nothing new is sent
			expect(sends).toBe(2)
			expect(h:state(p).modules.Quests.extra.prog).toBe(second.prog)
		end
	)

	it("several quests on one key: each is clamped at its own target, the first completes on time", function()
		local c = cfg()
		c.quests.short = F.quest("oneTime", { F.counter("dig", 3) })
		c.quests.long = F.quest("oneTime", { F.counter("dig", 10) })
		local h, p, q = K.boot({ quests = c })
		local completed, progressed = {}, {}
		q.signals.Completed:Connect(function(_, id)
			table.insert(completed, id)
		end)
		q.signals.Progressed:Connect(function(player, ids)
			for _, id in ids do
				table.insert(progressed, id .. "=" .. table.concat(q.state(player, id).values, ","))
			end
		end)
		q.progress(p, "dig", 1)
		q.progress(p, "dig", 1)
		expect(q.state(p, "short").values).toEqual({ 2 }) -- a read in between sees every increment
		q.progress(p, "dig", 4)
		expect(q.state(p, "short").values).toEqual({ 3 })
		expect(q.state(p, "short").status).toBe("complete")
		expect(q.state(p, "long").values).toEqual({ 6 })
		h:tick(1)
		expect(completed).toEqual({ "short" })
		table.sort(progressed)
		expect(progressed).toEqual({ "long=6", "short=3" }) -- once each, after the fold
		for _ = 1, 3 do
			q.progress(p, "dig", 1)
		end
		h:tick(1)
		expect(State.prog(h:state(p)).long).toEqual({ 9 })
		expect(q.progress(p, "dig", 5)).toBe(true)
		expect(q.state(p, "long").values).toEqual({ 10 })
		h:tick(1)
		expect(completed).toEqual({ "short", "long" })
		expect(q.progress(p, "dig", 1)).toBe(false)
		h:removePlayer(p) -- the final save has the folded values
		expect(K.section(h, p).prog.long.n).toEqual({ 10 })
	end)

	it("an amount accumulated before midnight counts for the ended day's quest, not the new one", function()
		local h, p, q = K.boot({ quests = cfg() })
		expect(q.progress(p, "jump", 2)).toBe(true)
		expect(q.progress(p, "jump", 1)).toBe(true)
		h.clock += 86400 -- the clock jumps past midnight without a tick
		expect(q.progress(p, "jump", 1)).toBe(false) -- d4 belongs to yesterday's set
		expect(q.state(p, "d4").values).toEqual({ 3 })
	end)
end)
