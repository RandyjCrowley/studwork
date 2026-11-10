--!strict
--[[
	The sandbox GameConfig. Both the server and client scripts pass this to Core.start.
	Sandbox loop: touch the glowing block -> get an item -> it goes on your plot -> it earns.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Config: Types.GameConfig = {
	gameId = "sandbox",
	-- Optional core modules. The foundation (Data, Net, Shop, Analytics, Policy, Events, Console,
	-- Replication, UI kit, Feedback, Input, Hud) is always on. Delete the lines you don't need;
	-- a module's dependencies must stay listed (Core.start says which). Calling a module that is
	-- not listed errors: "<Name> is not enabled in GameConfig.modules". See CLAUDE.md "Modules".
	modules = {
		"Items", -- item definitions (Core.Items); needed by Inventory and Rarity
		"Inventory", -- owned item copies, gifting, cap (needs Items; balance.inventory)
		"Rarity", -- weighted rolls, luck, pity, mutations, odds disclosure (needs Items; balance.rarityTables)
		"Economy", -- currencies, income ticks, multipliers (balance.income)
		"Upgrades", -- level-based upgrades bought with currency (needs Economy; balance.upgrades)
		"Rebirth", -- reset for a permanent multiplier; keeps Robux items (needs Economy; balance.rebirth)
		"Offline", -- what returning players get for time away (balance.offline; autoPay needs Economy)
		"Streak", -- daily UTC streak with grace (balance.streak; rewards need Economy)
		"Friends", -- co-play detection + optional income bonus (balance.friends)
		"Mail", -- cross-server / offline messages + mailbox (handler false = held; must be idempotent)
		"Plot", -- per-player plots with item display slots (needs Inventory; balance.plot)
	},
	items = require(script.Items),
	balance = require(script.Balance),
	products = require(script.Products),
	events = require(script.Events),
	palette = require(script.Palette),
	data = {
		defaults = { blockTouches = 0 },
		version = 1,
	},
	analytics = {
		funnel = { "Joined", "FirstCollect", "FirstUpgrade", "FirstRebirth" },
		clientSteps = {},
	},
	assetsFolderName = "GameAssets",
}

return Config
