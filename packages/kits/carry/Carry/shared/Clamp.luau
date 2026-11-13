--!strict
--[[
	Clamp: Carry's own object-displacement clamp (carry.md "Object motion", step 4, and "Worked numbers
	(Carry clamp)"). Pure. It applies with or without Movement: the object never moves faster than
	`objSpeed`, so a teleporting carrier loses the object and the object stays (nearly) where it was.

	  Clamp.objSpeed(walkSpeeds, speedSlack)   slowest carrier's server WalkSpeed x speedSlack
	  Clamp.step(from, to, p) -> (vector, limited)
	      p = { speed, dt, maxDt, riseSpeed, fallSpeed }
	      horizontal: at most speed x min(dt, maxDt); vertical: at most riseSpeed x dt up, fallSpeed x dt down
	  Clamp.teleportCap(walkSpeed, dt, lagSeconds)   a per-sample jump no walking player reaches
	      (Movement's formula at its defaults: max(16, WalkSpeed) x 1.15 x (dt + lag) + 1)
]]

local Clamp = {}

function Clamp.objSpeed(walkSpeeds: { number }, speedSlack: number): number
	local slowest = math.huge
	for _, ws in walkSpeeds do
		slowest = math.min(slowest, ws)
	end
	if slowest == math.huge then
		slowest = 16
	end
	return slowest * speedSlack
end

function Clamp.step(from: vector, to: vector, p: any): (vector, boolean)
	local dt = math.min(p.dt, p.maxDt)
	local limited = false
	local dx, dz = to.x - from.x, to.z - from.z
	local len = math.sqrt(dx * dx + dz * dz)
	local maxStep = p.speed * dt
	if len > maxStep then
		local k = if len > 0 then maxStep / len else 0
		dx, dz = dx * k, dz * k
		limited = true
	end
	local dy = to.y - from.y
	local up, down = p.riseSpeed * dt, p.fallSpeed * dt
	if dy > up then
		dy = up
		limited = true
	elseif dy < -down then
		dy = -down
		limited = true
	end
	return vector.create(from.x + dx, from.y + dy, from.z + dz), limited
end

function Clamp.teleportCap(walkSpeed: number, dt: number, lagSeconds: number): number
	return math.max(16, walkSpeed) * 1.15 * (dt + lagSeconds) + 1
end

return Clamp
