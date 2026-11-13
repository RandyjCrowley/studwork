--!strict
--[[
	Wobble: the cosmetic carry sway (pure; carry.md "Client" > "Wobble"). Computed on the client from the
	object's OBSERVED motion only; nothing wobble-related is sent per tick. A damped spring driven by the
	object's lateral acceleration, with its phase seeded by the object's `wobbleSeed`.

	  Wobble.new(cfg, seed) -> w         cfg = { enabled, maxDegrees, hz, damping }
	  Wobble.step(w, lateralAccel, dt) -> (angleDeg, phase)
	      lateralAccel: studs/s^2 along the object's right axis (signed); the spring is
	      angle'' = -w0^2 angle - 2 z w0 angle' + gain x lateralAccel, clamped to +-maxDegrees
]]

local Wobble = {}

local TAU = 2 * math.pi
-- degrees of sway per stud/s^2 at the spring's resting response (1 stud/s^2 ~ 0.5 degrees)
local GAIN = 0.5

function Wobble.new(cfg: any, seed: number): any
	return {
		cfg = cfg,
		angle = 0,
		velocity = 0,
		phase = (seed % 1000) / 1000 * TAU,
	}
end

function Wobble.step(w: any, lateralAccel: number, dt: number): (number, number)
	local cfg = w.cfg
	if not cfg.enabled or dt <= 0 then
		return 0, w.phase
	end
	dt = math.min(dt, 0.1) -- a hitch must not blow the spring up
	local w0 = TAU * cfg.hz
	-- semi-implicit Euler, one substep per 1/240 s so the stiff spring stays stable
	local steps = math.max(1, math.ceil(dt * 240))
	local h = dt / steps
	for _ = 1, steps do
		local accel = -w0 * w0 * w.angle - 2 * cfg.damping * w0 * w.velocity + w0 * w0 * GAIN * lateralAccel
		w.velocity += accel * h
		w.angle += w.velocity * h
	end
	w.angle = math.clamp(w.angle, -cfg.maxDegrees, cfg.maxDegrees)
	w.phase = (w.phase + w0 * dt) % TAU
	return w.angle, w.phase
end

return Wobble
