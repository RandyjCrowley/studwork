--!strict
--[[
	The game's client: StudWork.start(Config), the framework HUD (StudWork.Client.Hud), and a
	small action bar built from the UI kit, driving the kit modules' client actions
	(StudWork.use(X).actions.y, §9) and reading their replicated slices (StudWork.use(X).state(),
	§10). Its buttons (tools/new-game keeps the lines of the modules you chose):

	Paid random items: the odds the server discloses (Rarity's replicated `odds`) are shown for
	both the Chest and the Robux egg before rolling/buying, and players whose policy restricts
	paid random items never get the purchase prompt (the server refuses their paid rolls too).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local ReactRoblox = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactRoblox"))
local UI = require(ReplicatedStorage:WaitForChild("UI"))

local e = React.createElement

StudWork.start(Config)

local Client = StudWork.Client

Client.Hud.mount({})

local function ActionBar()
	return e("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	}, {
		Bar = e("Frame", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, 0),
			-- top-right: bottom-left is the touch thumbstick and bottom-right the jump button
			Position = UDim2.new(1, -12, 0, 8),
			AnchorPoint = Vector2.new(1, 0),
		}, {
			Layout = UI.Primitives.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Right),
		}),
	})
end

local screen = Instance.new("ScreenGui")
screen.Name = "SandboxActions"
screen.ResetOnSpawn = false
screen.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
screen.DisplayOrder = 10 -- above the framework HUD (5) so modals (odds) cover it
screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local root = ReactRoblox.createRoot(screen)
root:render(e(UI.ScaledRoot, nil, { Actions = e(ActionBar) }))
