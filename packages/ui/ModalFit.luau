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

return ModalFit
