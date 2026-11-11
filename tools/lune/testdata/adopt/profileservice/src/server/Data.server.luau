local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ProfileService = require(script.Parent.ProfileService)

local ProfileStore = ProfileService.GetProfileStore("PlayerSaves", { Coins = 0, Purchases = {} })
local profiles = {}

Players.PlayerAdded:Connect(function(player)
	local profile = ProfileStore:LoadProfileAsync("Player_" .. player.UserId)
	if profile then
		profiles[player] = profile
	end
end)

local function grant(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and profiles[player]
	if profile == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if profile.Data.Purchases[receiptInfo.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	profile.Data.Purchases[receiptInfo.PurchaseId] = true
	if receiptInfo.ProductId == 2000001 then
		profile.Data.Coins += 500
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

MarketplaceService.ProcessReceipt = grant
