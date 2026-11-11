-- Hud: the custom UI (coins, gems, pets list with equip toggles, hatch, VIP, gem pack) and the
-- coin piles the player can pick up.
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PetsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pets"))
local Ids = require(ReplicatedStorage.Shared:WaitForChild("Passes"))

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "Hud"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local function label(name, y)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Size = UDim2.new(0, 200, 0, 28)
	l.Position = UDim2.new(0, 12, 0, y)
	l.BackgroundTransparency = 0.3
	l.Parent = gui
	return l
end

local function button(name, text, y, onClick)
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = text
	b.Size = UDim2.new(0, 200, 0, 32)
	b.Position = UDim2.new(1, -212, 0, y)
	b.Parent = gui
	b.MouseButton1Click:Connect(onClick)
	return b
end

local coins = label("Coins", 12)
local gems = label("Gems", 44)
local pets = Instance.new("Frame")
pets.Size = UDim2.new(0, 200, 0, 300)
pets.Position = UDim2.new(0, 12, 0, 84)
pets.BackgroundTransparency = 0.5
pets.Parent = gui
local layout = Instance.new("UIListLayout")
layout.Parent = pets

button("Hatch", "Hatch egg (" .. PetsConfig.egg.gemCost .. " gems)", 12, function()
	Remotes.Hatch:FireServer()
end)
button("Vip", "VIP: double coins", 50, function()
	MarketplaceService:PromptGamePassPurchase(player, Ids.VIP)
end)
button("Slots", "20 pet slots", 88, function()
	MarketplaceService:PromptGamePassPurchase(player, Ids.ExtraSlots)
end)
button("GemPack", "100 gems (Robux)", 126, function()
	MarketplaceService:PromptProductPurchase(player, Ids.GemPack)
end)

Remotes.StateChanged.OnClientEvent:Connect(function(data)
	coins.Text = "Coins: " .. data.coins
	gems.Text = "Gems: " .. data.gems
	for _, child in ipairs(pets:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	for _, pet in ipairs(data.pets) do
		local on = table.find(data.equipped, pet.uid) ~= nil
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, 0, 0, 26)
		b.Text = PetsConfig.pets[pet.id].name .. (on and " (equipped)" or "")
		b.Parent = pets
		b.MouseButton1Click:Connect(function()
			Remotes.Equip:FireServer(pet.uid, not on)
		end)
	end
end)

-- coin piles: touch one to pick it up (10 coins), it comes back after 10 seconds
for i = 1, 6 do
	local pile = Instance.new("Part")
	pile.Name = "CoinPile"
	pile.Anchored = true
	pile.CanCollide = false
	pile.Size = Vector3.new(3, 1, 3)
	pile.Position = Vector3.new(math.cos(i) * 30, 0.5, math.sin(i) * 30)
	pile.BrickColor = BrickColor.new("Bright yellow")
	pile.Parent = workspace
	local ready = true
	pile.Touched:Connect(function(hit)
		if ready and hit.Parent == player.Character then
			ready = false
			pile.Transparency = 0.8
			Remotes.Collect:FireServer(10)
			task.delay(10, function()
				ready = true
				pile.Transparency = 0
			end)
		end
	end)
end
