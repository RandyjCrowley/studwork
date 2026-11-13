--!nocheck
--[[
	Quests quick start (docs/framework/kits/quests.md, "Quick start"): the page's config with
	Economy, a counter progressed by the server, the claim granting the currency reward once, and a
	currencyEarned source fed by game income but not by the quest's own reward.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local F = require("packages/kits/quests/tests/Fixtures.luau")

local Quests = F.Quests
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local State = require(Modules:WaitForChild("Quests"):WaitForChild("client"):WaitForChild("State"))

local function pageConfig()
	return {
		daily = { count = 3, rerollsPerSlot = 1 },
		quests = {
			collectCoins = {
				kind = "daily",
				objectives = { { kind = "source", source = "currencyEarned", target = 250 } },
				reward = { { kind = "currency", amount = 100 } },
			},
			openCrates = {
				kind = "daily",
				objectives = { { kind = "counter", key = "crateOpened", target = 3 } },
				reward = { { kind = "currency", amount = 150 } },
			},
			visitShop = {
				kind = "daily",
				weight = 2,
				objectives = { { kind = "counter", key = "shopVisit", target = 1 } },
				reward = { { kind = "currency", amount = 50 } },
			},
		},
	}
end

local function boot()
	local h = StudWork.test.harness({
		modules = { Economy, Quests },
		config = { Quests = pageConfig(), Economy = F.economy() },
	})
	local p = h:addPlayer({ userId = 1 })
	return h, p, h:use(Quests), h:use(Economy)
end

describe("Quests quick start", function()
	it("deals the three daily quests and claims a counter quest exactly once", function()
		local h, p, q, econ = boot()
		local ids = {}
		for _, v in q.active(p) do
			table.insert(ids, v.id)
			expect(v.kind).toBe("daily")
			expect(v.status).toBe("active")
		end
		table.sort(ids)
		expect(ids).toEqual({ "collectCoins", "openCrates", "visitShop" })

		expect(q.progress(p, "crateOpened")).toBe(true)
		expect(select(2, q.claim(p, "openCrates"))).toBe("not_complete")
		q.progress(p, "crateOpened")
		q.progress(p, "crateOpened")
		expect(q.progress(p, "crateOpened")).toBe(false) -- capped at the target
		expect(q.state(p, "openCrates").status).toBe("complete")

		local ok, reason = q.claim(p, "openCrates")
		expect(ok).toBe(true)
		expect(reason).toBe(nil)
		expect(econ.balance(p)).toBe(150)
		expect(select(2, q.claim(p, "openCrates"))).toBe("claimed")
		expect(econ.balance(p)).toBe(150)
		expect(q.state(p, "openCrates").status).toBe("claimed")
		expect(h:warnings()).toEqual({})
	end)

	it("the board's Claim button takes the same path through the action", function()
		local h, p, q, econ = boot()
		q.progress(p, "shopVisit")
		h:tick(1)
		local ok, claimed = h:action(p, Quests, "claimQuest", "visitShop")
		expect(ok).toBe(true)
		expect(claimed).toBe(true)
		expect(econ.balance(p)).toBe(50)
		local _, again = h:action(p, Quests, "claimQuest", "visitShop")
		expect(again).toBe(false)
		expect(econ.balance(p)).toBe(50)
	end)

	it("currencyEarned counts income but not the quest's own reward", function()
		local h, p, q, econ = boot()
		econ.grant(p, 200, "pickup")
		h:tick(1)
		expect(q.state(p, "collectCoins").values).toEqual({ 200 })
		q.progress(p, "shopVisit")
		q.claim(p, "visitShop") -- +50 "Quests:visitShop": not counted
		h:tick(1)
		expect(q.state(p, "collectCoins").values).toEqual({ 200 })
		econ.grant(p, 60, "pickup")
		h:tick(1)
		expect(q.state(p, "collectCoins").status).toBe("complete")
		expect(q.claim(p, "collectCoins")).toBe(true)
		expect(econ.balance(p)).toBe(200 + 50 + 60 + 100)
	end)

	it("replicates the board and the live values to the player only", function()
		local h, p, q = boot()
		q.progress(p, "crateOpened", 2)
		h:tick(1)
		local extra = h:state(p).modules.Quests.extra
		expect(#extra.board.day.slots).toBe(3)
		expect(State.prog(h:state(p)).openCrates).toEqual({ 2 })
		expect(extra.questOdds).toEqual({})
	end)

	it("its flag switches the whole module live: off = an empty board and nothing written", function()
		local cs = StudWork.test.fakes.configService({ values = {} })
		local cfg = pageConfig()
		cfg.flag = "questsOn"
		local h = StudWork.test.harness({
			modules = { Economy, Quests },
			config = { Quests = cfg, Economy = F.economy() },
			flags = { questsOn = { default = false } },
			flagOverride = { enabled = true, refreshSeconds = 5 },
			services = { ConfigService = cs },
		})
		local p = h:addPlayer({ userId = 1 })
		local q = h:use(Quests)
		h:tick(1)
		expect(h:state(p).modules.Quests.extra.board).toEqual({})
		expect(#q.active(p)).toBe(0)
		expect(q.progress(p, "crateOpened")).toBe(false)
		cs.set("flag_questsOn", true)
		cs.publish()
		h:tick(7) -- the override applies, then the load tx (pruning + the deal) runs on the next tick
		expect(#q.active(p)).toBe(3)
		expect(#h:state(p).modules.Quests.extra.board.day.slots).toBe(3)
		expect(q.progress(p, "crateOpened")).toBe(true)
		cs.set("flag_questsOn", false)
		cs.publish()
		h:tick(7)
		expect(h:state(p).modules.Quests.extra.board).toEqual({})
		expect(select(2, q.claim(p, "openCrates"))).toBe("disabled")
		expect(h:warnings()).toEqual({})
	end)
end)
