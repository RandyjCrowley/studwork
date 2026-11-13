--!nocheck
--[[
	Quests event quests (docs/framework/kits/quests.md, "Event quests"): active while
	ctx.events.isActive, progress and claim per window; numeric window keys (startedAt for a
	scheduled event, the start of startedAt's UTC day for a hand-triggered one); a server hop
	during the event; a complete but unclaimed event quest to waiting when its window ends.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local K = require("packages/kits/quests/tests/QuestsKit.luau")
local F = K.F

local DAY = 86400
local START = 1700000000 -- 22:13:20 UTC on day 19675
local DAY_START = 19675 * DAY

local function cfg()
	return {
		daily = { count = 0, rerollsPerSlot = 0 },
		weekly = { count = 0, rerollsPerSlot = 0 },
		quests = { ev = F.quest("event", { F.counter("coin", 5) }, { event = "testEvent" }) },
	}
end

local function trigger(h)
	return h:console("events", "event", "testEvent")
end

describe("Quests event quests", function()
	it("is active only inside the window; a hand-triggered window is keyed by its UTC day", function()
		local h, p, q = K.boot({ quests = cfg() })
		expect(q.state(p, "ev").status).toBe("inactive")
		expect(q.progress(p, "coin", 5)).toBe(false)
		expect(string.find(trigger(h), "started", 1, true) ~= nil).toBe(true)
		h:tick(1)
		expect(q.state(p, "ev").status).toBe("active")
		expect(q.progress(p, "coin", 5)).toBe(true)
		expect(q.claim(p, "ev")).toBe(true)
		expect(q.state(p, "ev").periodId).toBe(DAY_START)
		expect(select(2, q.claim(p, "ev"))).toBe("claimed")
		h:tick(601) -- the window ends
		expect(q.state(p, "ev").status).toBe("inactive")
		expect(select(2, q.claim(p, "ev"))).toBe("not_active")
		-- a second hand trigger the same UTC day doesn't reopen it (by design)
		trigger(h)
		h:tick(1)
		expect(q.state(p, "ev").status).toBe("claimed")
		h:tick(601)
		-- the next UTC day opens a new window
		h.clock += DAY
		trigger(h)
		h:tick(1)
		expect(q.state(p, "ev").status).toBe("active")
		expect(q.state(p, "ev").periodId).toBe(DAY_START + DAY)
		expect(q.state(p, "ev").values).toEqual({ 0 })
		h:removePlayer(p)
		expect(type(K.section(h, p).prog.ev.p)).toBe("number")
	end)

	it("keys a scheduled window by its startedAt", function()
		local events = { testEvent = { durationSec = 600, schedule = { hourUtc = 22, minuteUtc = 15 } } }
		local h, p, q = K.boot({ quests = cfg(), events = events })
		expect(q.state(p, "ev").status).toBe("inactive")
		h:tick(101) -- 22:15:00 UTC
		expect(q.state(p, "ev").status).toBe("active")
		expect(q.state(p, "ev").periodId).toBe(DAY_START + 22 * 3600 + 15 * 60)
	end)

	it("carries progress and the claim across a server hop in the same window", function()
		local store = StudWork.test.memoryStore()
		local a, p, q = K.boot({ quests = cfg(), store = store })
		trigger(a)
		a:tick(1)
		q.progress(p, "coin", 3)
		a:removePlayer(p)
		-- another server triggers the same event by hand a few minutes later, the same UTC day
		local b = K.harness({ quests = cfg(), store = store, startTime = START + 120 })
		trigger(b)
		b:tick(1)
		local p2 = b:addPlayer({ userId = 1 })
		local q2 = b:use(K.Quests)
		expect(q2.state(p2, "ev").values).toEqual({ 3 })
		q2.progress(p2, "coin", 2)
		expect(q2.claim(p2, "ev")).toBe(true)
		b:removePlayer(p2)
		local c = K.harness({ quests = cfg(), store = store, startTime = START + 240 })
		trigger(c)
		c:tick(1)
		local p3 = c:addPlayer({ userId = 1 })
		expect(select(2, c:use(K.Quests).claim(p3, "ev"))).toBe("claimed")
	end)

	it("moves a complete, unclaimed event quest to waiting when its window ends", function()
		local h, p, q = K.boot({ quests = cfg() })
		trigger(h)
		h:tick(1)
		q.progress(p, "coin", 5)
		h:tick(1)
		expect(q.state(p, "ev").status).toBe("complete")
		h:tick(601)
		local waiting
		for _, v in q.active(p) do
			if v.waiting then
				waiting = v
			end
		end
		expect(waiting.id).toBe("ev")
		expect(waiting.periodId).toBe(DAY_START)
		h:removePlayer(p)
		local s = K.section(h, p)
		expect(s.waiting).toEqual({ { q = "ev", k = "event", p = DAY_START } })
		expect(s.prog.ev.s).toBe(2) -- the window stays consumed
		local p2 = h:addPlayer({ userId = 1 })
		expect(q.claim(p2, "ev")).toBe(true)
		expect(select(2, q.claim(p2, "ev"))).toBe("not_active")
		expect(h:state(p2).modules.Quests.extra.board.waiting).toEqual({})
	end)
end)
