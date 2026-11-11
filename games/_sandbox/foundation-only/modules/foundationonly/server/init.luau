--!strict
--[[
	Foundation-only server module: exercises the framework services with no kit enabled.
	Expected output on join:
	  [foundation-only] Rebirth.rebirth -> ok=false <... Rebirth is not enabled in GameConfig.modules>
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rebirth =
	require(ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Economy"):WaitForChild("Rebirth"))

local FoundationOnly = {}

function FoundationOnly.init(ctx: any)
	ctx.events.schedule("Ping", nil, function(event: any)
		print("[foundation-only] event Ping started, ends at " .. event.endsAt)
	end)
	ctx.data.onLoaded(function(player: Player)
		ctx.data.update(player, function(s: any)
			s.joins = (s.joins or 0) + 1
		end)
		ctx.analytics.custom(player, "FoundationOnlyJoin", 1)
		-- Deliberately calls a module that is off, to show the error.
		local ok, err = pcall(function()
			return ctx.deps[Rebirth].rebirth(player)
		end)
		print(`[foundation-only] Rebirth.rebirth -> ok={ok} {tostring(err)}`)
	end)
	ctx.lifecycle.onPlayerRemoving(function(player: Player)
		print("[foundation-only] bye " .. player.Name)
	end)
end

return FoundationOnly
