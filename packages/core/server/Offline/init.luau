--!strict
--[[
	Core.Offline. OWNED BY AGENT B (core/b-economy). Public API: Types.OfflineAPI.

	PHASE 0 STUB: on DataLoaded (not first session), secondsAway = now - lastSeen, capped at
	offline.capSeconds; if autoPay, pays getRate * secondsAway * payoutFraction; runs handlers.
	Agent B: pure math + tests (cap, min, clock skew), analytics, feedback toast.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local HandlerList =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("HandlerList"))

local Offline = {}

local ctx: any = nil
local handlers = HandlerList.new()

function Offline.init(context: any)
	ctx = context
end

function Offline.start()
	ctx.services.Data.onLoaded(function(player: Player, data: Types.PlayerData)
		local o = ctx.config.balance.offline
		if data.lastSeen <= 0 then
			return
		end
		local away = math.clamp(os.time() - data.lastSeen, 0, o.capSeconds)
		if away < o.minSeconds then
			return
		end
		if o.autoPay then
			task.wait() -- let other onLoaded handlers (plot/upgrades) settle so the rate is right
			local amount = ctx.services.Economy.getRate(player) * away * o.payoutFraction
			if amount > 0 then
				ctx.services.Economy.grant(player, amount, "offline")
			end
		end
		handlers:fire(player, away)
	end)
end

function Offline.onReturn(handler: (player: Player, secondsAway: number) -> ()): Types.Connection
	return handlers:add(handler)
end

return Offline
