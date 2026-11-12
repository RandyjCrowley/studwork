--!strict
--[[
	Leaderboards: periods on the framework clock (pure, no yielding).

	  Period.of(period, now, offsetHours, weekStartsOn) -> { id: string, startsAt, endsAt } | nil
	      "allTime" -> nil. "daily": id = the local day index; "weekly": id = the local day index of the
	      week's first day. startsAt / endsAt are unix seconds (a period is a half-open interval).
	  Period.previous(period, current, offsetHours, weekStartsOn) -> same shape, the period just before
	  Period.expirySeconds(endsAt, graceHours, now) -> number, seconds a period's item lives (1.. 45 days)

	Day 0 (1970-01-01) was a Thursday, so a Monday-start week index is floor((day + 3) / 7) and a
	Sunday-start one floor((day + 4) / 7).
]]

local DAY = 86400
local HOUR = 3600
local MAX_EXPIRY = 3888000 -- 45 days, the sorted map's limit (module-api.md §23.4)

local Period = {}

export type Info = { id: string, startsAt: number, endsAt: number }

local function dayIndex(now: number, offsetHours: number): number
	return math.floor((now + offsetHours * HOUR) / DAY)
end

local function weekFirstDay(day: number, weekStartsOn: string): number
	local shift = if weekStartsOn == "sunday" then 4 else 3
	return math.floor((day + shift) / 7) * 7 - shift
end

local function build(firstDay: number, days: number, offsetHours: number): Info
	return {
		id = string.format("%d", firstDay),
		startsAt = firstDay * DAY - offsetHours * HOUR,
		endsAt = (firstDay + days) * DAY - offsetHours * HOUR,
	}
end

function Period.of(period: string, now: number, offsetHours: number, weekStartsOn: string): Info?
	if period == "daily" then
		return build(dayIndex(now, offsetHours), 1, offsetHours)
	elseif period == "weekly" then
		return build(weekFirstDay(dayIndex(now, offsetHours), weekStartsOn), 7, offsetHours)
	end
	return nil
end

-- The period with this id (a day index as text), or nil for a bad id.
function Period.fromId(period: string, id: string, offsetHours: number): Info?
	local firstDay = tonumber(id)
	if firstDay == nil or (period ~= "daily" and period ~= "weekly") then
		return nil
	end
	return build(firstDay, if period == "weekly" then 7 else 1, offsetHours)
end

function Period.previous(period: string, current: Info, offsetHours: number, weekStartsOn: string): Info?
	-- one second before the current period began falls inside the previous one
	return Period.of(period, current.startsAt - 1, offsetHours, weekStartsOn)
end

function Period.expirySeconds(endsAt: number, graceHours: number, now: number): number
	local seconds = math.ceil(endsAt + graceHours * HOUR - now)
	return math.max(1, math.min(MAX_EXPIRY, seconds))
end

Period.DAY = DAY

return Period
