--!strict
--[[
	What the framework HUD itself shows (pure).
	  goal: whenever the game passes opts.nextGoal (the text is game-defined, any module set).
	core-v1.3.1 (R19): module widgets (the currency counter, the mailbox badge) are registered by
	their modules' client parts with UI.registerWidget and gated by their own module; the framework
	decides nothing per module.
]]

local Visibility = {}

export type Shown = { goal: boolean }

function Visibility.of(
	_isEnabled: (name: string) -> boolean,
	opts: { showRate: boolean?, nextGoal: any? }
): Shown
	return { goal = opts.nextGoal ~= nil }
end

return Visibility
