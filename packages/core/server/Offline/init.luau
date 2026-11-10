--!strict
--[[
	Core.Offline. OWNED BY AGENT B (core/b-economy). Public API: Types.OfflineAPI.

	In Data.onLoaded (Data guarantees lastSeen = previous session's last save/leave and
	stats.sessions already incremented): secondsAway = clamp(now - lastSeen, 0, capSeconds),
	skipped on first session or below minSeconds. If offline.autoPay, pays
	floor(Economy.getRate * secondsAway * payoutFraction) with reason "offline" and sends a "pop"
	feedback. onReturn handlers always run (when secondsAway >= minSeconds).

	Ordering: Economy computes the rate directly from PlayerData (displayed/inventory, rebirths,
	upgrade levels, saved multipliers), never from Plot/Instance state, and getRate recomputes on
	demand. So the rate is correct inside onLoaded regardless of which service's onLoaded handler
	runs first. Session-only boosts (co-play, passes applied later) are deliberately excluded.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local HandlerList =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("HandlerList"))
local OfflineMath = require(script.OfflineMath)

local Offline = {}

local ctx: any = nil
local handlers = HandlerList.new()

local function onLoaded(player: Player, data: Types.PlayerData)
	local o = ctx.config.balance.offline
	local away = OfflineMath.secondsAway(os.time(), data.lastSeen, data.stats.sessions, o)
	if away == nil then
		return
	end
	if o.autoPay then
		local amount = OfflineMath.payout(ctx.services.Economy.getRate(player), away, o.payoutFraction)
		if amount > 0 and ctx.services.Economy.grant(player, amount, "offline") then
			ctx.net.feedback(player, "pop", "+" .. tostring(amount))
		end
	end
	handlers:fire(player, away)
end

function Offline.init(context: any)
	ctx = context
end

function Offline.start()
	ctx.services.Data.onLoaded(onLoaded)
end

function Offline.onReturn(handler: (player: Player, secondsAway: number) -> ()): Types.Connection
	return handlers:add(handler)
end

return Offline
