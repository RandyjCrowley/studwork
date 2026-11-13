--!strict
--[[
	Slab: the analytic segment-vs-OBB test behind the volume sweep (carry.md, Movement "Checks"). Pure, zero
	engine queries. A volume's box is built once (`Slab.box`, from its CF and size); `Slab.crosses` then moves
	the segment into the volume's local space and runs the three slabs, behind a world-AABB reject.

	`crosses(box, a, b)` is true when the segment a -> b ENTERS or passes through the box: it touches the box
	and `a` is not already inside it. A player who stays inside a volume therefore counts once (the sample
	that entered), not on every sample (no strike storm while standing in or walking around inside it).
]]

local CF = require(script.Parent.CF)

export type Box = {
	-- inverse rotation (row-major) and inverse translation: local = ir * world + ip
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number,
	px: number,
	py: number,
	pz: number,
	hx: number,
	hy: number,
	hz: number,
	-- world AABB (broad phase)
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number,
}

local Slab = {}

function Slab.box(cf: CF.CF, size: vector): Box
	local inv = CF.inverse(cf)
	local m, r = inv.r, cf.r
	local hx, hy, hz = size.x * 0.5, size.y * 0.5, size.z * 0.5
	-- world half extents of the OBB
	local ex = math.abs(r[1]) * hx + math.abs(r[2]) * hy + math.abs(r[3]) * hz
	local ey = math.abs(r[4]) * hx + math.abs(r[5]) * hy + math.abs(r[6]) * hz
	local ez = math.abs(r[7]) * hx + math.abs(r[8]) * hy + math.abs(r[9]) * hz
	local c = cf.p
	return {
		r00 = m[1],
		r01 = m[2],
		r02 = m[3],
		r10 = m[4],
		r11 = m[5],
		r12 = m[6],
		r20 = m[7],
		r21 = m[8],
		r22 = m[9],
		px = inv.p.x,
		py = inv.p.y,
		pz = inv.p.z,
		hx = hx,
		hy = hy,
		hz = hz,
		minX = c.x - ex,
		minY = c.y - ey,
		minZ = c.z - ez,
		maxX = c.x + ex,
		maxY = c.y + ey,
		maxZ = c.z + ez,
	}
end

-- one slab: updates (tmin, tmax); returns false when the segment misses it
local function slab(o: number, d: number, h: number, tmin: number, tmax: number): (boolean, number, number)
	if math.abs(d) < 1e-9 then
		if o < -h or o > h then
			return false, tmin, tmax
		end
		return true, tmin, tmax
	end
	local t1, t2 = (-h - o) / d, (h - o) / d
	if t1 > t2 then
		t1, t2 = t2, t1
	end
	if t1 > tmin then
		tmin = t1
	end
	if t2 < tmax then
		tmax = t2
	end
	return tmin <= tmax, tmin, tmax
end

function Slab.contains(box: Box, p: vector): boolean
	local x, y, z = p.x, p.y, p.z
	local lx = box.r00 * x + box.r01 * y + box.r02 * z + box.px
	local ly = box.r10 * x + box.r11 * y + box.r12 * z + box.py
	local lz = box.r20 * x + box.r21 * y + box.r22 * z + box.pz
	return math.abs(lx) <= box.hx and math.abs(ly) <= box.hy and math.abs(lz) <= box.hz
end

function Slab.crosses(box: Box, a: vector, b: vector): boolean
	local ax, ay, az, bx, by, bz = a.x, a.y, a.z, b.x, b.y, b.z
	-- broad phase: the segment's AABB against the box's world AABB
	if
		(ax < box.minX and bx < box.minX)
		or (ax > box.maxX and bx > box.maxX)
		or (ay < box.minY and by < box.minY)
		or (ay > box.maxY and by > box.maxY)
		or (az < box.minZ and bz < box.minZ)
		or (az > box.maxZ and bz > box.maxZ)
	then
		return false
	end
	local lax = box.r00 * ax + box.r01 * ay + box.r02 * az + box.px
	local lay = box.r10 * ax + box.r11 * ay + box.r12 * az + box.py
	local laz = box.r20 * ax + box.r21 * ay + box.r22 * az + box.pz
	if math.abs(lax) <= box.hx and math.abs(lay) <= box.hy and math.abs(laz) <= box.hz then
		return false -- already inside at the start: the entry was an earlier sample
	end
	local lbx = box.r00 * bx + box.r01 * by + box.r02 * bz + box.px
	local lby = box.r10 * bx + box.r11 * by + box.r12 * bz + box.py
	local lbz = box.r20 * bx + box.r21 * by + box.r22 * bz + box.pz
	local ok, tmin, tmax = slab(lax, lbx - lax, box.hx, 0, 1)
	if not ok then
		return false
	end
	ok, tmin, tmax = slab(lay, lby - lay, box.hy, tmin, tmax)
	if not ok then
		return false
	end
	ok = slab(laz, lbz - laz, box.hz, tmin, tmax)
	return ok
end

return Slab
