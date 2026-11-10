--!strict
--[[
	The sandbox GameConfig. Both the server and client scripts pass this to Core.start.
	Sandbox loop: touch the glowing block -> get an item -> it goes on your plot -> it earns.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Config: Types.GameConfig = {
	gameId = "sandbox",
	-- Optional core modules (the foundation is always on). The sandbox exercises all of them.
	modules = {
		"Items",
		"Inventory",
		"Rarity",
		"Economy",
		"Upgrades",
		"Rebirth",
		"Offline",
		"Streak",
		"Friends",
		"Mail",
		"Plot",
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
