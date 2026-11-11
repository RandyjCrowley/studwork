-- hud: rebirth/boost/product buttons, and xp orbs to collect.
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Events = ReplicatedStorage:WaitForChild("Events")
local plr = Players.LocalPlayer

shared.Settings = shared.Settings or { orbs = 8 }

local gui = Instance.new("ScreenGui")
gui.ResetOnSpawn = false
gui.Parent = plr:WaitForChild("PlayerGui")

local function btn(text, y, fn)
	local b = Instance.new("TextButton")
	b.Text = text
	b.Size = UDim2.new(0, 180, 0, 34)
	b.Position = UDim2.new(1, -192, 1, -y)
	b.Parent = gui
	b.MouseButton1Click:Connect(fn)
end

btn("Rebirth", 44, function()
	Events.Rebirth:FireServer()
end)
btn("2x boost (500 coins)", 84, function()
	Events.BuyBoost:InvokeServer()
end)
btn("500 coins (R$)", 124, function()
	MarketplaceService:PromptProductPurchase(plr, 5555)
end)
btn("+1 rebirth (R$)", 164, function()
	MarketplaceService:PromptProductPurchase(plr, 5556)
end)

local giveXp = Events:WaitForChild("GiveXP")
for i = 1, shared.Settings.orbs do
	local orb = Instance.new("Part")
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(2, 2, 2)
	orb.Anchored = true
	orb.CanCollide = false
	orb.BrickColor = BrickColor.new("Cyan")
	orb.Position = Vector3.new(math.random(-60, 60), 2, math.random(-60, 60))
	orb.Parent = workspace
	orb.Touched:Connect(function(hit)
		if hit.Parent == plr.Character and orb.Transparency == 0 then
			orb.Transparency = 1
			giveXp:FireServer(25)
			task.delay(15, function()
				orb.Position = Vector3.new(math.random(-60, 60), 2, math.random(-60, 60))
				orb.Transparency = 0
			end)
		end
	end)
end
