local StreakMath = require(script.Parent.StreakMath)

local DAY = 86400
local HOUR = 3600
local D = 20000 -- some UTC day index

local function at(day: number, seconds: number?): number
	return day * DAY + (seconds or 0)
end

describe("StreakMath.advance", function()
	it("starts at day 1 the first time", function()
		local s, o = StreakMath.advance({ day = 0, lastDay = 0 }, at(D, 5), 6)
		expect(o).toBe("first")
		expect(s.day).toBe(1)
		expect(s.lastDay).toBe(D)
	end)

	it("does nothing on the same UTC day (00:00:00 and 23:59:59)", function()
		local _, o1 = StreakMath.advance({ day = 3, lastDay = D }, at(D), 6)
		local s2, o2 = StreakMath.advance({ day = 3, lastDay = D }, at(D, DAY - 1), 6)
		expect(o1).toBe("same")
		expect(o2).toBe("same")
		expect(s2.day).toBe(3)
	end)

	it("advances exactly at the next UTC midnight", function()
		local s, o = StreakMath.advance({ day = 3, lastDay = D }, at(D + 1), 6)
		expect(o).toBe("next")
		expect(s.day).toBe(4)
		expect(s.lastDay).toBe(D + 1)
	end)

	it("advances at the last second of the next day", function()
		local _, o = StreakMath.advance({ day = 3, lastDay = D }, at(D + 1, DAY - 1), 0)
		expect(o).toBe("next")
	end)

	it("forgives one missed day within graceHours after it ended", function()
		local s, o = StreakMath.advance({ day = 3, lastDay = D }, at(D + 2, 6 * HOUR - 1), 6)
		expect(o).toBe("grace")
		expect(s.day).toBe(4)
		expect(s.lastDay).toBe(D + 2)
	end)

	it("resets exactly at the grace deadline", function()
		local s, o = StreakMath.advance({ day = 3, lastDay = D }, at(D + 2, 6 * HOUR), 6)
		expect(o).toBe("reset")
		expect(s.day).toBe(1)
	end)

	it("resets after a missed day when graceHours is 0 or invalid", function()
		local _, o1 = StreakMath.advance({ day = 3, lastDay = D }, at(D + 2), 0)
		local _, o2 = StreakMath.advance({ day = 3, lastDay = D }, at(D + 2), 0 / 0)
		local _, o3 = StreakMath.advance({ day = 3, lastDay = D }, at(D + 2), -5)
		local _, o4 = StreakMath.advance({ day = 3, lastDay = D }, at(D + 2), nil)
		expect(o1).toBe("reset")
		expect(o2).toBe("reset")
		expect(o3).toBe("reset")
		expect(o4).toBe("reset")
	end)

	it("resets after long gaps even with grace", function()
		local s, o = StreakMath.advance({ day = 40, lastDay = D }, at(D + 30, 1), 6)
		expect(o).toBe("reset")
		expect(s.day).toBe(1)
		expect(s.lastDay).toBe(D + 30)
	end)

	it("graceHours > 24 can span into a later day (deadline is absolute)", function()
		local _, o = StreakMath.advance({ day = 2, lastDay = D }, at(D + 3, 5 * HOUR), 30)
		expect(o).toBe("grace")
		local _, o2 = StreakMath.advance({ day = 2, lastDay = D }, at(D + 3, 6 * HOUR), 30)
		expect(o2).toBe("reset")
	end)

	it("ignores clock skew (now before lastDay) without resetting", function()
		local s, o = StreakMath.advance({ day = 5, lastDay = D }, at(D - 1, 100), 6)
		expect(o).toBe("skew")
		expect(s.day).toBe(5)
		expect(s.lastDay).toBe(D)
		expect(StreakMath.counts(o)).toBe(false)
	end)

	it("counts only real daily visits", function()
		expect(StreakMath.counts("first")).toBe(true)
		expect(StreakMath.counts("next")).toBe(true)
		expect(StreakMath.counts("grace")).toBe(true)
		expect(StreakMath.counts("reset")).toBe(true)
		expect(StreakMath.counts("same")).toBe(false)
	end)
end)

describe("StreakMath.rewardFor", function()
	local rewards = {
		{ day = 1, amount = 100 },
		{ day = 2, amount = 250 },
		{ day = 7, amount = 2500, currency = "Gems" },
	}

	it("finds the reward for a day, nil for gaps", function()
		expect((StreakMath.rewardFor(1, rewards, 7) :: any).amount).toBe(100)
		expect(StreakMath.rewardFor(3, rewards, 7)).toBeNil()
		expect((StreakMath.rewardFor(7, rewards, 7) :: any).currency).toBe("Gems")
	end)

	it("wraps after loopAfter while the streak keeps counting", function()
		expect(StreakMath.effectiveDay(8, 7)).toBe(1)
		expect(StreakMath.effectiveDay(14, 7)).toBe(7)
		expect(StreakMath.effectiveDay(15, 7)).toBe(1)
		expect((StreakMath.rewardFor(9, rewards, 7) :: any).amount).toBe(250)
	end)

	it("does not wrap without loopAfter", function()
		expect(StreakMath.rewardFor(8, rewards, nil)).toBeNil()
		expect(StreakMath.effectiveDay(8, 0)).toBe(8)
		expect(StreakMath.rewardFor(1, nil, 7)).toBeNil()
	end)
end)

describe("StreakMath time zone (core-v1.3.0)", function()
	local DAY = 86400
	it("offset 0 / nil / invalid is UTC (the v1.2 days)", function()
		local t = 100 * DAY + 3600
		expect(StreakMath.dayIndex(t)).toBe(100)
		expect(StreakMath.dayIndex(t, 0)).toBe(100)
		expect(StreakMath.dayIndex(t, 0 / 0)).toBe(100)
		expect(StreakMath.dayIndex(t, 99)).toBe(100)
	end)

	it("days roll over at local midnight", function()
		-- 23:00 UTC on day 100 is already day 101 at UTC+2, still day 100 at UTC-5
		local t = 100 * DAY + 23 * 3600
		expect(StreakMath.dayIndex(t, 2)).toBe(101)
		expect(StreakMath.dayIndex(t, -5)).toBe(100)
		local state = { day = 3, lastDay = 100 }
		local nextUtc, outcomeUtc = StreakMath.advance(state, t, 0, 0)
		expect(outcomeUtc).toBe("same")
		expect(nextUtc.day).toBe(3)
		local nextLocal, outcomeLocal = StreakMath.advance(state, t, 0, 2)
		expect(outcomeLocal).toBe("next")
		expect(nextLocal.day).toBe(4)
		expect(nextLocal.lastDay).toBe(101)
	end)

	it("the grace window ends graceHours after LOCAL midnight", function()
		-- last counted local day 100 at UTC+3; day 101 missed; local day 102 starts at
		-- 102*DAY - 3h UTC, so a 6 h grace lasts until 102*DAY + 3h UTC
		local state = { day = 5, lastDay = 100 }
		local inside = 102 * DAY + 3 * 3600 - 1
		local _, a = StreakMath.advance(state, inside, 6, 3)
		expect(a).toBe("grace")
		local _, b = StreakMath.advance(state, inside + 2, 6, 3)
		expect(b).toBe("reset")
	end)
end)
