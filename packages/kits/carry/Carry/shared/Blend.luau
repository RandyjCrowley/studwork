--!strict
--[[
	Blend: the multi-carrier target pose (carry.md "Object motion", step 3). Pure and deterministic.

	  Blend.targetCF(slots, def, out?) -> (CF, tiltDegrees, stretch, implied)

	`slots` is the OCCUPIED slots in slot order: { { index = <slot number>, hold = <the carrier's hold CF:
	root * CF(holdOffset)> } }. `def.gripPoints[index]` is the object-local grip of that slot.

	  implied_i   = hold_i * CF(-grip_i)               (the object pivot that carrier i alone implies)
	  position    = the mean of the implied positions, folded in slot order (3+ carriers: fixed order)
	  orientation = 1 carrier: the hold orientation.
	                2+: the rotation that maps the object-local axis grip_last - grip_first onto the world
	                axis hold_last - hold_first (the first and last OCCUPIED slots), roll chosen so the
	                object's up stays closest to world up. No quaternion averaging, so nothing flips.
	  tilt        = the angle (degrees) between the target's up vector and world up
	  stretch     = max |implied_i - position|
	`implied` is { [slotIndex]: vector } for the grip-break test: `out` when given (cleared and refilled, so a
	caller on a hot path reuses one table), else a new table.
	The object-local half of the 2+ orientation (inverse(lookAlong(grip_last - grip_first))) depends only on
	`def` and the two slot indices, so it is computed once per (def, first, last) and cached (weak keys).
]]

local CF = require(script.Parent.CF)

local Blend = {}

local ZERO = vector.create(0, 0, 0)
local UP = vector.create(0, 1, 0)

local function grip(def: any, index: number): vector
	local g = def.gripPoints[index] or { 0, 0, 0 }
	return vector.create(g[1] or 0, g[2] or 0, g[3] or 0)
end

-- def -> { [first * 1024 + last]: inverse(lookAlong(grip_last - grip_first)) } (false: a degenerate axis)
local localAxis: { [any]: { [number]: any } } = setmetatable({}, { __mode = "k" }) :: any

local function localAxisInverse(def: any, firstIndex: number, lastIndex: number): CF.CF?
	local byPair = localAxis[def]
	if byPair == nil then
		byPair = {}
		localAxis[def] = byPair
	end
	local key = firstIndex * 1024 + lastIndex
	local cached = byPair[key]
	if cached == nil then
		local a = grip(def, lastIndex) - grip(def, firstIndex)
		cached = if vector.magnitude(a) < 1e-6 then false else CF.inverse(CF.lookAlong(ZERO, a, UP))
		byPair[key] = cached
	end
	return cached or nil
end

function Blend.targetCF(
	slots: { any },
	def: any,
	out: { [number]: vector }?
): (CF.CF, number, number, { [number]: vector })
	local n = #slots
	assert(n >= 1, "Blend.targetCF: no occupied slots")
	local implied: { [number]: vector }
	if out ~= nil then
		table.clear(out)
		implied = out
	else
		implied = {}
	end
	local sum = ZERO
	for _, slot in slots do
		local p = CF.pointTo(slot.hold, -grip(def, slot.index))
		implied[slot.index] = p
		sum += p
	end
	local pos = sum / n

	local rotation: { number }
	local first, last = slots[1], slots[n]
	if n == 1 then
		rotation = first.hold.r
	else
		local invLa = localAxisInverse(def, first.index, last.index)
		local w = last.hold.p - first.hold.p
		if invLa == nil or vector.magnitude(w) < 1e-6 then
			rotation = first.hold.r
		else
			rotation = CF.mul(CF.lookAlong(ZERO, w, UP), invLa).r
		end
	end
	local target = CF.new(pos, rotation)

	local up = CF.upVector(target)
	local tilt = math.deg(math.acos(math.clamp(up.y, -1, 1)))
	local stretch = 0
	for _, p in implied do
		stretch = math.max(stretch, vector.magnitude(p - pos))
	end
	return target, tilt, stretch, implied
end

return Blend
