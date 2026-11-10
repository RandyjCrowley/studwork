--!strict
--[[
	Sandbox client: starts Core, mounts the core HUD, and a small action bar built from the UI kit
	(upgrade, chest roll, Robux egg roll with its odds table, rebirth).

	Paid random items: the odds the server replicates (Core.Client.state().odds) are shown for
	both the Chest and the Robux egg before rolling/buying, and players whose policy restricts
	paid random items never get the purchase prompt (the server refuses their paid rolls too).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = require(ReplicatedStorage:WaitForChild("Core"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local ReactCharm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactCharm"))
local ReactRoblox = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactRoblox"))
local UI = require(ReplicatedStorage:WaitForChild("UI"))

local Charm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Charm"))

local e = React.createElement

Core.start(Config)

-- v1.2 mailbox: the HUD shows "Mailbox (N)" while gifts wait (full inventory); tapping opens this.
local mailboxOpen = Charm.atom(false)

local function rebirthCost(rebirths: number): number
	local r = Config.balance.rebirth :: any
	return math.floor(r.baseCost * r.costGrowth ^ rebirths)
end

Core.Client.Hud.mount({
	onMailbox = function()
		mailboxOpen(true)
	end,
	nextGoal = function()
		local state = Core.Client.state()
		if not state.data then
			return nil
		end
		local coins = state.data.currency[Config.balance.primaryCurrency] or 0
		local cost = rebirthCost(state.data.rebirths)
		if coins >= cost then
			return "Rebirth ready!"
		end
		return "Next: rebirth at " .. UI.Format.abbreviate(cost)
	end,
})

local function upgradeCost(level: number): number
	local u = (Config.balance.upgrades :: any).IncomeBoost
	return math.floor(u.baseCost * u.costGrowth ^ level)
end

local function ActionBar()
	local state = ReactCharm.useAtom(Core.Client.state)
	local oddsFor_, setOddsFor = React.useState("")
	local showMailbox = ReactCharm.useAtom(mailboxOpen)
	local mailRows: { [string]: any } = {}
	local mailbox: { any } = state.mailbox or {}
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
				Core.Client.Actions.claimMail(entry.id)
			end,
		})
	end
	local data = state.data
	local level = if data then (data.upgrades.IncomeBoost or 0) else 0
	local chestCost = (Config.balance.rarityTables :: any).Chest.cost.amount
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
					Core.Client.Actions.upgrade("IncomeBoost")
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
					Core.Client.Actions.rebirth()
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
					detail = (state.odds or {})[oddsFor_],
					items = Config.items,
					restricted = state.paidRandomRestricted,
					layoutOrder = 1,
				})
				else nil,
			Open = if oddsFor_ == "Chest" and not state.paidRandomRestricted
				then e(UI.Button, {
					text = "Open chest (" .. UI.Format.abbreviate(chestCost) .. ")",
					layoutOrder = 2,
					onActivated = function()
						Core.Client.Actions.roll("Chest")
					end,
				})
				else nil,
			Buy = if oddsFor_ == "Egg" and not state.paidRandomRestricted
				then e(UI.Button, {
					text = if eggProduct == 0 then "Buy (product not created yet)" else "Buy egg",
					disabled = eggProduct == 0,
					layoutOrder = 2,
					onActivated = function()
						if eggProduct ~= 0 and not Core.Client.state().paidRandomRestricted then
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
screen.DisplayOrder = 10 -- above the core HUD (5) so modals (odds) cover it
screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local root = ReactRoblox.createRoot(screen)
root:render(e(UI.ScaledRoot, nil, { Actions = e(ActionBar) }))
