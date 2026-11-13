--!nocheck
--[[
	Quests rerolls (docs/framework/kits/quests.md, "Rerolls"): the free count per slot and period,
	the n-th reroll's result as a pure function of (user, period, slot, n), the `seen` snapshot (a
	rerolled-away quest never comes back; requirements changed after the deal don't change the
	pool), slot_done, pool_empty, and a crash rollback that can't give another result.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Deal = require(ReplicatedStorage.Modules.Quests.shared.Deal)
local K = require("packages/kits/quests/tests/QuestsKit.luau")
local F = K.F
local Quests = K.Quests
local Items = K.ref("Items")
local Inventory = K.ref("Inventory")

local DAY = 19675

local function cfg(rerolls, extra)
	local c = F.questsConfig({ daily = { count = 3, rerollsPerSlot = rerolls } })
	for k, v in extra or {} do
		c[k] = v
	end
	return c
end

local function weights(q, ids)
	local w = {}
	for _, id in ids do
		w[id] = q.def(id).weight
	end
	return w
end

describe("Quests rerolls", function()
	it("allows rerollsPerSlot free rerolls per slot per period", function()
		local h, p, q = K.boot({ quests = cfg(1) })
		local before = K.ids(q, p, "daily") -- d3, d1, d4
		local ok, id = q.reroll(p, "daily", 1)
		expect(ok).toBe(true)
		expect(id).toBe("d2") -- the only id left in the snapshot
		expect(K.ids(q, p, "daily")).toEqual({ "d2", before[2], before[3] })
		expect(select(2, q.reroll(p, "daily", 1))).toBe("no_rerolls")
		expect(q.active(p)[1].rerollsLeft).toBe(0)
		expect(q.active(p)[2].rerollsLeft).toBe(1)
		h:removePlayer(p)
		local s = K.section(h, p)
		expect(s.day.slots[1]).toEqual({ q = "d2", n = { 0 }, s = 0, r = 1 })
		expect(s.day.seen.d3).toBe(true) -- rerolled away: never offered again this period
	end)

	it("refuses bad kinds, bad slots, zero rerolls, a done slot and an empty pool", function()
		local _, p, q = K.boot({ quests = cfg(1) })
		expect(select(2, q.reroll(p, "monthly", 1))).toBe("bad_kind")
		expect(select(2, q.reroll(p, "daily", 0))).toBe("bad_slot")
		expect(select(2, q.reroll(p, "daily", 4))).toBe("bad_slot")
		expect(select(2, q.reroll(p, "daily", 1.5))).toBe("bad_slot")
		expect(select(2, q.reroll(p, "weekly", 1))).toBe("no_rerolls") -- weekly rerollsPerSlot = 0
		q.progress(p, "jump", 10) -- d4 (slot 3) complete, still pending
		expect(select(2, q.reroll(p, "daily", 3))).toBe("slot_done")
		expect(q.claim(p, "d4")).toBe(true)
		expect(select(2, q.reroll(p, "daily", 3))).toBe("slot_done")
		expect(q.reroll(p, "daily", 1)).toBe(true) -- takes d2, the last unseen id
		expect(select(2, q.reroll(p, "daily", 2))).toBe("pool_empty")
	end)

	it("the n-th reroll is a function of (user, period, slot, n) over the seen snapshot", function()
		local c = cfg(3)
		for i = 5, 9 do
			c.quests["d" .. i] = F.quest("daily", { F.counter("k" .. i, 2) }, { weight = i - 3 })
		end
		local function run(userId)
			local _, p, q = K.boot({ quests = c, userId = userId })
			local got = { K.ids(q, p, "daily")[2] }
			for _ = 1, 3 do
				local ok, id = q.reroll(p, "daily", 2)
				expect(ok).toBe(true)
				expect(table.find(got, id)).toBe(nil) -- never a quest already shown
				table.insert(got, id)
			end
			return got
		end
		local a = run(7)
		local b = run(7)
		expect(a).toEqual(b)
		-- and it matches the page's formula for the first reroll
		local h, p, q = K.boot({ quests = c, userId = 7 })
		h:removePlayer(p)
		local s = K.section(h, p)
		local unseen = {}
		for id, shown in s.day.seen do
			if not shown then
				table.insert(unseen, id)
			end
		end
		table.sort(unseen)
		local expected = Deal.pick(unseen, weights(q, unseen), Deal.seed(7, "daily", DAY, 1, 2, 1))
		expect(a[2]).toBe(expected)
	end)

	it("a crash rollback can't give a different result or a free extra reroll", function()
		local store = StudWork.test.memoryStore()
		local a = K.harness({ quests = cfg(1), store = store })
		local pa = a:addPlayer({ userId = 5 })
		a:removePlayer(pa) -- the deal is saved
		local b = K.harness({ quests = cfg(1), store = store })
		local pb = b:addPlayer({ userId = 5 })
		local _, first = b:use(Quests).reroll(pb, "daily", 2) -- then b crashes (never saves)
		local c = K.harness({ quests = cfg(1), store = store })
		local pc = c:addPlayer({ userId = 5 })
		local qc = c:use(Quests)
		local _, again = qc.reroll(pc, "daily", 2)
		expect(again).toBe(first)
		c:removePlayer(pc)
		local d = K.harness({ quests = cfg(1), store = store })
		local pd = d:addPlayer({ userId = 5 })
		expect(select(2, d:use(Quests).reroll(pd, "daily", 2))).toBe("no_rerolls")
	end)

	it("rerolls through the action with the client's slot checked against count", function()
		local h, p = K.boot({ quests = cfg(1) })
		local _, ok = h:action(p, Quests, "rerollQuest", "daily", 1)
		expect(ok).toBe(true)
		local _, refused = h:action(p, Quests, "rerollQuest", "daily", 9)
		expect(refused).toBe(false)
	end)

	it("draws from the pool snapshotted at the deal: later requirement changes don't steer it", function()
		local c = {
			daily = { count = 1, rerollsPerSlot = 3 },
			weekly = { count = 0, rerollsPerSlot = 0 },
			quests = {
				a = F.quest("daily", { F.counter("a", 1) }),
				b = F.quest("daily", { F.counter("b", 1) }),
				gemQuest = F.quest("daily", { F.counter("g", 1) }, { requires = { items = { "gem" } } }),
				starQuest = F.quest("daily", { F.counter("s", 1) }, { requires = { items = { "star" } } }),
			},
		}
		local h, p, q = K.boot({
			quests = c,
			modules = { Items, Inventory },
			items = F.items(),
			userId = 9,
		})
		local inv = h:use(Inventory)
		inv.add(p, "gem")
		h.clock += 86400
		h:tick(1) -- today's deal sees the gem
		inv.remove(p, inv.list(p)[1].uid) -- sold after the deal
		inv.add(p, "star") -- acquired after the deal
		local seen = { [K.ids(q, p, "daily")[1]] = true }
		for _ = 1, 2 do
			local ok, id = q.reroll(p, "daily", 1)
			expect(ok).toBe(true)
			seen[id] = true
		end
		expect(seen).toEqual({ a = true, b = true, gemQuest = true })
		expect(select(2, q.reroll(p, "daily", 1))).toBe("pool_empty") -- starQuest wasn't eligible at the deal
	end)
end)
