--!strict
--[[
	Sandbox client: starts Core, mounts the HUD and a few buttons (upgrade, rebirth, chest roll).
	Phase 0 uses plain Instances; the UI kit (packages/ui) replaces these in Phase 2.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Core = require(ReplicatedStorage:WaitForChild("Core"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))

Core.start(Config)

Core.Client.Hud.mount({
	nextGoal = function()
		local state = Core.Client.state()
		if not state.data then
			return nil
		end
		local coins = state.data.currency.Coins or 0
		local rebirthCost = Config.balance.rebirth.baseCost
			* Config.balance.rebirth.costGrowth ^ state.data.rebirths
		if coins >= rebirthCost then
			return "Rebirth ready!"
		end
		return string.format("Next: rebirth at %d", math.floor(rebirthCost))
	end,
})

local gui = Instance.new("ScreenGui")
gui.Name = "SandboxButtons"
gui.ResetOnSpawn = false
local list = Instance.new("Frame")
list.BackgroundTransparency = 1
list.Size = UDim2.fromScale(0.25, 0.3)
list.Position = UDim2.fromScale(0.02, 0.6)
list.Parent = gui
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.Parent = list

local function button(text: string, onClick: () -> ())
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 48)
	b.Text = text
	b.TextScaled = true
	b.Parent = list
	b.Activated:Connect(onClick)
end

button("Upgrade income", function()
	Core.Client.Actions.upgrade("IncomeBoost")
end)
button("Open chest (250)", function()
	Core.Client.Actions.roll("Chest")
end)
button("Rebirth", function()
	Core.Client.Actions.rebirth()
end)

gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
