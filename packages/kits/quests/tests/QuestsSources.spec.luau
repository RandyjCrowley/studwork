--!nocheck
--[[
	Quests sources (docs/framework/kits/quests.md, "Built-in sources", registerSource): every
	built-in with its module (and the boot error naming the quest and the module without it),
	registered value sources with and without a `changed` signal (polled every sourcePollSeconds),
	and quest rewards never feeding quests.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local K = require("packages/kits/quests/tests/QuestsKit.luau")
local F = K.F
local Quests = K.Quests
local Economy = K.ref("Economy")
local Items = K.ref("Items")
local Inventory = K.ref("Inventory")
local Rarity = K.ref("Rarity")
local Rebirth = K.ref("Rebirth")
local Streak = K.ref("Streak")
local Leaderboards = K.ref("Leaderboards")

-- one oneTime quest per objective, so it is active at once
local function oneQuest(objective, extra)
	local quests = { probe = F.quest("oneTime", { objective }, extra) }
	return {
		daily = { count = 0, rerollsPerSlot = 0 },
		weekly = { count = 0, rerollsPerSlot = 0 },
		quests = quests,
	}
end

local function bootWith(objective, modules, config, extra)
	return K.boot({
		quests = oneQuest(objective, extra and extra.quest),
		modules = modules,
		items = F.items(),
		config = config or {},
		services = extra and extra.services,
	})
end

local function values(q, p)
	return q.state(p, "probe").values
end

describe("Quests built-in sources", function()
	it("currencyEarned: positive deltas in the currency, except quest rewards", function()
		local c = oneQuest(F.source("currencyEarned", 100))
		c.quests.paid = F.quest("oneTime", { F.counter("pay", 1) }, { reward = { F.currency(500) } })
		c.quests.gems = F.quest("oneTime", { F.source("currencyEarned", 5, { currency = "Gems" }) })
		local h, p, q = K.boot({
			quests = c,
			modules = { Economy },
			config = { Economy = { primaryCurrency = "Coins", currencies = { "Gems" } } },
		})
		local econ = h:use(Economy)
		econ.grant(p, 40, "pickup")
		econ.spend(p, 10, "shop") -- negative: not counted
		econ.grant(p, 3, "pickup", "Gems")
		expect(values(q, p)).toEqual({ 40 })
		expect(q.state(p, "gems").values).toEqual({ 3 })
		q.progress(p, "pay")
		expect(q.claim(p, "paid")).toBe(true) -- +500 "Quests:paid"
		expect(values(q, p)).toEqual({ 40 })
		econ.grant(p, 100, "pickup")
		expect(values(q, p)).toEqual({ 100 }) -- capped at the target
		h:tick(1)
		expect(q.state(p, "probe").status).toBe("complete")
	end)

	it("itemCollected: one per copy matching item and rarity, except quest rewards", function()
		local c = oneQuest(F.source("itemCollected", 2, { rarity = "Rare" }))
		c.quests.coins = F.quest("oneTime", { F.source("itemCollected", 5, { item = "coin" }) })
		c.quests.gift = F.quest("oneTime", { F.counter("pay", 1) }, { reward = { F.item("star", 2) } })
		local h, p, q = K.boot({
			quests = c,
			modules = { Items, Inventory },
			items = F.items(),
		})
		local inv = h:use(Inventory)
		inv.add(p, "coin")
		inv.add(p, "coin")
		inv.add(p, "star")
		expect(values(q, p)).toEqual({ 1 })
		expect(q.state(p, "coins").values).toEqual({ 2 })
		q.progress(p, "pay")
		expect(q.claim(p, "gift")).toBe(true) -- two stars with source "Quests:gift"
		expect(values(q, p)).toEqual({ 1 })
	end)

	it("rebirthDone and rebirths: Rebirthed adds one and re-reads the count", function()
		local c = oneQuest(F.source("rebirthDone", 2))
		c.quests.reborn = F.quest("oneTime", { F.threshold("rebirths", 1) })
		local h, p, q = K.boot({
			quests = c,
			modules = { Economy, Rebirth },
			config = { Economy = F.economy(), Rebirth = { rebirth = { baseCost = 10, costGrowth = 1 } } },
		})
		h:use(Economy).grant(p, 10, "pickup")
		expect(h:use(Rebirth).rebirth(p)).toBe(true)
		expect(values(q, p)).toEqual({ 1 })
		expect(q.state(p, "reborn").values).toEqual({ 1 })
		h:tick(1)
		expect(q.state(p, "reborn").status).toBe("complete")
		expect(q.state(p, "probe").status).toBe("active")
	end)

	it("currency: a value source re-read on CurrencyChanged", function()
		local h, p, q = bootWith(F.threshold("currency", 50), { Economy }, { Economy = F.economy() })
		expect(values(q, p)).toEqual({ 0 })
		h:use(Economy).grant(p, 30, "pickup")
		expect(values(q, p)).toEqual({ 30 })
		h:use(Economy).spend(p, 10, "shop")
		expect(values(q, p)).toEqual({ 20 })
		h:use(Economy).grant(p, 40, "pickup")
		h:tick(1)
		expect(q.state(p, "probe").status).toBe("complete")
	end)

	it("itemOwned: copies of the item, re-read on ItemAdded / ItemRemoved", function()
		local h, p, q = bootWith(F.threshold("itemOwned", 2, { item = "gem" }), { Items, Inventory })
		local inv = h:use(Inventory)
		local first = inv.add(p, "gem")
		inv.add(p, "coin")
		expect(values(q, p)).toEqual({ 1 })
		inv.remove(p, first.uid)
		expect(values(q, p)).toEqual({ 0 })
		inv.add(p, "gem")
		inv.add(p, "gem")
		h:tick(1)
		expect(q.state(p, "probe").status).toBe("complete")
	end)

	it("streakDay: the streak's day, read at the deal and on StreakAdvanced", function()
		local h, p, q = bootWith(F.threshold("streakDay", 1), { Streak })
		h:tick(1)
		expect(q.state(p, "probe").status).toBe("complete") -- day 1 on the first join
	end)

	it("leaderboardRank: done at rank <= target, re-read on BoardRefreshed", function()
		local c = oneQuest(F.threshold("leaderboardRank", 1, { board = "best" }))
		c.sourcePollSeconds = 60 -- outlasts the ticks below: only BoardRefreshed can re-read the rank
		local h, p, q = K.boot({
			quests = c,
			modules = { Leaderboards },
			items = F.items(),
			config = { Leaderboards = { refreshSeconds = 10, writeSeconds = 5, boards = { best = {} } } },
			services = { UserService = StudWork.test.fakes.userService() },
		})
		expect(values(q, p)).toEqual({ 0 }) -- not ranked = not done
		h:use(Leaderboards).submit(p, "best", 10)
		h:tick(40)
		expect(values(q, p)).toEqual({ 1 })
		expect(q.state(p, "probe").status).toBe("complete")
	end)

	it(
		"a built-in source whose module isn't enabled is a boot error naming the quest and the module",
		function()
			local cases = {
				{ F.source("currencyEarned", 1), "Economy" },
				{ F.source("itemCollected", 1), "Inventory" },
				{ F.source("rebirthDone", 1), "Rebirth" },
				{ F.threshold("currency", 1), "Economy" },
				{ F.threshold("rebirths", 1), "Rebirth" },
				{ F.threshold("streakDay", 1), "Streak" },
				{ F.threshold("itemOwned", 1, { item = "gem" }), "Inventory" },
				{ F.threshold("leaderboardRank", 1, { board = "best" }), "Leaderboards" },
			}
			for _, case in cases do
				local h, err =
					StudWork.test.boot({ modules = { Quests }, config = { Quests = oneQuest(case[1]) } })
				expect(h).toBe(nil)
				expect(string.find(err, "quest 'probe'", 1, true) ~= nil).toBe(true)
				expect(string.find(err, "needs " .. case[2], 1, true) ~= nil).toBe(true)
			end
		end
	)
end)

describe("Quests registered value sources", function()
	it("re-reads a source with a changed signal when it fires", function()
		local source = F.valueSource({ name = "power" })
		local h, p, q = K.boot({ quests = oneQuest(F.threshold("power", 5)), probes = { source } })
		expect(values(q, p)).toEqual({ 0 })
		source:set(p, 3)
		expect(values(q, p)).toEqual({ 3 })
		source:set(p, 9)
		h:tick(1)
		expect(q.state(p, "probe").status).toBe("complete")
		local reads = source.reads
		h:tick(30)
		expect(source.reads).toBe(reads) -- complete: no more reads, and never polled
	end)

	it(
		"polls a source without changed every sourcePollSeconds, only for players with an active objective",
		function()
			local source = F.valueSource({ name = "level", changed = false })
			local c = oneQuest(F.threshold("level", 5))
			c.sourcePollSeconds = 5
			local h, p, q = K.boot({ quests = c, probes = { source } })
			local other = h:addPlayer({ userId = 2 })
			source.values[p] = 2
			local before = source.reads
			h:tick(10)
			expect(source.reads - before >= 2 * 2).toBe(true) -- both players, twice
			expect(source.reads - before <= 3 * 2).toBe(true)
			expect(values(q, p)).toEqual({ 2 })
			source.values[p] = 5
			h:tick(6)
			h:tick(1)
			expect(q.state(p, "probe").status).toBe("complete")
			local _ = other
		end
	)

	it("a read that errors counts as no value and never breaks the tick", function()
		local probe = StudWork.defineModule({
			name = "BadSource",
			version = "1.0.0",
			framework = "^1.7.0",
			optional = { Quests },
		})
		local part = {
			init = function(ctx)
				ctx.depsExt[Quests].registerSource("broken", {
					read = function()
						error("boom")
					end,
				})
			end,
		}
		local h, p, q =
			K.boot({ quests = oneQuest(F.threshold("broken", 1)), probes = { { ref = probe, part = part } } })
		h:tick(12)
		expect(values(q, p)).toEqual({ 0 })
		expect(q.progress(p, "nothing")).toBe(false)
	end)

	it("needs Rarity for nothing: a roll reward table is checked at boot only", function()
		local h = StudWork.test.boot({
			modules = { Quests, Items, Inventory, Rarity },
			items = F.items(),
			config = {
				Quests = oneQuest(F.counter("x", 1), { reward = { F.roll("FreeCrate") } }),
				Rarity = F.rarity(),
			},
		})
		expect(h ~= nil).toBe(true)
	end)
end)
