--!strict
--[[
	Which sandbox HUD elements show, decided by feature flags (docs/framework/kits/environments.md).
	Pure: the client passes StudWork.flags.isOn, a spec passes a fake. A flag that is switched at
	run time (`flags set leaderboardButton false` in the Studio console) changes the answer
	without a restart, and the client re-renders when the replicated flags change.

	  leaderboardButton  the HUD button that opens the Leaderboards screen (default on)
	  debugPanel         a debug-only label with the environment (testOnly: never on in live)
]]

local HudRules = {}

HudRules.LEADERBOARD_FLAG = "leaderboardButton"
HudRules.DEBUG_FLAG = "debugPanel"
-- the board the HUD button opens (Balance.Leaderboards.boards)
HudRules.BOARD = "dailyTouches"

export type Visible = { leaderboards: boolean, debug: boolean }

function HudRules.visible(isOn: (string) -> boolean): Visible
	local function on(name: string): boolean
		local ok, value = pcall(isOn, name)
		return ok and value == true
	end
	return {
		leaderboards = on(HudRules.LEADERBOARD_FLAG),
		debug = on(HudRules.DEBUG_FLAG),
	}
end

return HudRules
