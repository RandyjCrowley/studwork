--!nocheck
--[[
	The page's end-to-end `chains` example (docs/framework/kits/quests.md, "A story chain, end to
	end"): three quests of kind "chain" listed in `chains.story` boot without a validation error,
	only the first step is active, and each claim unlocks the next one, in order.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local F = require("packages/kits/quests/tests/Fixtures.luau")

local Quests = F.Quests
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))

-- the page's snippet, as printed
local function pageConfig()
	return {
		quests = {
			story1 = {
				kind = "chain",
				objectives = { { kind = "counter", key = "talkedToGuide", target = 1 } },
				reward = { { kind = "currency", amount = 20 } },
			},
			story2 = {
				kind = "chain",
				objectives = { { kind = "counter", key = "coinTouched", target = 5 } },
				reward = { { kind = "currency", amount = 30 } },
			},
			story3 = {
				kind = "chain",
				objectives = { { kind = "counter", key = "reachedTower", target = 1 } },
				reward = { { kind = "currency", amount = 100 } },
			},
		},
		chains = { story = { "story1", "story2", "story3" } },
	}
end

local function activeIds(q, p)
	local ids = {}
	for _, v in q.active(p) do
		if v.status == "active" or v.status == "complete" then
			table.insert(ids, v.id)
		end
	end
	return ids
end

describe("Quests page example: a story chain", function()
	it("shows one step at a time and each claim opens the next", function()
		local h = StudWork.test.harness({
			modules = { Economy, Quests },
			config = { Quests = pageConfig(), Economy = F.economy() },
		})
		local p = h:addPlayer({ userId = 1 })
		local q = h:use(Quests)
		expect(activeIds(q, p)).toEqual({ "story1" })

		q.progress(p, "talkedToGuide")
		h:tick(2)
		expect(q.state(p, "story1").status).toBe("complete")
		expect(q.claim(p, "story1")).toBe(true)
		h:tick(2)
		expect(activeIds(q, p)).toEqual({ "story2" })

		q.progress(p, "coinTouched", 5)
		h:tick(2)
		expect(q.claim(p, "story2")).toBe(true)
		h:tick(2)
		expect(activeIds(q, p)).toEqual({ "story3" })

		q.progress(p, "reachedTower")
		h:tick(2)
		expect(q.claim(p, "story3")).toBe(true)
		h:tick(2)
		expect(activeIds(q, p)).toEqual({})
	end)
end)
