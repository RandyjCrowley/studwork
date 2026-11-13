--!nocheck
--[[
	Quests clock skew (docs/framework/kits/quests.md, "Periods only move forward"): two harnesses
	sharing a memoryStore(), their startTimes on either side of the day boundary. A set saved by
	the server that is ahead stays current on the one behind: no re-deal, no second claim;
	repeatable claim counts and event windows only move forward too.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local K = require("packages/kits/quests/tests/QuestsKit.luau")
local F = K.F

local DAY = 86400
local BOUNDARY = 19676 * DAY

local function cfg()
	return {
		daily = { count = 2, rerollsPerSlot = 1 },
		weekly = { count = 0, rerollsPerSlot = 0 },
		quests = {
			d1 = F.quest("daily", { F.counter("coin", 2) }),
			d2 = F.quest("daily", { F.counter("gem", 1) }),
			d3 = F.quest("daily", { F.counter("fish", 1) }),
			rep = F.quest("repeatable", { F.counter("coin", 1) }, { cap = 2 }),
			ev = F.quest("event", { F.counter("coin", 1) }, { event = "testEvent" }),
		},
	}
end

local function servers()
	local store = StudWork.test.memoryStore()
	local ahead = K.harness({ quests = cfg(), store = store, startTime = BOUNDARY + 2 })
	local behind = K.harness({ quests = cfg(), store = store, startTime = BOUNDARY - 5 })
	return ahead, behind
end

describe("Quests with servers' clocks on either side of the boundary", function()
	it("keeps the set saved ahead of the clock: no re-deal, no second claim", function()
		local ahead, behind = servers()
		local p = ahead:addPlayer({ userId = 1 })
		local qa = ahead:use(K.Quests)
		local dealt = K.ids(qa, p, "daily")
		expect(qa.active(p)[1].periodId).toBe(19676)
		qa.progress(p, "coin", 2)
		qa.progress(p, "gem", 1)
		qa.progress(p, "fish", 1)
		local claimedId = dealt[1]
		expect(qa.claim(p, claimedId)).toBe(true)
		ahead:removePlayer(p)

		local rotated = 0
		local qb = behind:use(K.Quests)
		qb.signals.Rotated:Connect(function()
			rotated += 1
		end)
		local p2 = behind:addPlayer({ userId = 1 })
		expect(K.ids(qb, p2, "daily")).toEqual(dealt)
		expect(qb.active(p2)[1].periodId).toBe(19676)
		expect(select(2, qb.claim(p2, claimedId))).toBe("claimed")
		expect(rotated).toBe(0)
		-- behind's clock reaches the same day: still the same set (not larger)
		behind:tick(10)
		expect(K.ids(qb, p2, "daily")).toEqual(dealt)
		expect(rotated).toBe(0)
		-- the next larger day deals
		behind.clock += DAY
		behind:tick(1)
		expect(rotated).toBe(1)
		expect(qb.active(p2)[1].periodId).toBe(19677)
	end)

	it("a reroll result saved ahead can't be rerolled again behind", function()
		local ahead, behind = servers()
		local p = ahead:addPlayer({ userId = 1 })
		local qa = ahead:use(K.Quests)
		local ok, id = qa.reroll(p, "daily", 1)
		expect(ok).toBe(true)
		ahead:removePlayer(p)
		local p2 = behind:addPlayer({ userId = 1 })
		local qb = behind:use(K.Quests)
		expect(K.ids(qb, p2, "daily")[1]).toBe(id)
		expect(select(2, qb.reroll(p2, "daily", 1))).toBe("no_rerolls")
	end)

	it("a repeatable's claim count saved ahead stands behind", function()
		local ahead, behind = servers()
		local p = ahead:addPlayer({ userId = 1 })
		local qa = ahead:use(K.Quests)
		for _ = 1, 2 do
			qa.progress(p, "coin", 1)
			expect(qa.claim(p, "rep")).toBe(true)
		end
		ahead:removePlayer(p)
		local p2 = behind:addPlayer({ userId = 1 })
		local qb = behind:use(K.Quests)
		qb.progress(p2, "coin", 1)
		expect(select(2, qb.claim(p2, "rep"))).toBe("cap_reached")
		expect(qb.state(p2, "rep").claims).toBe(2)
	end)

	it("an event window saved ahead stays the current window behind", function()
		local ahead, behind = servers()
		ahead:console("events", "event", "testEvent")
		behind:console("events", "event", "testEvent")
		ahead:tick(1)
		behind:tick(1)
		local p = ahead:addPlayer({ userId = 1 })
		local qa = ahead:use(K.Quests)
		qa.progress(p, "coin", 1)
		expect(qa.claim(p, "ev")).toBe(true)
		expect(qa.state(p, "ev").periodId).toBe(BOUNDARY)
		ahead:removePlayer(p)
		local p2 = behind:addPlayer({ userId = 1 })
		local qb = behind:use(K.Quests)
		expect(qb.state(p2, "ev").status).toBe("claimed")
		expect(qb.progress(p2, "coin", 1)).toBe(true) -- rep moves; ev doesn't
		behind:tick(1)
		expect(select(2, qb.claim(p2, "ev"))).toBe("claimed")
	end)
end)
