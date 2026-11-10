--!strict
--[[
	Pure plot layout math. OWNED BY AGENT D (core/d-plot). Zero Roblox dependencies.

	Generates local slot offsets (studs, relative to the plot centre, on the XZ plane) that a game
	or tool can turn into "SlotId" pads, e.g.:
		for i, o in PlotLayout.grid(8, { cols = 4, spacingX = 8, spacingZ = 10 }) do
			pad.CFrame = base.CFrame * CFrame.new(o.x, 0.7, o.z)
			pad:SetAttribute("SlotId", PlotLayout.slotId(i))
		end
		for i, p in PlotLayout.ring(6, 12) do
			pad.CFrame = base.CFrame * CFrame.new(p.x, 0.7, p.z) * CFrame.Angles(0, p.yaw, 0)
		end

	All functions return entries in slot order (index 1 = first slot = "slot01").
	Invalid input (count < 1, NaN, negative spacing) yields an empty list / falls back to defaults;
	nothing here errors.
]]

export type Offset = { x: number, z: number }
export type Placement = { x: number, z: number, yaw: number } -- yaw (radians) about +Y

export type GridOptions = {
	cols: number?, -- default ceil(sqrt(count)) (or derived from rows)
	rows: number?, -- when only rows is given, cols = ceil(count / rows)
	spacing: number?, -- both axes (default 8)
	spacingX: number?, -- overrides spacing on X
	spacingZ: number?, -- overrides spacing on Z
}

local DEFAULT_SPACING = 8

local PlotLayout = {}

local function finite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function count(n: number): number
	if not finite(n) or n < 1 then
		return 0
	end
	return math.floor(n)
end

local function nonNegative(n: number?, fallback: number): number
	if n ~= nil and finite(n) and n >= 0 then
		return n
	end
	return fallback
end

-- Grid dimensions for `n` slots: (cols, rows). (0, 0) for n < 1.
function PlotLayout.dimensions(n: number, opts: GridOptions?): (number, number)
	local total = count(n)
	if total == 0 then
		return 0, 0
	end
	local cols: number
	if opts and opts.cols and finite(opts.cols) and opts.cols >= 1 then
		cols = math.floor(opts.cols)
	elseif opts and opts.rows and finite(opts.rows) and opts.rows >= 1 then
		cols = math.ceil(total / math.floor(opts.rows))
	else
		cols = math.ceil(math.sqrt(total))
	end
	cols = math.min(cols, total)
	return cols, math.ceil(total / cols)
end

-- `n` offsets centred on the origin, filled row by row (X = column, Z = row).
-- Back-compat with the Phase 0 stub: PlotLayout.grid(count, spacing) still works.
function PlotLayout.grid(n: number, spacingOrOpts: (number | GridOptions)?): { Offset }
	local opts: GridOptions = if type(spacingOrOpts) == "number"
		then { spacing = spacingOrOpts }
		elseif type(spacingOrOpts) == "table" then spacingOrOpts
		else {}
	local total = count(n)
	local cols, rows = PlotLayout.dimensions(total, opts)
	local spacing = nonNegative(opts.spacing, DEFAULT_SPACING)
	local sx = nonNegative(opts.spacingX, spacing)
	local sz = nonNegative(opts.spacingZ, spacing)
	local offsets: { Offset } = {}
	for i = 0, total - 1 do
		local col = i % cols
		local row = i // cols
		table.insert(offsets, {
			x = (col - (cols - 1) / 2) * sx,
			z = (row - (rows - 1) / 2) * sz,
		})
	end
	return offsets
end

-- `n` placements evenly spaced on a circle of `radius` around the origin: slot i sits at angle
-- startAngle + (i-1)/n * 2pi, position (cos a * r, sin a * r). `yaw` rotates a pad so its front
-- (-Z) faces the centre: CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0).
function PlotLayout.ring(n: number, radius: number, startAngle: number?): { Placement }
	local total = count(n)
	local r = nonNegative(radius, 0)
	local start = if startAngle ~= nil and finite(startAngle) then startAngle else 0
	local out: { Placement } = {}
	for i = 0, total - 1 do
		local angle = start + i / total * 2 * math.pi
		local x, z = math.cos(angle) * r, math.sin(angle) * r
		-- front of a Y-rotated part = (-sin yaw, 0, -cos yaw); we want it along (-x, -z)
		table.insert(out, { x = x, z = z, yaw = math.atan2(x, z) })
	end
	return out
end

-- Footprint (width on X, depth on Z) a grid needs between the outer slot centres, plus
-- `padding` studs on each side.
function PlotLayout.gridSize(n: number, opts: GridOptions?, padding: number?): (number, number)
	local o: GridOptions = opts or {}
	local cols, rows = PlotLayout.dimensions(n, o)
	local spacing = nonNegative(o.spacing, DEFAULT_SPACING)
	local pad = nonNegative(padding, 0) * 2
	if cols == 0 then
		return pad, pad
	end
	return (cols - 1) * nonNegative(o.spacingX, spacing) + pad,
		(rows - 1) * nonNegative(o.spacingZ, spacing) + pad
end

-- Conventional slot id for index i: "slot01", "slot02", ... (matches the sandbox world).
function PlotLayout.slotId(i: number): string
	return string.format("slot%02d", math.max(0, math.floor(if finite(i) then i else 0)))
end

return PlotLayout
