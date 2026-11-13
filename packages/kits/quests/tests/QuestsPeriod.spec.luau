--!nocheck
--[[
	Quests periods (Quests/shared/Period.luau, kit page "Periods, the deal and rerolls"): day and week
	ids on the framework clock in utcOffsetHours -5, 0 and +9, the boundary itself (a period is
	[startsAt, endsAt)), weeks starting monday or sunday, event window keys, forward-only ids.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Period = require(Modules:WaitForChild("Quests"):WaitForChild("shared"):WaitForChild("Period"))

local DAY = 86400
local HOUR = 3600
-- 2026-11-12 00:00:00 UTC, a Thursday (day index 20769)
local THU = 1794441600
local THU_DAY = 20769

describe("Quests periods: days", function()
	it("day 0 was 1970-01-01 and the fixture day is a Thursday", function()
		expect(Period.day(0, 0)).toBe(0)
		expect(Period.day(THU, 0)).toBe(THU_DAY)
		expect(THU_DAY % 7).toBe(0) -- day 0 was a Thursday too
	end)

	for _, off in { -5, 0, 9 } do
		it(`changes exactly at local midnight in UTC{if off >= 0 then "+" else ""}{off}`, function()
			local midnight = THU - off * HOUR -- local midnight of THU's calendar day, in UTC seconds
			expect(Period.day(midnight - 1, off)).toBe(THU_DAY - 1)
			expect(Period.day(midnight, off)).toBe(THU_DAY)
			expect(Period.day(midnight + DAY - 1, off)).toBe(THU_DAY)
			expect(Period.day(midnight + DAY, off)).toBe(THU_DAY + 1)
			local info = Period.of("daily", midnight + 3600, off)
			expect(info.id).toBe(THU_DAY)
			expect(info.startsAt).toBe(midnight)
			expect(info.endsAt).toBe(midnight + DAY)
			expect(Period.startsAt(THU_DAY, off)).toBe(midnight)
			expect(Period.endsAt("daily", THU_DAY, off)).toBe(midnight + DAY)
		end)
	end

	it("-5 resets at 05:00 UTC, +9 at 15:00 UTC the day before", function()
		expect(Period.startsAt(THU_DAY, -5) - THU).toBe(5 * HOUR)
		expect(Period.startsAt(THU_DAY, 9) - THU).toBe(-9 * HOUR)
		-- the same instant is a different local day in different zones
		local t = THU + 2 * HOUR -- 02:00 UTC Thursday
		expect(Period.day(t, 0)).toBe(THU_DAY)
		expect(Period.day(t, -5)).toBe(THU_DAY - 1) -- 21:00 Wednesday
		expect(Period.day(t, 9)).toBe(THU_DAY) -- 11:00 Thursday
		local late = THU + 20 * HOUR -- 20:00 UTC Thursday
		expect(Period.day(late, 9)).toBe(THU_DAY + 1) -- 05:00 Friday
	end)
end)

describe("Quests periods: weeks", function()
	-- THU_DAY is a Thursday: its monday-week starts 3 days earlier, its sunday-week 4 days earlier
	it("a monday week starts on Monday", function()
		local monday = THU_DAY - 3
		expect(Period.week(THU, 0, "monday")).toBe(monday)
		expect(Period.week(THU, 0, nil)).toBe(monday) -- monday is the default
		expect(Period.id("weekly", THU, 0, "monday")).toBe(monday)
		-- Sunday night still belongs to the week; Monday 00:00 starts the next one
		local nextMonday = Period.startsAt(monday + 7, 0)
		expect(Period.week(nextMonday - 1, 0, "monday")).toBe(monday)
		expect(Period.week(nextMonday, 0, "monday")).toBe(monday + 7)
		local info = Period.of("weekly", THU, 0, "monday")
		expect(info.startsAt).toBe(Period.startsAt(monday, 0))
		expect(info.endsAt).toBe(nextMonday)
		expect(info.endsAt - info.startsAt).toBe(7 * DAY)
	end)

	it("a sunday week starts on Sunday", function()
		local sunday = THU_DAY - 4
		expect(Period.week(THU, 0, "sunday")).toBe(sunday)
		local nextSunday = Period.startsAt(sunday + 7, 0)
		expect(Period.week(nextSunday - 1, 0, "sunday")).toBe(sunday)
		expect(Period.week(nextSunday, 0, "sunday")).toBe(sunday + 7)
		-- the sunday itself: a sunday-week's first day, a monday-week's last day
		local sundayNoon = Period.startsAt(sunday + 7, 0) + 12 * HOUR
		expect(Period.week(sundayNoon, 0, "sunday")).toBe(sunday + 7)
		expect(Period.week(sundayNoon, 0, "monday")).toBe(THU_DAY - 3)
	end)

	for _, off in { -5, 0, 9 } do
		it(`weeks follow the local day in UTC{if off >= 0 then "+" else ""}{off}`, function()
			local monday = THU_DAY - 3
			local start = Period.startsAt(monday + 7, off) -- next local Monday 00:00
			expect(Period.week(start - 1, off, "monday")).toBe(monday)
			expect(Period.week(start, off, "monday")).toBe(monday + 7)
			expect(Period.endsAt("weekly", monday, off)).toBe(start)
		end)
	end

	it("a week id is a day id of the right weekday, for days far from the epoch", function()
		for _, day in { -400, -1, 0, 1, 6, 7, 20404, 30000 } do
			local now = day * DAY + 1
			local monday = Period.week(now, 0, "monday")
			local sunday = Period.week(now, 0, "sunday")
			expect((monday + 3) % 7).toBe(0) -- Monday = Thursday - 3
			expect((sunday + 4) % 7).toBe(0)
			expect(day - monday >= 0 and day - monday < 7).toBe(true)
			expect(day - sunday >= 0 and day - sunday < 7).toBe(true)
		end
	end)
end)

describe("Quests periods: windows and forward-only ids", function()
	it("an event window key is startedAt (scheduled) or its UTC day start (hand-triggered)", function()
		local startedAt = THU + 13 * HOUR + 7
		expect(Period.windowKey(startedAt, true)).toBe(startedAt)
		expect(Period.windowKey(startedAt, false)).toBe(THU)
		expect(Period.windowKey(THU + DAY - 1, false)).toBe(THU)
		expect(Period.windowKey(THU + DAY, false)).toBe(THU + DAY)
	end)

	it("periods only move forward", function()
		expect(Period.isNewer(THU_DAY, nil)).toBe(true)
		expect(Period.isNewer(THU_DAY, -1)).toBe(true)
		expect(Period.isNewer(THU_DAY, THU_DAY)).toBe(false)
		expect(Period.isNewer(THU_DAY, THU_DAY + 1)).toBe(false) -- a set saved ahead of this clock stays
		expect(Period.days("daily")).toBe(1)
		expect(Period.days("weekly")).toBe(7)
	end)
end)
