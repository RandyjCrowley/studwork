--# selene: allow(global_usage)
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")

local saves = DataStoreService:GetDataStore("PlayerData", "v1")
local GEM_PACK = 1000001

MarketplaceService.ProcessReceipt = function(receiptInfo)
	local key = "Player_" .. receiptInfo.PlayerId
	if receiptInfo.ProductId == GEM_PACK then
		saves:UpdateAsync(key, function(old)
			old.Gems += 100
			return old
		end)
	elseif receiptInfo.ProductId == 1000002 then
		local data = _G.Data[receiptInfo.PlayerId]
		table.insert(data.Pets, math.random(1, 3))
		saves:SetAsync(key, data)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end
