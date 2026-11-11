-- Shop: the gem pack developer product. Granted purchase ids are kept in the profile.
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Sessions = require(script.Parent.Sessions)
local Ids = require(ReplicatedStorage.Shared.Passes)

MarketplaceService.ProcessReceipt = function(receipt)
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	local profile = player and Sessions.profiles[player]
	if not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if profile.Data.Purchases[receipt.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if receipt.ProductId == Ids.GemPack then
		profile.Data.gems += 100
	else
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	profile.Data.Purchases[receipt.PurchaseId] = true
	Sessions.pushState(player)
	-- ProfileService saves the profile (and the purchase id) on its next autosave
	return Enum.ProductPurchaseDecision.PurchaseGranted
end
