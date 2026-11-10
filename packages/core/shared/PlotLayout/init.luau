--!strict
--[[
	Pure plot layout math. OWNED BY AGENT D (core/d-plot).

	PHASE 0 STUB: grid of slot offsets. Agent D extends (rows/cols from slotCount, spacing,
	ring layout for generated plots) with Lune tests.
]]

local PlotLayout = {}

-- Returns local (x, z) offsets for `count` slots in a grid centred on the origin.
function PlotLayout.grid(count: number, spacing: number): { { x: number, z: number } }
	local cols = math.max(1, math.ceil(math.sqrt(count)))
	local rows = math.ceil(count / cols)
	local offsets = {}
	for i = 0, count - 1 do
		local col = i % cols
		local row = i // cols
		table.insert(offsets, {
			x = (col - (cols - 1) / 2) * spacing,
			z = (row - (rows - 1) / 2) * spacing,
		})
	end
	return offsets
end

return PlotLayout
