--!nocheck
-- Goals checks (docs/framework/kits/quests.md, Goals config `check`): each built-in value source
-- with its module (and a boot error without it), registered sources with and without `changed`
-- (polled every sourcePollSeconds, only while a goal needs them), and the Quests checks (complete,
-- claimed, objective n) against a stand-in Quests server part.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local G = require("packages/kits/quests/tests/GoalsHelpers.luau")
local F = G.F
local Goals, Economy, Quests = G.Goals, G.Economy, G.Quests
local Items = require(Modules:WaitForChild("Items"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Rebirth = require(Modules:WaitForChild("Rebirth"):WaitForChild("module"))
local Streak = require(Modules:WaitForChild("Streak"):WaitForChild("module"))

local function goal(id, check)
	return { id = id, check = check, funnel = "Step_" .. id }
end

describe("Goals sources", function()
	it("currency (Economy), with a params.currency", function()
		local h = G.boot({
			chain = { goal("coins", { source = "currency", atLeast = 30, params = { currency = "Coins" } }) },
		})
		local p = h:addPlayer({ userId = 1 })
		h:use(Economy).grant(p, 29, "test")
		h:tick(1)
		expect(h:use(Goals).current(p).id).toBe("coins")
		h:use(Economy).grant(p, 1, "test")
		h:tick(1)
		expect(h:use(Goals).current(p)).toBeNil()
	end)

	it("itemOwned (Inventory) counts copies of params.item; ItemAdded marks dirty", function()
		local h = G.boot({
			modules = { Items, Inventory, Goals },
			items = F.items(),
			chain = { goal("gems", { source = "itemOwned", atLeast = 2, params = { item = "gem" } }) },
		})
		local p = h:addPlayer({ userId = 2 })
		local inv = h:use(Inventory)
		inv.add(p, "gem")
		inv.add(p, "coin")
		h:tick(1)
		expect(h:use(Goals).current(p).id).toBe("gems")
		inv.add(p, "gem")
		h:tick(1)
		expect(h:use(Goals).current(p)).toBeNil()
	end)

	it("rebirths (Rebirth)", function()
		local h = G.boot({
			modules = { Economy, Rebirth, Goals },
			chain = { goal("reborn", { source = "rebirths", atLeast = 1 }) },
		})
		local p = h:addPlayer({ userId = 3 })
		h:use(Economy).grant(p, h:use(Rebirth).cost(p), "test")
		expect(h:use(Rebirth).rebirth(p)).toBe(true)
		h:tick(1)
		expect(h:use(Goals).current(p)).toBeNil()
	end)

	it("streakDay (Streak): checked on load", function()
		local h = G.boot({
			modules = { Streak, Goals },
			chain = { goal("daily", { source = "streakDay", atLeast = 1 }), goal("later", { call = true }) },
		})
		local p = h:addPlayer({ userId = 4 })
		h:tick(1)
		expect(h:use(Goals).current(p).id).toBe("later")
	end)

	it("a built-in source whose module is off is a boot error", function()
		local _, err = StudWork.test.boot({
			modules = { Goals },
			config = { Goals = { chain = { goal("coins", { source = "currency", atLeast = 1 }) } } },
		})
		expect(err).never.toBeNil()
		expect(string.find(tostring(err), "currency", 1, true) ~= nil).toBe(true)
	end)

	it("a registered source with `changed` is checked on the signal (next tick)", function()
		local source = F.valueSource({ goals = true, quests = false })
		local h =
			G.boot({ probes = { source }, chain = { goal("v", { source = "testValue", atLeast = 3 }) } })
		local p = h:addPlayer({ userId = 5 })
		h:tick(1)
		source:set(p, 3)
		expect(h:use(Goals).current(p).id).toBe("v")
		h:tick(1)
		expect(h:use(Goals).current(p)).toBeNil()
	end)

	it(
		"a registered source without `changed` is polled every sourcePollSeconds, only while needed",
		function()
			local source = F.valueSource({ goals = true, quests = false, changed = false })
			local h = G.boot({
				probes = { source },
				goals = { sourcePollSeconds = 5 },
				chain = { goal("v", { source = "testValue", atLeast = 3 }) },
			})
			local p = h:addPlayer({ userId = 6 })
			h:tick(1) -- the load check
			source.values[p] = 3
			local reads = source.reads
			h:tick(3)
			expect(source.reads).toBe(reads) -- between polls: no read
			expect(h:use(Goals).current(p).id).toBe("v")
			h:tick(2)
			expect(h:use(Goals).current(p)).toBeNil()
			local after = source.reads
			h:tick(20)
			expect(source.reads).toBe(after) -- done: no more polling
		end
	)

	it("registerSource: a built-in name or a second registration errors", function()
		local seen = {}
		local probe = {
			ref = StudWork.defineModule({
				name = "SourceProbe",
				version = "1.0.0",
				framework = "^1.7.0",
				optional = { Goals },
			}),
		}
		probe.part = {
			init = function(ctx)
				local ext = ctx.depsExt[Goals]
				seen.builtin = pcall(ext.registerSource, "currency", { read = function() end })
				ext.registerSource("mine", { read = function() end })
				seen.twice = pcall(ext.registerSource, "mine", { read = function() end })
				seen.noRead = pcall(ext.registerSource, "other", {})
			end,
		}
		G.boot({ probes = { probe }, chain = {} })
		expect(seen.builtin).toBe(false)
		expect(seen.twice).toBe(false)
		expect(seen.noRead).toBe(false)
	end)

	it(
		"Quests checks: complete, claimed and objective n (a Quests stand-in; Completed marks dirty)",
		function()
			local states = {
				q1 = { status = "active", values = { 0 } },
				q2 = { status = "complete", values = { 3 } },
				q3 = { status = "active", values = { 1 } },
			}
			local fake = G.fakeQuests(states)
			local h = G.boot({
				modules = { Quests, Goals },
				servers = { Quests = fake },
				chain = {
					goal("done1", { quest = "q1" }),
					goal("claim2", { quest = "q2", on = "claimed" }),
					goal("obj3", { quest = "q3", objective = 1 }),
				},
			})
			local p = h:addPlayer({ userId = 7 })
			h:tick(1)
			expect(h:use(Goals).current(p).id).toBe("done1")
			states.q1 = { status = "complete", values = { 3 } }
			fake.fired.Completed:Fire(p, "q1")
			h:tick(1)
			expect(h:use(Goals).current(p).id).toBe("claim2") -- complete isn't claimed
			states.q2 = { status = "claimed", values = { 3 } }
			states.q3 = { status = "active", values = { 3 } } -- objective 1 reached its target (3)
			fake.fired.Claimed:Fire(p, "q2", {})
			h:tick(1)
			expect(h:use(Goals).current(p)).toBeNil()
			expect(G.funnels(h, p)).toEqual({ "Step_done1", "Step_claim2", "Step_obj3" })
		end
	)

	it(
		"a leaderboardRank objective is done at rank <= target (lower is better), not rank >= target",
		function()
			local rank = { kind = "threshold", source = "leaderboardRank", target = 10 }
			local states = { q1 = { status = "active", values = { 50 }, objective = rank } }
			local fake = G.fakeQuests(states)
			local h = G.boot({
				modules = { Quests, Goals },
				servers = { Quests = fake },
				chain = { goal("rank", { quest = "q1", objective = 1 }) },
			})
			local p = h:addPlayer({ userId = 9 })
			h:tick(1)
			expect(h:use(Goals).current(p).id).toBe("rank") -- rank 50 is worse than 10: not done
			states.q1.values = { 0 } -- unranked
			fake.fired.Progressed:Fire(p, { "q1" })
			h:tick(1)
			expect(h:use(Goals).current(p).id).toBe("rank")
			states.q1.values = { 7 }
			fake.fired.Progressed:Fire(p, { "q1" })
			h:tick(1)
			expect(h:use(Goals).current(p)).toBeNil() -- rank 7 <= 10
		end
	)

	it("quest checks while Quests is off are a boot error; Goals alone boots", function()
		local _, err = StudWork.test.boot({
			modules = { Goals },
			config = { Goals = { chain = { goal("q", { quest = "story1" }) } } },
		})
		expect(err).never.toBeNil()
		local h = StudWork.test.boot({
			modules = { Goals },
			config = { Goals = { chain = { goal("c", { call = true }) } } },
		})
		expect(h).never.toBeNil()
	end)
end)
