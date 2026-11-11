--!strict
--[[
	Sandbox client: StudWork.start(Config), the framework HUD (StudWork.Client.Hud), and a small
	action bar built from the UI kit (upgrade, chest roll, Robux egg roll with its odds table,
	rebirth), driving the kit modules'
	client actions (StudWork.use(X).actions.y, §9) and reading their replicated slices
	(StudWork.use(X).state(), §10).

	Paid random items: the odds the server discloses (Rarity's replicated `odds`) are shown for
	both the Chest and the Robux egg before rolling/buying, and players whose policy restricts
	paid random items never get the purchase prompt (the server refuses their paid rolls too).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local Balance = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"):WaitForChild("Balance"))
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local ReactCharm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactCharm"))
local ReactRoblox = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactRoblox"))
local UI = require(ReplicatedStorage:WaitForChild("UI"))

local Charm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Charm"))

local KitDefs = ReplicatedStorage:WaitForChild("Kits")
local Rarity = require(KitDefs:WaitForChild("Collection"):WaitForChild("Rarity"))
local EconomyDef = require(KitDefs:WaitForChild("Economy"):WaitForChild("Economy"))
local Upgrades = require(KitDefs:WaitForChild("Economy"):WaitForChild("Upgrades"))
local Rebirth = require(KitDefs:WaitForChild("Economy"):WaitForChild("Rebirth"))
local Mail = require(KitDefs:WaitForChild("Social"):WaitForChild("Mail"))

local e = React.createElement

StudWork.start(Config)

local Client = StudWork.Client
local economy = StudWork.use(EconomyDef)
local upgrades = StudWork.use(Upgrades)
local rebirth = StudWork.use(Rebirth)
local rarity = StudWork.use(Rarity)
local mail = StudWork.use(Mail)
local PRIMARY = Balance.Economy.primaryCurrency

-- The mailbox: the HUD shows "Mailbox (N)" while gifts wait (full inventory); tapping opens this.
local mailboxOpen = Charm.atom(false)

local function rebirthCost(rebirths: number): number
	local r = Balance.Rebirth.rebirth
	return math.floor(r.baseCost * r.costGrowth ^ rebirths)
end

Client.Hud.mount({
	onMailbox = function()
		mailboxOpen(true)
	end,
	nextGoal = function(): string?
		local money = economy.state().data
		local reborn = rebirth.state().data
		if not money or not reborn then
			return nil
		end
		local coins = money.currency[PRIMARY] or 0
		local cost = rebirthCost(reborn.rebirths or 0)
		if coins >= cost then
			return "Rebirth ready!"
		end
		return "Next: rebirth at " .. UI.Format.abbreviate(cost)
	end,
})

local function upgradeCost(level: number): number
	local u = Balance.Upgrades.upgrades.IncomeBoost
	return math.floor(u.baseCost * u.costGrowth ^ level)
end

local function ActionBar()
	local state = ReactCharm.useAtom(Client.state)
	local upgradeSlice = ReactCharm.useAtom(upgrades.state)
	local raritySlice = ReactCharm.useAtom(rarity.state)
	local mailSlice = ReactCharm.useAtom(mail.state)
	local oddsFor_, setOddsFor = React.useState("")
	local showMailbox = ReactCharm.useAtom(mailboxOpen)
	local restricted = if state.framework then state.framework.paidRandomRestricted ~= false else true
	local mailRows: { [string]: any } = {}
	local mailbox: { any } = (mailSlice.extra and mailSlice.extra.mailbox) or {}
	for i, entry in mailbox do
		local itemId = if type(entry.payload) == "table" then entry.payload.itemId else nil
		local item = if type(entry.payload) == "table" and type(entry.payload.item) == "table"
			then entry.payload.item.itemId
			else itemId
		mailRows["Row" .. i] = e(UI.Button, {
			text = "Claim " .. tostring(item or entry.kind),
			variant = "secondary",
			layoutOrder = i,
			onActivated = function()
				mail.actions.claimMail(entry.id)
			end,
		})
	end
	local levels = upgradeSlice.data and upgradeSlice.data.upgrades
	local level = if levels then (levels.IncomeBoost or 0) else 0
	local odds = (raritySlice.extra and raritySlice.extra.odds) or {}
	local chestCost = Balance.Rarity.rarityTables.Chest.cost.amount
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
			Upgrade = e(UI.Button, {
				text = "Upgrade income (" .. UI.Format.abbreviate(upgradeCost(level)) .. ")",
				layoutOrder = 1,
				onActivated = function()
					upgrades.actions.upgrade("IncomeBoost")
				end,
			}),
			Chest = e(UI.Button, {
				text = "Chest (" .. UI.Format.abbreviate(chestCost) .. ")",
				variant = "secondary",
				layoutOrder = 2,
				onActivated = function()
					setOddsFor("Chest")
				end,
			}),
			Egg = e(UI.Button, {
				text = "Robux egg",
				variant = "secondary",
				layoutOrder = 3,
				onActivated = function()
					setOddsFor("Egg")
				end,
			}),
			Rebirth = e(UI.Button, {
				text = "Rebirth",
				variant = "danger",
				layoutOrder = 4,
				onActivated = function()
					rebirth.actions.rebirth()
				end,
			}),
		}),
		Mailbox = e(UI.Modal, {
			open = showMailbox and #mailbox > 0,
			title = "Mailbox",
			onClose = function()
				mailboxOpen(false)
			end,
		}, mailRows),
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
					-- the SERVER's full disclosure (Rarity.getOddsDetail), never computed here
					detail = odds[oddsFor_],
					items = Config.items,
					restricted = restricted,
					layoutOrder = 1,
				})
				else nil,
			Open = if oddsFor_ == "Chest" and not restricted
				then e(UI.Button, {
					text = "Open chest (" .. UI.Format.abbreviate(chestCost) .. ")",
					layoutOrder = 2,
					onActivated = function()
						rarity.actions.roll("Chest")
					end,
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
screen.DisplayOrder = 10 -- above the framework HUD (5) so modals (odds) cover it
screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local root = ReactRoblox.createRoot(screen)
root:render(e(UI.ScaledRoot, nil, { Actions = e(ActionBar) }))
