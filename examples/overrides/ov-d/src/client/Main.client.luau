--!strict
--[[
	The game's client: StudWork.start(Config), the framework HUD (StudWork.Client.Hud), and a
	small action bar built from the UI kit, driving the kit modules' client actions
	(StudWork.use(X).actions.y, §9) and reading their replicated slices (StudWork.use(X).state(),
	§10). Its buttons (tools/new-game keeps the lines of the modules you chose):
	  - chest roll for Coins and the Robux egg roll, each with its odds table (Rarity)

	Paid random items: the odds the server discloses (Rarity's replicated `odds`) are shown for
	both the Chest and the Robux egg before rolling/buying, and players whose policy restricts
	paid random items never get the purchase prompt (the server refuses their paid rolls too).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local ReactCharm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactCharm"))
local ReactRoblox = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactRoblox"))
local UI = require(ReplicatedStorage:WaitForChild("UI"))

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module"))

local e = React.createElement

StudWork.start(Config)

local Client = StudWork.Client
local rarity = StudWork.use(Rarity)

Client.Hud.mount({})

local function ActionBar()
	local state = ReactCharm.useAtom(Client.state)
	local raritySlice = ReactCharm.useAtom(rarity.state)
	local oddsFor_, setOddsFor = React.useState("")
	local restricted = if state.framework then state.framework.paidRandomRestricted ~= false else true
	local odds = (raritySlice.extra and raritySlice.extra.odds) or {}
	local eggProduct = Config.products.devProducts.EggRoll

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
			Egg = e(UI.Button, {
				text = "Robux egg",
				variant = "secondary",
				layoutOrder = 3,
				onActivated = function()
					setOddsFor("Egg")
				end,
			}),
		}),
		-- Both rolls are paid random items (Robux egg; Chest costs Coins, which are sold for
		-- Robux), so the exact odds are always shown before rolling and restricted players get
		-- no roll button.
		Odds = e(UI.Modal, {
			open = oddsFor_ ~= "",
			title = if oddsFor_ == "Egg" then "Robux egg" else "Chest",
			onClose = function()
				setOddsFor("")
			end,
		}, {
			Table = if oddsFor_ ~= ""
				then e(UI.OddsTable, {
					title = false, -- the Modal shows the title; one title only (v1.6.2)
					-- the SERVER's full disclosure (Rarity.getOddsDetail), never computed here
					detail = odds[oddsFor_],
					items = Config.items,
					restricted = restricted,
					layoutOrder = 1,
				})
				else nil,
			Buy = if oddsFor_ == "Egg" and not restricted
				then e(UI.Button, {
					text = if eggProduct == 0 then "Buy (product not created yet)" else "Buy egg",
					disabled = eggProduct == 0,
					layoutOrder = 2,
					onActivated = function()
						if eggProduct ~= 0 and Client.state().framework.paidRandomRestricted == false then
							MarketplaceService:PromptProductPurchase(Players.LocalPlayer, eggProduct)
						end
					end,
				})
				else nil,
		}),
	})
end

local screen = Instance.new("ScreenGui")
screen.Name = "SandboxActions"
screen.ResetOnSpawn = false
screen.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling -- UI.Modal layers its panel by sibling order
screen.DisplayOrder = 10 -- above the framework HUD (5) so modals (odds) cover it
screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local root = ReactRoblox.createRoot(screen)
root:render(e(UI.ScaledRoot, nil, { Actions = e(ActionBar) }))
