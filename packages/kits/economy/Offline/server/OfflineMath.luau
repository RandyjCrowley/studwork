--!strict
--[[
	Pure offline-earnings math (zero Roblox dependencies). Tested by OfflineMath.spec.

	secondsAway(now, lastSeen, sessions, cfg) -> number?
	  nil when this is the first session (sessions <= 1 or lastSeen <= 0) or the clamped time is
	  below cfg.minSeconds. Clock skew (lastSeen in the future) clamps to 0 -> nil.
	  Otherwise clamp(now - lastSeen, 0, capSeconds).
	payout(rate, seconds, fraction) -> floor(rate * seconds * clamp(fraction, 0, 1)); 0 on bad input.
]]

local OfflineMath = {}

export type Cfg = { capSeconds: number, minSeconds: number, payoutFraction: number, autoPay: boolean }

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function OfflineMath.secondsAway(now: number, lastSeen: number, sessions: number?, cfg: Cfg): number?
	if not isFinite(now) or not isFinite(lastSeen) or lastSeen <= 0 then
		return nil
	end
	if sessions ~= nil and sessions <= 1 then
		return nil
	end
	local away = math.clamp(now - lastSeen, 0, math.max(cfg.capSeconds, 0))
	if away < cfg.minSeconds or away <= 0 then
		return nil
	end
	return away
end

function OfflineMath.payout(rate: number, seconds: number, fraction: number): number
	if not isFinite(rate) or not isFinite(seconds) or not isFinite(fraction) or rate <= 0 or seconds <= 0 then
		return 0
	end
	return math.floor(rate * seconds * math.clamp(fraction, 0, 1))
end

return OfflineMath
