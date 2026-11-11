--# selene: allow(global_usage)
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local buy = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("BuyItem")

buy.OnServerEvent:Connect(function(player, itemId, amount)
	local data = _G.Data[player]
	data.Coins = data.Coins - amount
	data.Last = itemId
end)
