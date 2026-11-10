--!strict
--[[
	Core.Streak. OWNED BY AGENT E (core/e-meta). Public API: Types.StreakAPI.

	PHASE 0 STUB: UTC day index = os.time() // 86400; same day = no change; next day = +1;
	otherwise reset to 1 (no grace window yet). Fires onDaily + StreakAdvanced when the day counts.
	Agent E: pure day math with graceHours + tests, reward table (rewards/loopAfter), analytics.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local HandlerList =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("HandlerList"))

local Streak = {}

local ctx: any = nil
local handlers = HandlerList.new()

function Streak.init(context: any)
	ctx = context
end

function Streak.start()
	ctx.services.Data.onLoaded(function(player: Player, data: Types.PlayerData)
		local today = os.time() // 86400
		local s = data.streak
		if s.lastDay == today then
			return
		end
		local newDay = if s.lastDay == today - 1 then s.day + 1 else 1
		ctx.services.Data.update(player, function(d: Types.PlayerData)
			d.streak = { day = newDay, lastDay = today }
		end)
		ctx.signals.StreakAdvanced:Fire(player, newDay)
		handlers:fire(player, newDay)
	end)
end

function Streak.onDaily(handler: (player: Player, streakDay: number) -> ()): Types.Connection
	return handlers:add(handler)
end

function Streak.get(player: Player): Types.StreakState
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	return if data then table.clone(data.streak) else { day = 0, lastDay = 0 }
end

return Streak
