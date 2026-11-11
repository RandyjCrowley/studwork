-- Purchases: developer products (Robux), the Roblox sample pattern with a purchase history store.
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local purchaseHistory = DataStoreService:GetDataStore("PurchaseHistory")

local COIN_PACK = 1234567 -- 1000 coins

local handlers = {
	[COIN_PACK] = function(player)
		_G.AddCoins(player, 1000)
		return true
	end,
}

MarketplaceService.ProcessReceipt = function(receiptInfo)
	local playerProductKey = receiptInfo.PlayerId .. "_" .. receiptInfo.PurchaseId
	local ok, purchased = pcall(function()
		return purchaseHistory:GetAsync(playerProductKey)
	end)
	if ok and purchased then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local handler = handlers[receiptInfo.ProductId]
	if not handler then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local okGrant = pcall(handler, player)
	if not okGrant then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local okSave = pcall(function()
		purchaseHistory:SetAsync(playerProductKey, true)
	end)
	if not okSave then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end
