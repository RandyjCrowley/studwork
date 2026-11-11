-- ShopGui: the coin shop window, the daily button and the coin pack button.
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local gui = script.Parent
local frame = gui:WaitForChild("Frame")
local list = frame:WaitForChild("List")
local player = Players.LocalPlayer

local COIN_PACK = 1234567

local function refresh()
	local items, owned = Remotes.GetShop:InvokeServer()
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	for id, item in pairs(items) do
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(1, 0, 0, 30)
		button.Text = item.name .. " - " .. item.price .. " coins" .. (table.find(owned, id) and " (owned)" or "")
		button.Parent = list
		button.MouseButton1Click:Connect(function()
			Remotes.BuyItem:FireServer(id)
			task.wait(0.5)
			refresh()
		end)
	end
end

frame:WaitForChild("Daily").MouseButton1Click:Connect(function()
	Remotes.ClaimDaily:FireServer()
end)
frame:WaitForChild("CoinPack").MouseButton1Click:Connect(function()
	MarketplaceService:PromptProductPurchase(player, COIN_PACK)
end)

refresh()
