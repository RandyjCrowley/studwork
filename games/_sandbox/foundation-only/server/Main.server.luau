--!strict
--[[
	Foundation-only server: boots Core with modules = {} and exercises foundation services.
	Expected output on join:
	  [foundation-only] boot ok
	  [foundation-only] Core.Rebirth.rebirth -> <... Rebirth is not enabled in GameConfig.modules>
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = require(ReplicatedStorage:WaitForChild("Core"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))

Core.start(Config, { admins = {} })

Core.Events.schedule("Ping", nil, function(ctx)
	print("[foundation-only] event Ping started, ends at " .. ctx.endsAt)
end)

print("[foundation-only] boot ok")

Core.Data.onLoaded(function(player: Player)
	Core.Data.updateGame(player, function(g)
		g.joins = (g.joins or 0) + 1
	end)
	Core.Analytics.custom(player, "FoundationOnlyJoin", 1)
	-- Deliberately calls a module that is off, to show the error. -- guard: allow modules
	local ok, err = pcall(Core.Rebirth.rebirth, player) -- guard: allow modules
	print(`[foundation-only] Core.Rebirth.rebirth -> ok={ok} {tostring(err)}`) -- guard: allow modules
end)

Players.PlayerRemoving:Connect(function(player)
	print("[foundation-only] bye " .. player.Name)
end)
