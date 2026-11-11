--!strict
--[[
	The game's client: StudWork.start(Config), the framework HUD (StudWork.Client.Hud), and a
	small action bar built from the UI kit, driving the kit modules' client actions
	(StudWork.use(X).actions.y, §9) and reading their replicated slices (StudWork.use(X).state(),
	§10). Its buttons (tools/new-game keeps the lines of the modules you chose):
	  - upgrade (Upgrades) -- @if Upgrades
	  - chest roll for Coins and the Robux egg roll, each with its odds table (Rarity) -- @if Rarity
	  - rebirth (Rebirth) -- @if Rebirth
	  - the mailbox (Mail): claim waiting gifts -- @if Mail

	Paid random items: the odds the server discloses (Rarity's replicated `odds`) are shown for
	both the Chest and the Robux egg before rolling/buying, and players whose policy restricts
	paid random items never get the purchase prompt (the server refuses their paid rolls too).
]]

local MarketplaceService = game:GetService("MarketplaceService") -- @if Rarity,Inventory
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local Balance = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"):WaitForChild("Balance")) -- @if Economy,Rebirth|Upgrades|Rarity,Economy
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local ReactCharm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactCharm")) -- @if Rarity|Upgrades|Mail
local ReactRoblox = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactRoblox"))
local UI = require(ReplicatedStorage:WaitForChild("UI"))

local Charm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Charm")) -- @if Mail

local KitDefs = ReplicatedStorage:WaitForChild("Kits")
local Rarity = require(KitDefs:WaitForChild("Collection"):WaitForChild("Rarity")) -- @if Rarity
local EconomyDef = require(KitDefs:WaitForChild("Economy"):WaitForChild("Economy")) -- @if Economy,Rebirth
local Upgrades = require(KitDefs:WaitForChild("Economy"):WaitForChild("Upgrades")) -- @if Upgrades
local Rebirth = require(KitDefs:WaitForChild("Economy"):WaitForChild("Rebirth")) -- @if Rebirth
local Mail = require(KitDefs:WaitForChild("Social"):WaitForChild("Mail")) -- @if Mail

local e = React.createElement

StudWork.start(Config)

local Client = StudWork.Client
local economy = StudWork.use(EconomyDef) -- @if Economy,Rebirth
local upgrades = StudWork.use(Upgrades) -- @if Upgrades
local rebirth = StudWork.use(Rebirth) -- @if Rebirth
local rarity = StudWork.use(Rarity) -- @if Rarity
local mail = StudWork.use(Mail) -- @if Mail
local PRIMARY = Balance.Economy.primaryCurrency -- @if Economy,Rebirth

-- @if Mail
-- The mailbox: the HUD shows "Mailbox (N)" while gifts wait (full inventory); tapping opens this.
local mailboxOpen = Charm.atom(false)
-- @end

-- @if Economy,Rebirth
local function rebirthCost(rebirths: number): number
	local r = Balance.Rebirth.rebirth
	return math.floor(r.baseCost * r.costGrowth ^ rebirths)
end
-- @end

Client.Hud.mount({
	-- @if Mail
	onMailbox = function()
		mailboxOpen(true)
	end,
	-- @end
	-- @if Economy,Rebirth
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
	-- @end
})

-- @if Upgrades
local function upgradeCost(level: number): number
	local u = Balance.Upgrades.upgrades.IncomeBoost
	return math.floor(u.baseCost * u.costGrowth ^ level)
end
-- @end

local function ActionBar()
	-- @if Rarity
	local state = ReactCharm.useAtom(Client.state)
	local raritySlice = ReactCharm.useAtom(rarity.state)
	local oddsFor_, setOddsFor = React.useState("")
	local restricted = if state.framework then state.framework.paidRandomRestricted ~= false else true
	local odds = (raritySlice.extra and raritySlice.extra.odds) or {}
	-- @end
	-- @if Upgrades
	local upgradeSlice = ReactCharm.useAtom(upgrades.state)
	local levels = upgradeSlice.data and upgradeSlice.data.upgrades
	local level = if levels then (levels.IncomeBoost or 0) else 0
	-- @end
	-- @if Mail
	local mailSlice = ReactCharm.useAtom(mail.state)
	local showMailbox = ReactCharm.useAtom(mailboxOpen)
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
	-- @end
	local chestCost = Balance.Rarity.rarityTables.Chest.cost.amount -- @if Rarity,Economy
	local eggProduct = Config.products.devProducts.EggRoll -- @if Rarity,Inventory

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
			-- @if Upgrades
			Upgrade = e(UI.Button, {
				text = "Upgrade income (" .. UI.Format.abbreviate(upgradeCost(level)) .. ")",
				layoutOrder = 1,
				onActivated = function()
					upgrades.actions.upgrade("IncomeBoost")
				end,
			}),
			-- @end
			-- @if Rarity,Economy
			Chest = e(UI.Button, {
				text = "Chest (" .. UI.Format.abbreviate(chestCost) .. ")",
				variant = "secondary",
				layoutOrder = 2,
				onActivated = function()
					setOddsFor("Chest")
				end,
			}),
			-- @end
			-- @if Rarity,Inventory
			Egg = e(UI.Button, {
				text = "Robux egg",
				variant = "secondary",
				layoutOrder = 3,
				onActivated = function()
					setOddsFor("Egg")
				end,
			}),
			-- @end
			-- @if Rebirth
			Rebirth = e(UI.Button, {
				text = "Rebirth",
				variant = "danger",
				layoutOrder = 4,
				onActivated = function()
					rebirth.actions.rebirth()
				end,
			}),
			-- @end
		}),
		-- @if Mail
		Mailbox = e(UI.Modal, {
			open = showMailbox and #mailbox > 0,
			title = "Mailbox",
			onClose = function()
				mailboxOpen(false)
			end,
		}, mailRows),
		-- @end
		-- @if Rarity
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
			-- @if Economy
			Open = if oddsFor_ == "Chest" and not restricted
				then e(UI.Button, {
					text = "Open chest (" .. UI.Format.abbreviate(chestCost) .. ")",
					layoutOrder = 2,
					onActivated = function()
						rarity.actions.roll("Chest")
					end,
				})
				else nil,
			-- @end
			-- @if Inventory
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
			-- @end
		}),
		-- @end
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
