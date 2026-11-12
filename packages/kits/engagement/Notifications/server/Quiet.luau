--!strict
--[[
	Quiet hours (docs/framework/kits/notifications.md, config `quiet`). Pure, no Roblox globals.

	A recipient's local time is unix time + their UTC offset (hours, -14..14; the client reports it,
	`quiet.defaultUtcOffsetHours` when unknown). The quiet window runs from `startHour` to `endHour`
	local time and wraps midnight when startHour > endHour (the default 22 -> 8). startHour == endHour
	means no quiet hours.

	  Quiet.offset(hours, default) -> number          a usable offset (finite, -14..14) or the default
	  Quiet.inQuiet(t, offsetHours, startHour, endHour) -> boolean
	  Quiet.nextOpen(t, offsetHours, startHour, endHour) -> number
	      the first unix time at or after `t` outside quiet hours (`t` itself when not quiet)
]]

local Quiet = {}

local DAY = 86400
local HOUR = 3600

function Quiet.offset(hours: any, default: number): number
	if type(hours) == "number" and hours == hours and hours >= -14 and hours <= 14 then
		return hours
	end
	return default
end

local function localSeconds(t: number, offsetHours: number): number
	return (t + offsetHours * HOUR) % DAY
end

function Quiet.inQuiet(t: number, offsetHours: number, startHour: number, endHour: number): boolean
	if startHour == endHour then
		return false
	end
	local sod = localSeconds(t, offsetHours)
	local startS, endS = startHour * HOUR, endHour * HOUR
	if startS > endS then
		return sod >= startS or sod < endS
	end
	return sod >= startS and sod < endS
end

function Quiet.nextOpen(t: number, offsetHours: number, startHour: number, endHour: number): number
	if not Quiet.inQuiet(t, offsetHours, startHour, endHour) then
		return t
	end
	local sod = localSeconds(t, offsetHours)
	local delta = (endHour * HOUR - sod) % DAY
	return t + delta
end

return Quiet
