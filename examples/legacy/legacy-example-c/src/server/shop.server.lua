-- shop: robux products
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local PRODUCTS = {
	[5555] = function(plr) -- 500 coins
		_G.Stores[plr].coins:Increment(500, 0)
	end,
	[5556] = function(plr) -- skip a rebirth's cost: +1 rebirth
		_G.Stores[plr].rebirths:Increment(1, 0)
	end,
}

MarketplaceService.ProcessReceipt = function(info)
	local plr = Players:GetPlayerByUserId(info.PlayerId)
	if not plr or not _G.Stores[plr] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local grant = PRODUCTS[info.ProductId]
	if not grant then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	grant(plr)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end
