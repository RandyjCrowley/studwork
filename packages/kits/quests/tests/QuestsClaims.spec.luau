--!nocheck
--[[
	Quests claims (docs/framework/kits/quests.md, "Claims: exactly once"): the claim record and every
	reward in one tx; every row of the exactly-once table that a single harness can show (the
	multi-server rows also run in QuestsClaimSim); every reason; waiting quests; the same id
	current and waiting claimed in order once each; chains; repeatable caps; inventory_full writing
	nothing; refusals logging nothing; a custom handler error discarding the claim.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local K = require("packages/kits/quests/tests/QuestsKit.luau")
local F = K.F
local Quests = K.Quests
local Economy = K.ref("Economy")
local Items = K.ref("Items")
local Inventory = K.ref("Inventory")

local function econCfg(quests)
	return {
		quests = quests,
		modules = { Economy },
		config = { Economy = F.economy() },
	}
end

-- daily pool == count, so the same ids are dealt every day
local function twoDailies(extra)
	local c = {
		daily = { count = 2, rerollsPerSlot = 0 },
		weekly = { count = 0, rerollsPerSlot = 0 },
		quests = {
			d1 = F.quest("daily", { F.counter("coin", 2) }, { reward = { F.currency(10) } }),
			d2 = F.quest("daily", { F.counter("gem", 1) }, { reward = { F.currency(1) } }),
		},
	}
	for k, v in extra or {} do
		c[k] = v
	end
	return c
end

local function nextDay(h)
	h.clock += 86400
	h:tick(1)
end

describe("Quests claims: exactly once", function()
	it("a double-tapped Claim (two actions in one frame) grants once", function()
		local h, p, q = K.boot(econCfg(twoDailies()))
		q.progress(p, "coin", 2)
		local _, first = h:action(p, Quests, "claimQuest", "d1")
		local _, second = h:action(p, Quests, "claimQuest", "d1")
		expect(first).toBe(true)
		expect(second).toBe(false)
		expect(h:use(Economy).balance(p)).toBe(10)
		expect(select(2, q.claim(p, "d1"))).toBe("claimed")
	end)

	it("rejoin on another server: the save carries the claim record with the grant", function()
		local store = StudWork.test.memoryStore()
		local o = econCfg(twoDailies())
		o.store = store
		local a, p, q = K.boot(o)
		q.progress(p, "coin", 2)
		expect(q.claim(p, "d1")).toBe(true)
		a:removePlayer(p)
		local b, p2, q2 = K.boot(o)
		expect(select(2, q2.claim(p2, "d1"))).toBe("claimed")
		expect(b:use(Economy).balance(p2)).toBe(10)
	end)

	it("shutdown right after a claim saves the claim and the grant together", function()
		local store = StudWork.test.memoryStore()
		local o = econCfg(twoDailies())
		o.store = store
		local a, p, q = K.boot(o)
		q.progress(p, "coin", 2)
		expect(q.claim(p, "d1")).toBe(true)
		a:shutdown()
		local saved = a:saved(p)
		expect(saved.economy.currency.Coins).toBe(10)
		for _, slot in saved.quests.day.slots do
			if slot.q == "d1" then
				expect(slot.s).toBe(2)
			end
		end
	end)

	it("a crash after the claim loses both: the quest is claimable once again", function()
		local store = StudWork.test.memoryStore()
		local o = econCfg(twoDailies())
		o.store = store
		local a, p, q = K.boot(o)
		q.progress(p, "coin", 2)
		a:tick(1)
		a:removePlayer(p) -- saved complete, unclaimed
		local b, pb, qb = K.boot(o)
		expect(qb.claim(pb, "d1")).toBe(true) -- then b "crashes": it never saves
		expect(b:use(Economy).balance(pb)).toBe(10)
		local c, pc, qc = K.boot(o)
		expect(qc.state(pc, "d1").status).toBe("complete")
		expect(qc.claim(pc, "d1")).toBe(true)
		expect(select(2, qc.claim(pc, "d1"))).toBe("claimed")
		expect(c:use(Economy).balance(pc)).toBe(10)
	end)

	it("a save failure keeps the claim and the grant together (both saved or neither)", function()
		local store = StudWork.test.memoryStore()
		local o = econCfg(twoDailies())
		o.store = store
		local a, p, q = K.boot(o)
		q.progress(p, "coin", 2)
		expect(q.claim(p, "d1")).toBe(true)
		store.failNext(1)
		pcall(a.removePlayer, a, p)
		local saved = a:saved(p) -- the last save that went through
		if saved ~= nil and saved.quests ~= nil then
			local claimed = false
			for _, slot in saved.quests.day.slots do
				if slot.q == "d1" and slot.s == 2 then
					claimed = true
				end
			end
			local coins = saved.economy and saved.economy.currency.Coins or 0
			expect(claimed).toBe(coins == 10)
		end
	end)
end)

describe("Quests claim reasons", function()
	it("refuses with every documented reason and logs nothing", function()
		local h, p, q = K.boot(econCfg(F.questsConfig()))
		local stranger = StudWork.test.player(404)
		expect(select(2, q.claim(stranger, "d1"))).toBe("not_loaded")
		expect(select(2, q.claim(p, "nope"))).toBe("unknown_quest")
		expect(select(2, q.claim(p, "d2"))).toBe("not_active") -- not dealt to user 1
		expect(select(2, q.claim(p, "s2"))).toBe("not_active") -- a later chain step
		expect(select(2, q.claim(p, "gift"))).toBe("not_active") -- not granted
		expect(select(2, q.claim(p, "ev"))).toBe("not_active") -- outside its window
		expect(select(2, q.claim(p, "d1"))).toBe("not_complete")
		q.progress(p, "tutorial")
		expect(q.claim(p, "once")).toBe(true)
		expect(select(2, q.claim(p, "once"))).toBe("claimed")
		expect(h:warnings()).toEqual({})
		for _, line in h.logs do
			expect(string.find(line.msg, "Quests", 1, true)).toBe(nil)
		end
	end)

	it("a currency reward the economy refuses is reward_failed and writes nothing", function()
		local c = twoDailies()
		c.quests.d1.reward = { F.currency(10, "Gems") } -- not a currency of this game
		local h, p, q = K.boot(econCfg(c))
		q.progress(p, "coin", 2)
		expect(select(2, q.claim(p, "d1"))).toBe("reward_failed")
		expect(q.state(p, "d1").status).toBe("complete")
		expect(h:use(Economy).balance(p)).toBe(0)
	end)
end)

describe("Quests waiting and repeat claims", function()
	it(
		"moves an unclaimed complete daily to waiting at the deal; claims current then waiting, once each",
		function()
			local h, p, q = K.boot(econCfg(twoDailies()))
			local claimed = {}
			q.signals.Claimed:Connect(function(_, id, rewards)
				table.insert(claimed, id .. ":" .. rewards[1].amount)
			end)
			q.progress(p, "coin", 2)
			h:tick(1)
			nextDay(h) -- yesterday's complete d1 -> waiting; today's d1 dealt again
			local waiting = {}
			for _, v in q.active(p) do
				if v.waiting then
					table.insert(waiting, v.id .. "@" .. v.periodId)
				end
			end
			expect(waiting).toEqual({ "d1@19675" })
			expect(q.state(p, "d1").status).toBe("active") -- the current instance
			-- current not complete: the waiting instance is claimed
			expect(q.claim(p, "d1")).toBe(true)
			expect(select(2, q.claim(p, "d1"))).toBe("not_complete")
			q.progress(p, "coin", 2)
			expect(q.claim(p, "d1")).toBe(true) -- today's
			expect(select(2, q.claim(p, "d1"))).toBe("claimed")
			expect(h:use(Economy).balance(p)).toBe(20)
			expect(claimed).toEqual({ "d1:10", "d1:10" })
		end
	)

	it("with both complete, claims the current instance first, then the waiting one", function()
		local h, p, q = K.boot(econCfg(twoDailies()))
		q.progress(p, "coin", 2)
		h:tick(1)
		nextDay(h)
		q.progress(p, "coin", 2)
		h:tick(1)
		expect(q.claim(p, "d1")).toBe(true)
		expect(q.state(p, "d1").status).toBe("claimed")
		expect(#K.ids(q, p, "daily")).toBe(3) -- d1 (claimed), d2, waiting d1
		expect(q.claim(p, "d1")).toBe(true)
		expect(select(2, q.claim(p, "d1"))).toBe("claimed")
		expect(h:use(Economy).balance(p)).toBe(20)
	end)

	it("keeps at most waitingMax waiting quests, oldest dropped first", function()
		local h, p, q = K.boot(econCfg(twoDailies({ waitingMax = 2 })))
		for _ = 1, 3 do
			q.progress(p, "coin", 2)
			q.progress(p, "gem", 1)
			h:tick(1)
			nextDay(h)
		end
		local waiting = {}
		for _, v in q.active(p) do
			if v.waiting then
				table.insert(waiting, v.id .. "@" .. v.periodId)
			end
		end
		table.sort(waiting)
		expect(waiting).toEqual({ "d1@19677", "d2@19677" })
	end)

	it("advances a chain in the claim tx and caps a repeatable per period", function()
		local h, p, q = K.boot(econCfg(F.questsConfig()))
		expect(q.state(p, "s2").status).toBe("locked")
		q.progress(p, "talk")
		expect(q.claim(p, "s1")).toBe(true)
		expect(q.state(p, "s1").status).toBe("claimed")
		expect(q.state(p, "s2").status).toBe("active")
		q.progress(p, "coin", 5)
		expect(q.claim(p, "rep")).toBe(true)
		expect(q.state(p, "rep").claims).toBe(1)
		expect(q.state(p, "rep").values).toEqual({ 0 })
		q.progress(p, "coin", 5)
		expect(q.claim(p, "rep")).toBe(true)
		expect(q.state(p, "rep").status).toBe("claimed")
		expect(q.progress(p, "coin", 5)).toBe(false) -- capped (d1 and s2 on "coin" are complete too)
		h:tick(1)
		expect(select(2, q.claim(p, "rep"))).toBe("cap_reached")
		nextDay(h)
		expect(q.state(p, "rep").status).toBe("active")
		expect(q.state(p, "rep").claims).toBe(0)
		h:removePlayer(p)
		expect(K.section(h, p).done.s1).toBeTruthy()
	end)
end)

describe("Quests claims that write nothing", function()
	it("inventory_full via count + n > cap: nothing granted, nothing recorded", function()
		local c = twoDailies()
		c.quests.d1.reward = { F.currency(10), F.item("gem", 2) }
		local h, p, q = K.boot({
			quests = c,
			modules = { Economy, Items, Inventory },
			items = F.items(),
			config = { Economy = F.economy(), Inventory = { inventory = { cap = 3 } } },
		})
		local inv = h:use(Inventory)
		inv.add(p, "coin")
		inv.add(p, "coin")
		q.progress(p, "coin", 2)
		expect(select(2, q.claim(p, "d1"))).toBe("inventory_full")
		expect(h:use(Economy).balance(p)).toBe(0)
		expect(inv.count(p)).toBe(2)
		expect(q.state(p, "d1").status).toBe("complete")
		local list = inv.list(p)
		inv.remove(p, list[1].uid)
		expect(q.claim(p, "d1")).toBe(true)
		expect(inv.count(p)).toBe(3)
		expect(h:use(Economy).balance(p)).toBe(10)
		for _, inst in inv.list(p) do
			if inst.itemId == "gem" then
				expect(inst.source).toBe("Quests:d1")
			end
		end
		expect(h:warnings()).toEqual({})
	end)

	it("a custom handler error discards the whole claim, logged once with the quest id", function()
		local rewards = F.rewardModule({ handler = "bad", fail = true })
		local c = twoDailies()
		c.quests.d1.reward = { F.currency(10), F.custom("bad") }
		local h, p, q = K.boot({
			quests = c,
			modules = { Economy },
			config = { Economy = F.economy() },
			probes = { rewards },
		})
		q.progress(p, "coin", 2)
		expect(select(2, q.claim(p, "d1"))).toBe("reward_failed")
		expect(#rewards.calls).toBe(1)
		expect(h:use(Economy).balance(p)).toBe(0)
		expect(q.state(p, "d1").status).toBe("complete")
		local warns = h:warnings()
		expect(#warns).toBe(1)
		expect(string.find(warns[1], "d1", 1, true) ~= nil).toBe(true)
		h:removePlayer(p)
		expect(h:saved(p).testrewards.got).toBe(0)
	end)

	it("a working custom handler writes its own section in the claim tx", function()
		local rewards = F.rewardModule({ handler = "badge" })
		local c = twoDailies()
		c.quests.d1.reward = { F.custom("badge", { tier = 2 }) }
		local h, p, q = K.boot({
			quests = c,
			modules = { Economy },
			config = { Economy = F.economy() },
			probes = { rewards },
		})
		q.progress(p, "coin", 2)
		expect(q.claim(p, "d1")).toBe(true)
		expect(rewards.calls[1].questId).toBe("d1")
		expect(rewards.calls[1].params.tier).toBe(2)
		h:removePlayer(p)
		expect(h:saved(p).testrewards.got).toBe(1)
		expect(h:saved(p).testrewards.last).toBe("d1")
	end)

	it("claim inside a game tx is the framework's nested-tx error (use tx.after)", function()
		local Probe = StudWork.defineModule({
			name = "NestProbe",
			version = "1.0.0",
			framework = "^1.7.0",
			optional = { Quests },
			data = { key = "nestprobe", version = 1, default = { n = 0 } },
		})
		local probeCtx
		local part = {
			init = function(ctx)
				probeCtx = ctx
			end,
			api = {
				nested = function(player)
					return pcall(probeCtx.tx, player, function(tx)
						probeCtx.section(tx).n += 1
						probeCtx.deps[Quests].claim(player, "d1")
					end)
				end,
				deferred = function(player)
					return probeCtx.tx(player, function(tx)
						tx.after(function()
							probeCtx.deps[Quests].claim(player, "d1")
						end)
					end)
				end,
			},
		}
		local h, p, q = K.boot(econCfg(twoDailies()))
		local _ = h
		local h2, p2, q2 = K.boot({
			quests = twoDailies(),
			modules = { Economy },
			config = { Economy = F.economy() },
			probes = { { ref = Probe, part = part } },
		})
		q2.progress(p2, "coin", 2)
		h2:tick(1)
		local ok = h2:use(Probe).nested(p2)
		expect(ok).toBe(false)
		expect(q2.state(p2, "d1").status).toBe("complete")
		expect(h2:use(Probe).deferred(p2)).toBe(true)
		expect(q2.state(p2, "d1").status).toBe("claimed")
		expect(q.state(p, "d1").status).toBe("active")
	end)
end)
