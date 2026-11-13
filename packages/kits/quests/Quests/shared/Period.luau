--!strict
--[[
	Quests: periods on the framework clock (pure, no yielding; both sides use it, the client for
	"Resets in"). docs/framework/kits/quests.md, "Periods, the deal and rerolls".

	Days and weeks are counted in a fixed UTC offset (`utcOffsetHours`, -14..14), the framework's
	convention (Streak, Leaderboards). Day 0 (1970-01-01) was a Thursday, so a week's first day is
	floor((day + s) / 7) * 7 - s with s = 3 (monday) or 4 (sunday).

	  Period.day(now, offsetHours) -> number                       the daily period id (local day index)
	  Period.week(now, offsetHours, weekStartsOn) -> number        the weekly period id (day index of the week's first day)
	  Period.id(kind, now, offsetHours, weekStartsOn) -> number    kind "daily" | "weekly"
	  Period.days(kind) -> number                                  1 or 7
	  Period.startsAt(periodId, offsetHours) -> number             unix seconds
	  Period.endsAt(kind, periodId, offsetHours) -> number         unix seconds; a period is [startsAt, endsAt)
	  Period.of(kind, now, offsetHours, weekStartsOn) -> { id, startsAt, endsAt }
	  Period.windowKey(startedAt, scheduled) -> number             an event window key: startedAt for a
	      scheduled event, the start of startedAt's UTC day for one triggered only by hand
	  Period.isNewer(current, saved) -> boolean                    periods only move forward: current > saved
]]

local DAY = 86400
local HOUR = 3600

local Period = {}

export type Kind = "daily" | "weekly"
export type Info = { id: number, startsAt: number, endsAt: number }

function Period.day(now: number, offsetHours: number): number
	return math.floor((now + offsetHours * HOUR) / DAY)
end

local function weekFirstDay(day: number, weekStartsOn: string?): number
	local s = if weekStartsOn == "sunday" then 4 else 3
	return math.floor((day + s) / 7) * 7 - s
end

function Period.week(now: number, offsetHours: number, weekStartsOn: string?): number
	return weekFirstDay(Period.day(now, offsetHours), weekStartsOn)
end

function Period.id(kind: string, now: number, offsetHours: number, weekStartsOn: string?): number
	if kind == "weekly" then
		return Period.week(now, offsetHours, weekStartsOn)
	end
	return Period.day(now, offsetHours)
end

function Period.days(kind: string): number
	return if kind == "weekly" then 7 else 1
end

function Period.startsAt(periodId: number, offsetHours: number): number
	return periodId * DAY - offsetHours * HOUR
end

function Period.endsAt(kind: string, periodId: number, offsetHours: number): number
	return (periodId + Period.days(kind)) * DAY - offsetHours * HOUR
end

function Period.of(kind: string, now: number, offsetHours: number, weekStartsOn: string?): Info
	local id = Period.id(kind, now, offsetHours, weekStartsOn)
	return {
		id = id,
		startsAt = Period.startsAt(id, offsetHours),
		endsAt = Period.endsAt(kind, id, offsetHours),
	}
end

function Period.windowKey(startedAt: number, scheduled: boolean): number
	if scheduled then
		return startedAt
	end
	return math.floor(startedAt / DAY) * DAY
end

function Period.isNewer(current: number, saved: number?): boolean
	return type(saved) ~= "number" or current > saved
end

Period.DAY = DAY
Period.HOUR = HOUR

return Period
