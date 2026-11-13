--!strict
--[[
	Box: oriented-box tests for Carry (pure; positions are vectors, orientation is ./CF.luau).

	  Box.distance(cf, size, point)           distance from a point to the closest point of the box (0 inside)
	  Box.contains(cf, size, point, grow?)    the point is inside the box grown by `grow` studs on every side
	  Box.containsBox(zoneCf, zoneSize, cf, size, eps?)  all 8 corners of the second box inside the first
	  Box.corners(cf, size)                   the 8 world-space corners
]]

local CF = require(script.Parent.CF)

local Box = {}

local function localPoint(cf: CF.CF, point: vector): vector
	return CF.pointTo(CF.inverse(cf), point)
end

function Box.distance(cf: CF.CF, size: vector, point: vector): number
	local l = localPoint(cf, point)
	local hx, hy, hz = size.x * 0.5, size.y * 0.5, size.z * 0.5
	local dx = math.max(math.abs(l.x) - hx, 0)
	local dy = math.max(math.abs(l.y) - hy, 0)
	local dz = math.max(math.abs(l.z) - hz, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Box.contains(cf: CF.CF, size: vector, point: vector, grow: number?): boolean
	local l = localPoint(cf, point)
	local g = grow or 0
	return math.abs(l.x) <= size.x * 0.5 + g
		and math.abs(l.y) <= size.y * 0.5 + g
		and math.abs(l.z) <= size.z * 0.5 + g
end

function Box.corners(cf: CF.CF, size: vector): { vector }
	local hx, hy, hz = size.x * 0.5, size.y * 0.5, size.z * 0.5
	local out: { vector } = {}
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				table.insert(out, CF.pointTo(cf, vector.create(sx * hx, sy * hy, sz * hz)))
			end
		end
	end
	return out
end

function Box.containsBox(zoneCf: CF.CF, zoneSize: vector, cf: CF.CF, size: vector, eps: number?): boolean
	local inv = CF.inverse(zoneCf)
	local e = eps or 1e-4
	local hx, hy, hz = zoneSize.x * 0.5 + e, zoneSize.y * 0.5 + e, zoneSize.z * 0.5 + e
	for _, corner in Box.corners(cf, size) do
		local l = CF.pointTo(inv, corner)
		if math.abs(l.x) > hx or math.abs(l.y) > hy or math.abs(l.z) > hz then
			return false
		end
	end
	return true
end

return Box
