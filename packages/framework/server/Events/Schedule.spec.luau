local Schedule = require(script.Parent.Schedule)

local DAY = 86400
local SAT = 1704499200 -- 2024-01-06 00:00:00 UTC, a Saturday

describe("Events.Schedule", function()
	it("knows the weekday of an epoch day", function()
		expect(Schedule.weekday(0)).toBe(5) -- 1970-01-01 Thursday
		expect(Schedule.weekday(SAT // DAY)).toBe(7)
		expect(Schedule.weekday(SAT // DAY + 1)).toBe(1) -- Sunday
	end)

	it("validates schedules", function()
		expect(Schedule.validate({ hourUtc = 18 })).toBeNil()
		expect(Schedule.validate({ weekday = 7, hourUtc = 0, minuteUtc = 59 })).toBeNil()
		expect(Schedule.validate({ weekday = 0, hourUtc = 1 })).never.toBeNil()
		expect(Schedule.validate({ hourUtc = 24 })).never.toBeNil()
		expect(Schedule.validate({ hourUtc = 1.5 })).never.toBeNil()
		expect(Schedule.validate({ hourUtc = 1, minuteUtc = 60 })).never.toBeNil()
		expect(Schedule.validate(nil)).never.toBeNil()
	end)

	local weekly = { weekday = 7, hourUtc = 18, minuteUtc = 0 }
	local start = SAT + 18 * 3600

	it("weekly: next start from earlier in the week", function()
		expect(Schedule.nextStart(weekly, SAT - 3 * DAY)).toBe(start)
		expect(Schedule.nextStart(weekly, start - 1)).toBe(start)
	end)

	it("weekly: at the exact start the next start is a week later", function()
		expect(Schedule.lastStart(weekly, start)).toBe(start)
		expect(Schedule.nextStart(weekly, start)).toBe(start + 7 * DAY)
	end)

	it("weekly: a Saturday before the hour points to the previous week for lastStart", function()
		expect(Schedule.lastStart(weekly, start - 1)).toBe(start - 7 * DAY)
	end)

	it("active window covers [start, start + duration)", function()
		local s0, e0 = Schedule.activeWindow(weekly, 300, start)
		expect(s0).toBe(start)
		expect(e0).toBe(start + 300)
		local s1 = Schedule.activeWindow(weekly, 300, start + 299)
		expect(s1).toBe(start)
		expect(Schedule.activeWindow(weekly, 300, start + 300)).toBeNil()
		expect(Schedule.activeWindow(weekly, 300, start - 1)).toBeNil()
	end)

	it("a window crossing midnight stays active (server booting mid-window)", function()
		local late = { weekday = 7, hourUtc = 23, minuteUtc = 50 }
		local s, e = Schedule.activeWindow(late, 1200, SAT + DAY + 300) -- Sunday 00:05
		expect(s).toBe(SAT + 23 * 3600 + 50 * 60)
		expect(e).toBe(SAT + DAY + 600)
	end)

	it("daily schedules repeat every day", function()
		local daily = { hourUtc = 12, minuteUtc = 30 }
		local noon = SAT + 12 * 3600 + 1800
		expect(Schedule.nextStart(daily, SAT)).toBe(noon)
		expect(Schedule.nextStart(daily, noon)).toBe(noon + DAY)
		expect(Schedule.lastStart(daily, SAT)).toBe(noon - DAY)
	end)

	it("rejects bad durations", function()
		expect(Schedule.activeWindow(weekly, 0, start)).toBeNil()
		expect(Schedule.activeWindow(weekly, 0 / 0, start)).toBeNil()
	end)
end)
