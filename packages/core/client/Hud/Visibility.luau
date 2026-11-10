--!strict
--[[
	What the core HUD shows for the enabled modules (pure).
	  currency/rate: only with Economy (no currencies without it); rate also honours opts.showRate.
	  goal: only with Rebirth (the "next goal" pill is the rebirth goal) and when opts.nextGoal is set.
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
		goal = isEnabled("Rebirth") and opts.nextGoal ~= nil,
	}
end

return Visibility
