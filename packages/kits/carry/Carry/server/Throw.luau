--!strict
--[[
	Throw: the launch velocity of a throw (carry.md "Pick-up, hand-off, throw, catch"). Pure.

	  Throw.velocity(from, target, targetVelocity, speed, gravity) -> vector
	Flight speed is `speed` (studs/s) toward the receiver's PREDICTED position (accepted position plus
	its velocity over the flight time), with gravity compensated for that flight time.
]]

local Throw = {}

function Throw.velocity(
	from: vector,
	target: vector,
	targetVelocity: vector,
	speed: number,
	gravity: number
): vector
	local function flightTime(to: vector): number
		return math.max(vector.magnitude(to - from) / math.max(speed, 1e-3), 0.05)
	end
	local t = flightTime(target)
	local predicted = target + targetVelocity * t
	t = flightTime(predicted)
	predicted = target + targetVelocity * t
	local v = (predicted - from) / t
	return vector.create(v.x, v.y + 0.5 * gravity * t, v.z)
end

return Throw
