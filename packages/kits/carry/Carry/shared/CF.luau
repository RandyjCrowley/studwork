--!strict
--[[
	CF: the carry kit's tiny CFrame math (a position plus a row-major 3x3 rotation), so blends,
	clamps, arcs and sweeps are pure functions the Lune specs can run (the harness has no CFrame).

	There are two byte-identical copies, Carry/shared/CF.luau and Movement/shared/CF.luau (the
	modules never share Lua state); tests/SharedCopies.spec.luau fails when they differ. Change
	both or neither.

	  CF = { p: vector, r: { number } }   r = { r00, r01, r02, r10, r11, r12, r20, r21, r22 },
	  columns are the right, up and back axes (-Z is forward, like Roblox).

	  CF.new(p, r?)                     r defaults to the identity
	  CF.fromParts(x, y, z, r00 .. r22)  the argument order of CFrame.new(x, y, z, r00 .. r22)
	  CF.mul(a, b)                      a * b (b expressed in a's space)
	  CF.inverse(a)
	  CF.pointTo(a, v)                  a * v: a local point to world
	  CF.rotate(a, v)                   a's rotation applied to a direction
	  CF.lerp(a, b, t)                  position lerp, rotation nlerp on the shortest quaternion arc
	  CF.lookAlong(p, dir, up?)         -Z along dir, up as close to `up` (default world up) as possible
	  CF.lookVector / upVector / rightVector (a)
	  CF.toCFrame(a) / CF.fromCFrame(cf)   live adapter only (need the engine's CFrame)
]]

export type CF = { p: vector, r: { number } }

local CF = {}

local function identity(): { number }
	return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

function CF.new(p: vector, r: { number }?): CF
	return { p = p, r = r or identity() }
end

function CF.fromParts(
	x: number,
	y: number,
	z: number,
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number
): CF
	return { p = vector.create(x, y, z), r = { r00, r01, r02, r10, r11, r12, r20, r21, r22 } }
end

local function rot(r: { number }, v: vector): vector
	return vector.create(
		r[1] * v.x + r[2] * v.y + r[3] * v.z,
		r[4] * v.x + r[5] * v.y + r[6] * v.z,
		r[7] * v.x + r[8] * v.y + r[9] * v.z
	)
end

function CF.rotate(a: CF, v: vector): vector
	return rot(a.r, v)
end

function CF.pointTo(a: CF, v: vector): vector
	return a.p + rot(a.r, v)
end

function CF.mul(a: CF, b: CF): CF
	local x, y = a.r, b.r
	local r = table.create(9, 0)
	for i = 0, 2 do
		for j = 0, 2 do
			r[i * 3 + j + 1] = x[i * 3 + 1] * y[j + 1] + x[i * 3 + 2] * y[j + 4] + x[i * 3 + 3] * y[j + 7]
		end
	end
	return { p = a.p + rot(x, b.p), r = r }
end

function CF.inverse(a: CF): CF
	local m = a.r
	local t = { m[1], m[4], m[7], m[2], m[5], m[8], m[3], m[6], m[9] }
	return { p = -rot(t, a.p), r = t }
end

function CF.rightVector(a: CF): vector
	return vector.create(a.r[1], a.r[4], a.r[7])
end

function CF.upVector(a: CF): vector
	return vector.create(a.r[2], a.r[5], a.r[8])
end

function CF.lookVector(a: CF): vector
	return vector.create(-a.r[3], -a.r[6], -a.r[9])
end

function CF.lookAlong(p: vector, dir: vector, up: vector?): CF
	local look = vector.normalize(dir)
	local upRef = up or vector.create(0, 1, 0)
	local right = vector.cross(look, upRef)
	if vector.magnitude(right) < 1e-6 then
		-- looking along the up reference: pick any perpendicular axis
		local alt = if math.abs(look.x) < 0.9 then vector.create(1, 0, 0) else vector.create(0, 0, 1)
		right = vector.cross(look, alt)
	end
	right = vector.normalize(right)
	local upAxis = vector.cross(right, look)
	local back = -look
	return {
		p = p,
		r = { right.x, upAxis.x, back.x, right.y, upAxis.y, back.y, right.z, upAxis.z, back.z },
	}
end

-- rotation matrix -> unit quaternion (w, x, y, z)
local function toQuat(m: { number }): (number, number, number, number)
	local trace = m[1] + m[5] + m[9]
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		return 0.25 * s, (m[8] - m[6]) / s, (m[3] - m[7]) / s, (m[4] - m[2]) / s
	elseif m[1] > m[5] and m[1] > m[9] then
		local s = math.sqrt(1 + m[1] - m[5] - m[9]) * 2
		return (m[8] - m[6]) / s, 0.25 * s, (m[2] + m[4]) / s, (m[3] + m[7]) / s
	elseif m[5] > m[9] then
		local s = math.sqrt(1 + m[5] - m[1] - m[9]) * 2
		return (m[3] - m[7]) / s, (m[2] + m[4]) / s, 0.25 * s, (m[6] + m[8]) / s
	end
	local s = math.sqrt(1 + m[9] - m[1] - m[5]) * 2
	return (m[4] - m[2]) / s, (m[3] + m[7]) / s, (m[6] + m[8]) / s, 0.25 * s
end

local function fromQuat(w: number, x: number, y: number, z: number): { number }
	return {
		1 - 2 * (y * y + z * z),
		2 * (x * y - z * w),
		2 * (x * z + y * w),
		2 * (x * y + z * w),
		1 - 2 * (x * x + z * z),
		2 * (y * z - x * w),
		2 * (x * z - y * w),
		2 * (y * z + x * w),
		1 - 2 * (x * x + y * y),
	}
end

function CF.lerp(a: CF, b: CF, t: number): CF
	local p = a.p + (b.p - a.p) * t
	local aw, ax, ay, az = toQuat(a.r)
	local bw, bx, by, bz = toQuat(b.r)
	if aw * bw + ax * bx + ay * by + az * bz < 0 then
		bw, bx, by, bz = -bw, -bx, -by, -bz
	end
	local w, x, y, z = aw + (bw - aw) * t, ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t
	local n = math.sqrt(w * w + x * x + y * y + z * z)
	return { p = p, r = fromQuat(w / n, x / n, y / n, z / n) }
end

-- Live adapter only: the engine's CFrame (a spec under Lune never calls these).
function CF.toCFrame(a: CF): any
	local r = a.r
	return (CFrame :: any).new(a.p.x, a.p.y, a.p.z, r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9])
end

function CF.fromCFrame(cf: any): CF
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return CF.fromParts(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

return CF
