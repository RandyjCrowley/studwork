-- Passes: gamepass ownership (cached), and purchases made in game.
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ids = require(ReplicatedStorage.Shared.Passes)

local Passes = {}
local cache = {}

function Passes.owns(player, name)
	cache[player] = cache[player] or {}
	if cache[player][name] == nil then
		local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, Ids[name])
		if not ok then
			return false
		end
		cache[player][name] = owns
	end
	return cache[player][name]
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
	if not purchased then
		return
	end
	for name, id in pairs(Ids) do
		if id == passId then
			cache[player] = cache[player] or {}
			cache[player][name] = true
		end
	end
end)

return Passes
