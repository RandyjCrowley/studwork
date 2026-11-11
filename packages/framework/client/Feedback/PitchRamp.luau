--!strict
--[[
	Rising pitch for rapid repeated sounds (coin ticks). Pure; the clock is passed in.

	PitchRamp.new({ base?, step?, max?, window? }) -> ramp
	  ramp:next(now) -> playbackSpeed
	    first call, or a call more than `window` seconds after the previous one -> base
	    otherwise previous + step, capped at max
	Defaults: base 1, step 0.06 (about one semitone), max 1.6, window 0.35 s.
]]

export type Options = { base: number?, step: number?, max: number?, window: number? }
export type Ramp = { next: (self: Ramp, now: number) -> number, reset: (self: Ramp) -> () }

local DEFAULT_BASE = 1
local DEFAULT_STEP = 0.06
local DEFAULT_MAX = 1.6
local DEFAULT_WINDOW = 0.35

local PitchRamp = {}

function PitchRamp.new(options: Options?): Ramp
	local o: Options = options or {}
	local base = o.base or DEFAULT_BASE
	local step = o.step or DEFAULT_STEP
	local max = o.max or DEFAULT_MAX
	local window = o.window or DEFAULT_WINDOW
	local last: number? = nil
	local current = base
	local ramp = {}

	function ramp.next(_self: Ramp, now: number): number
		if last == nil or now - (last :: number) > window or now < (last :: number) then
			current = base
		else
			current = math.min(max, current + step)
		end
		last = now
		return current
	end

	function ramp.reset(_self: Ramp)
		last = nil
		current = base
	end

	return (ramp :: any) :: Ramp
end

return PitchRamp
