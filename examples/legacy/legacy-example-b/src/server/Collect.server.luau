-- Collect: coins the client picks up from the coin piles around the map.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Sessions = require(script.Parent.Sessions)
local Passes = require(script.Parent.Passes)

ReplicatedStorage.Remotes.Collect.OnServerEvent:Connect(function(player, amount)
	local profile = Sessions.profiles[player]
	if not profile then
		return
	end
	local mult = if Passes.owns(player, "VIP") then 2 else 1
	Sessions.addCoins(player, amount * mult)
	profile.Data.stats.collected += amount
end)
