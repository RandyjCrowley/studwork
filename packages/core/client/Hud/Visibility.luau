--!strict
--[[
	What the core HUD shows for the enabled modules (pure).
	  currency/rate: only with Economy (no currencies without it); rate also honours opts.showRate.
	  goal: whenever the game passes opts.nextGoal (the text is game-defined, any module set).
]]

local Visibility = {}

export type Shown = { currency: boolean, rate: boolean, goal: boolean }

function Visibility.of(
	isEnabled: (name: string) -> boolean,
	opts: { showRate: boolean?, nextGoal: any? }
): Shown
	local economy = isEnabled("Economy")
	return {
		currency = economy,
		rate = economy and opts.showRate ~= false,
		goal = opts.nextGoal ~= nil,
	}
end

return Visibility
