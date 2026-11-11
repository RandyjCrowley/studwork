--!strict
--[[
	What the core HUD shows for the enabled modules (pure).
	  currency/rate: only with Economy (no currencies without it); rate also honours opts.showRate.
	  goal: whenever the game passes opts.nextGoal (the text is game-defined, any module set).
	  mailbox: the mailbox badge slot, only with Mail (v1.2, N1); drawn while mailboxCount > 0.
]]

local Slices = require(script.Parent.Slices)

local Visibility = {}

export type Shown = { currency: boolean, rate: boolean, goal: boolean, mailbox: boolean }

-- Number of held mailbox messages (0 when absent or malformed). Reads Mail's client slice
-- (state.modules.Mail.extra.mailbox) and, for a v1.2 flat state, state.mailbox.
function Visibility.mailboxCount(state: any): number
	local box = Slices.extra(state, "Mail", "mailbox")
	if type(box) ~= "table" then
		return 0
	end
	local n = 0
	for _ in box do
		n += 1
	end
	return n
end

function Visibility.of(
	isEnabled: (name: string) -> boolean,
	opts: { showRate: boolean?, nextGoal: any? }
): Shown
	local economy = isEnabled("Economy")
	return {
		currency = economy,
		rate = economy and opts.showRate ~= false,
		goal = opts.nextGoal ~= nil,
		mailbox = isEnabled("Mail"),
	}
end

return Visibility
