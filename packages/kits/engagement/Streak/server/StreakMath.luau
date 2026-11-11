--!strict
--[[
	Pure daily-streak math (no Roblox globals).

	Days are day indices in a time zone: day(t, utcOffsetHours) = (t + offset * 3600) // 86400
	(day 0 = 1970-01-01 there). utcOffsetHours defaults to 0 (UTC, the v1.2 behaviour); a value
	that is not a finite number in -14..14 counts as 0. All rules below use these local days, and
	the grace window ends graceHours after local midnight.

	advance(state, now, graceHours, utcOffsetHours?) decides what a visit at unix time `now` does:
	  - never claimed (lastDay <= 0 or day <= 0)          -> "first",  day = 1
	  - today == lastDay                                  -> "same",   unchanged
	  - today < lastDay (clock skew / rollback)           -> "skew",   unchanged (never punish)
	  - today == lastDay + 1                              -> "next",   day + 1
	  - now < (lastDay + 2) * 86400 + graceHours * 3600   -> "grace",  day + 1
	      i.e. the player missed day lastDay+1 but returned within graceHours after that missed
	      day ended (it ends at the start of day lastDay+2). The missed day itself is not counted.
	      With graceHours <= 24 this only ever forgives exactly one missed day.
	  - otherwise                                         -> "reset",  day = 1
	graceHours that is not a finite number >= 0 is treated as 0.
	"next" | "grace" | "reset" | "first" count as a new daily visit (rewards + handlers fire).

	rewardFor(day, rewards, loopAfter) returns the reward entry for a streak day. When loopAfter
	is a positive integer and day > loopAfter, the table wraps: effective = (day - 1) % loopAfter + 1.
	Days without an entry give nil.
]]

local StreakMath = {}

local DAY = 86400
local HOUR = 3600

export type State = { day: number, lastDay: number }
export type Outcome = "first" | "same" | "skew" | "next" | "grace" | "reset"
export type Reward = { day: number, currency: string?, amount: number }

local function finiteNonNegative(value: any): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value < 0 then
		return 0
	end
	return value
end

local function offsetSeconds(utcOffsetHours: number?): number
	local h = utcOffsetHours
	if type(h) ~= "number" or h ~= h or h < -14 or h > 14 then
		return 0
	end
	return h * HOUR
end

function StreakMath.dayIndex(now: number, utcOffsetHours: number?): number
	return (now + offsetSeconds(utcOffsetHours)) // DAY
end

function StreakMath.advance(
	state: State,
	now: number,
	graceHours: number?,
	utcOffsetHours: number?
): (State, Outcome)
	now += offsetSeconds(utcOffsetHours) -- local wall-clock seconds from here on
	local today = now // DAY
	local lastDay = state.lastDay
	if lastDay <= 0 or state.day <= 0 then
		return { day = 1, lastDay = today }, "first" :: Outcome
	end
	if today == lastDay then
		return { day = state.day, lastDay = lastDay }, "same" :: Outcome
	end
	if today < lastDay then
		return { day = state.day, lastDay = lastDay }, "skew" :: Outcome
	end
	if today == lastDay + 1 then
		return { day = state.day + 1, lastDay = today }, "next" :: Outcome
	end
	local graceSec = finiteNonNegative(graceHours) * HOUR
	if now < (lastDay + 2) * DAY + graceSec then
		return { day = state.day + 1, lastDay = today }, "grace" :: Outcome
	end
	return { day = 1, lastDay = today }, "reset" :: Outcome
end

function StreakMath.counts(outcome: string): boolean
	return outcome == "first" or outcome == "next" or outcome == "grace" or outcome == "reset"
end

function StreakMath.effectiveDay(day: number, loopAfter: number?): number
	if
		type(loopAfter) == "number"
		and loopAfter >= 1
		and loopAfter == math.floor(loopAfter)
		and day > loopAfter
	then
		return (day - 1) % loopAfter + 1
	end
	return day
end

function StreakMath.rewardFor(day: number, rewards: { Reward }?, loopAfter: number?): Reward?
	if rewards == nil then
		return nil
	end
	local effective = StreakMath.effectiveDay(day, loopAfter)
	for _, entry in rewards do
		if entry.day == effective then
			return entry
		end
	end
	return nil
end

return StreakMath
