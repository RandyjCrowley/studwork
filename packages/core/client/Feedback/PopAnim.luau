--!strict
--[[
	Number-pop animation curve + layout. Pure numbers in/out.

	PopAnim.sample(t, reduced) -> { sx, sy, rise, alpha }
	  t = seconds since the pop started. sx/sy = scale multipliers (squash-and-stretch),
	  rise = 0..1 fraction of the float-up distance, alpha = 0 (opaque) .. 1 (invisible).
	  Phases: 0-0.08 s squash in (wide/flat), 0.08-0.2 stretch (tall/thin), 0.2-0.32 settle to 1,
	  then hold and float; fade over the last FADE seconds. Reduced motion: scale 1, no rise,
	  just fade in/out.
	PopAnim.DURATION total lifetime (s).
	PopAnim.stackOffset(slot) -> pixels    vertical offset so concurrent screen pops don't overlap.
	PopAnim.freeSlot(used, maxSlots) -> slot  lowest slot not in `used` (0-based); wraps when full.
]]

local PopAnim = {}

PopAnim.DURATION = 1.1
PopAnim.FADE = 0.3
PopAnim.SLOT_HEIGHT = 34

export type Sample = { sx: number, sy: number, rise: number, alpha: number }

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function easeOut(t: number): number
	return 1 - (1 - t) * (1 - t)
end

function PopAnim.sample(t: number, reduced: boolean?): Sample
	local d = PopAnim.DURATION
	if t >= d then
		return { sx = 1, sy = 1, rise = 1, alpha = 1 }
	end
	local alpha = 0
	if t > d - PopAnim.FADE then
		alpha = (t - (d - PopAnim.FADE)) / PopAnim.FADE
	end
	if reduced then
		local fadeIn = if t < 0.1 then 1 - t / 0.1 else 0
		return { sx = 1, sy = 1, rise = 0, alpha = math.max(alpha, fadeIn) }
	end
	local sx, sy
	if t < 0.08 then
		local k = easeOut(t / 0.08)
		sx, sy = lerp(0.2, 1.3, k), lerp(0.2, 0.7, k)
	elseif t < 0.2 then
		local k = easeOut((t - 0.08) / 0.12)
		sx, sy = lerp(1.3, 0.85, k), lerp(0.7, 1.25, k)
	elseif t < 0.32 then
		local k = easeOut((t - 0.2) / 0.12)
		sx, sy = lerp(0.85, 1, k), lerp(1.25, 1, k)
	else
		sx, sy = 1, 1
	end
	local rise = easeOut(math.clamp(t / d, 0, 1))
	return { sx = sx, sy = sy, rise = rise, alpha = alpha }
end

function PopAnim.stackOffset(slot: number): number
	return -slot * PopAnim.SLOT_HEIGHT
end

function PopAnim.freeSlot(used: { [number]: boolean }, maxSlots: number): number
	for slot = 0, maxSlots - 1 do
		if not used[slot] then
			return slot
		end
	end
	return 0
end

return PopAnim
