--!strict
--[[
	Pure responsive-sizing helpers (zero dependencies).

	Components are authored in "design pixels" for a phone-landscape baseline (short side 400 px). Responsive.scale picks a
	UIScale for the viewport so the same layout grows on tablets/desktop and never shrinks below
	MIN_SCALE. Responsive.touchTarget(minPx) returns the design-pixel size that still meets
	`minPx` real pixels at MIN_SCALE (so touch targets stay >= 44 px on every device).
]]

local Responsive = {}

Responsive.BASE_SHORT_SIDE = 400
Responsive.MIN_SCALE = 0.85
Responsive.MAX_SCALE = 1.75

function Responsive.scale(width: number, height: number): number
	if width ~= width or height ~= height or width <= 0 or height <= 0 then
		return 1
	end
	local short = math.min(width, height)
	local s = short / Responsive.BASE_SHORT_SIDE
	return math.clamp(s, Responsive.MIN_SCALE, Responsive.MAX_SCALE)
end

function Responsive.touchTarget(minPx: number): number
	return math.ceil(minPx / Responsive.MIN_SCALE)
end

return Responsive
