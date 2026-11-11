local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
remotes.BuyItem:FireServer("sword", 1)
MarketplaceService:PromptProductPurchase(Players.LocalPlayer, 1000001)
