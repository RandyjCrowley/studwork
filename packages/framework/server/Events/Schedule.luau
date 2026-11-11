--!strict
--[[
	Pure live-event schedule math (no Roblox globals).

	All times are unix seconds in UTC. A schedule (Types.EventSchedule) is
	{ weekday: 1..7? (1 = Sunday, nil = every day), hourUtc: 0..23, minuteUtc: 0..59? }.
	Because the math only depends on `now`, every server computes the same windows.

	1970-01-01 (day 0) was a Thursday, so weekday(day) = (day + 4) % 7 + 1.

	lastStart(s, now)          most recent start <= now
	nextStart(s, now)          first start > now
	activeWindow(s, dur, now)  (startedAt, endsAt) when now is inside [start, start + dur), else nil
]]

local Schedule = {}

local DAY = 86400
local WEEK = 7 * DAY

export type EventSchedule = { weekday: number?, hourUtc: number, minuteUtc: number? }

local function isInt(v: any, lo: number, hi: number): boolean
	return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

-- Returns nil when valid, else a reason string.
function Schedule.validate(s: any): string?
	if type(s) ~= "table" then
		return "schedule must be a table"
	end
	if s.weekday ~= nil and not isInt(s.weekday, 1, 7) then
		return "weekday must be an integer 1..7 (1 = Sunday) or nil"
	end
	if not isInt(s.hourUtc, 0, 23) then
		return "hourUtc must be an integer 0..23"
	end
	if s.minuteUtc ~= nil and not isInt(s.minuteUtc, 0, 59) then
		return "minuteUtc must be an integer 0..59"
	end
	return nil
end

function Schedule.weekday(day: number): number
	return (day + 4) % 7 + 1
end

function Schedule.lastStart(s: EventSchedule, now: number): number
	local day = now // DAY
	local offset = s.hourUtc * 3600 + (s.minuteUtc or 0) * 60
	if s.weekday == nil then
		local start = day * DAY + offset
		if start > now then
			start -= DAY
		end
		return start
	end
	local back = (Schedule.weekday(day) - s.weekday) % 7
	local start = (day - back) * DAY + offset
	if start > now then
		start -= WEEK
	end
	return start
end

function Schedule.period(s: EventSchedule): number
	return if s.weekday == nil then DAY else WEEK
end

function Schedule.nextStart(s: EventSchedule, now: number): number
	return Schedule.lastStart(s, now) + Schedule.period(s)
end

function Schedule.activeWindow(s: EventSchedule, durationSec: number, now: number): (number?, number?)
	if type(durationSec) ~= "number" or durationSec ~= durationSec or durationSec <= 0 then
		return nil, nil
	end
	local start = Schedule.lastStart(s, now)
	local endsAt = start + durationSec
	if now < endsAt then
		return start, endsAt
	end
	return nil, nil
end

return Schedule
