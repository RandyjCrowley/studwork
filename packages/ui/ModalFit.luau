--!strict
--[[
	Pure sizing rule for UI.Modal: the panel (title and close button included) must fit in 92% x
	88% of the screen. fitScale returns the UIScale (<= 1) that makes a panel of the given
	UNSCALED size fit; 1 when it already fits or a size is unknown (0).
]]

local Responsive = require(script.Parent.Responsive)

local ModalFit = {}

-- A second scale may never make the smallest text fall below the real-pixel floor.
function ModalFit.minScale(tokens: any): number
	local metrics = tokens.metrics or {}
	local text = tokens.text or metrics.text or {}
	local smallest = math.min(text.min or text.small or 14, text.small or 14)
	return math.min(1, (metrics.minTextSize or 11) / (Responsive.MIN_SCALE * smallest * 0.94))
end

ModalFit.MAX_WIDTH_FRACTION = 0.92
ModalFit.MAX_HEIGHT_FRACTION = 0.88

function ModalFit.fitScale(panelX: number, panelY: number, screenX: number, screenY: number): number
	if panelX <= 0 or panelY <= 0 or screenX <= 0 or screenY <= 0 then
		return 1
	end
	return math.min(
		1,
		screenX * ModalFit.MAX_WIDTH_FRACTION / panelX,
		screenY * ModalFit.MAX_HEIGHT_FRACTION / panelY
	)
end

-- Height of the Modal's scrolling content area, in the content's own design pixels (v1.6.2):
--   screenAbsY   the backdrop's AbsoluteSize.Y (real pixels: every outer UIScale applied)
--   outerScale   the product of the UIScales ABOVE the Modal (e.g. ScaledRoot's responsive scale)
--   fit          the Modal's own fit UIScale
--   chrome       design px the panel needs besides its content (title, paddings, gaps)
--   content      the content's measured height in design px
-- The panel (chrome + content) stays inside MAX_HEIGHT_FRACTION of the screen; taller content
-- scrolls. Never below `floor` (a touch target), so a tiny screen still shows a scroll area.
function ModalFit.contentHeight(
	screenAbsY: number,
	outerScale: number,
	fit: number,
	chrome: number,
	content: number,
	floor: number
): number
	local s = math.max(outerScale, 0.01) * math.max(fit, 0.01)
	local available = math.max(floor, screenAbsY / s * ModalFit.MAX_HEIGHT_FRACTION - chrome)
	return math.max(0, math.min(content, available))
end

return ModalFit
