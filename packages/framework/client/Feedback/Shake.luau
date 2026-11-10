--!strict
--[[
	Camera shake curve. Pure numbers in/out.

	Shake.offset(elapsed, duration, intensity, seed) -> (x, y, roll)
	  x/y in studs (camera-local), roll in radians. Smooth (sum of sines at fixed incommensurate
	  frequencies, phase from seed), decays with (1 - t)^2, exactly 0 at/after duration.
	Shake.forRarity(order) -> intensity?   nil below Legendary (order 5); grows per tier.
	Shake.combine(current, added) -> intensity   new shakes stack but cap at MAX_INTENSITY.
	Intensity 1 = a "big reward" shake (~0.35 studs, ~0.6 degrees peak).
]]

local Shake = {}

Shake.DEFAULT_INTENSITY = 1
Shake.MAX_INTENSITY = 2.5
Shake.DURATION = 0.45
Shake.MIN_ORDER = 5 -- Legendary

local AMP_POS = 0.35
local AMP_ROLL = math.rad(0.6)

function Shake.offset(
	elapsed: number,
	duration: number,
	intensity: number,
	seed: number?
): (number, number, number)
	if duration <= 0 or elapsed >= duration or elapsed < 0 or intensity <= 0 then
		return 0, 0, 0
	end
	local t = elapsed / duration
	local decay = (1 - t) * (1 - t)
	local p = (seed or 0) * 1.7
	local a = intensity * decay
	local x = (math.sin(elapsed * 61 + p) * 0.6 + math.sin(elapsed * 37 + p * 2) * 0.4) * AMP_POS * a
	local y = (math.sin(elapsed * 53 + p * 3) * 0.6 + math.sin(elapsed * 29 + p) * 0.4) * AMP_POS * a
	local roll = math.sin(elapsed * 41 + p * 5) * AMP_ROLL * a
	return x, y, roll
end

function Shake.forRarity(order: number): number?
	if order < Shake.MIN_ORDER then
		return nil
	end
	return math.min(Shake.MAX_INTENSITY, 0.8 + (order - Shake.MIN_ORDER) * 0.35)
end

function Shake.combine(current: number, added: number): number
	return math.min(Shake.MAX_INTENSITY, math.max(current, 0) + math.max(added, 0))
end

return Shake
