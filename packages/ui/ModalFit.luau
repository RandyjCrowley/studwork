--!strict
--[[
	Pure sizing rule for UI.Modal: the panel (title and close button included) must fit in 92% x
	88% of the screen. fitScale returns the UIScale (<= 1) that makes a panel of the given
	UNSCALED size fit; 1 when it already fits or a size is unknown (0).
]]

local ModalFit = {}

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
