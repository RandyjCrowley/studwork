--!strict
local Math = {}
function Math.formation(slot: number, _count: number, spacing: number, behind: number): Vector3
	local index = slot - 1
	local side = if index % 3 == 0 then 0 elseif index % 3 == 1 then -spacing else spacing
	return Vector3.new(side, 0, behind + math.floor(index / 3) * spacing)
end
function Math.alpha(dt: number, speed: number): number
	return 1 - math.exp(-speed * math.clamp(dt, 0, 5))
end
function Math.snap(current: Vector3, target: Vector3, distance: number): boolean
	local x, y, z = current.X - target.X, current.Y - target.Y, current.Z - target.Z
	return x * x + y * y + z * z > distance * distance
end
function Math.motion(
	movement: string,
	t: number,
	speed: number,
	idleSpeed: number,
	reduced: boolean,
	low: boolean,
	bob: number,
	hz: number,
	hop: number
): Vector3
	if reduced or low then
		return Vector3.new(0, 0, 0)
	end
	local wave = math.sin(t * hz * 2 * math.pi)
	local moving = speed > idleSpeed
	local y = if not moving
		then wave * bob
		elseif movement == "hop" then math.max(0, wave) * hop
		elseif movement == "walk" then math.abs(wave) * bob
		else wave * bob
	return Vector3.new(0, y, 0)
end
function Math.rate(distance: number, config: any, low: boolean): number
	local hz = if distance <= config.nearDistance then config.nearHz else config.farHz
	return if low then math.min(hz, config.lowDetailHz) else hz
end
function Math.ground(groundY: number, centerY: number, sizeY: number): number
	return groundY - (centerY - sizeY / 2)
end
return Math
