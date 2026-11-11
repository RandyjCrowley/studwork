--!strict
--[[
	The sandbox GameConfig (core-v1.3.0 shape, module-api.md §3, §11). The server and client
	scripts both pass it to StudWork.start. Sandbox loop: touch the glowing block -> get an item
	-> it goes on your plot -> it earns.

	modules: kit module refs (the game's own module, examples/sandbox/modules/sandbox, is added by
	the framework; the game never lists itself). Listed in the v1.2 boot order, which the
	framework keeps (ties = list order), so the kit modules start in the same order as the v1.2
	services did.
	config: each module's config (config.<Name>, Balance.luau); compliance.paidCurrencies: the
	Robux-buyable currencies (framework, §14).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")

local Config = {
	gameId = "sandbox",
	-- The sandbox exercises every kit module.
	modules = {
		require(Modules:WaitForChild("Items"):WaitForChild("module")),
		require(Modules:WaitForChild("Rarity"):WaitForChild("module")),
		require(Modules:WaitForChild("Inventory"):WaitForChild("module")),
		require(Modules:WaitForChild("Economy"):WaitForChild("module")),
		require(Modules:WaitForChild("Upgrades"):WaitForChild("module")),
		require(Modules:WaitForChild("Rebirth"):WaitForChild("module")),
		require(Modules:WaitForChild("Offline"):WaitForChild("module")),
		require(Modules:WaitForChild("Streak"):WaitForChild("module")),
		require(Modules:WaitForChild("Friends"):WaitForChild("module")),
		require(Modules:WaitForChild("Mail"):WaitForChild("module")),
		require(Modules:WaitForChild("Plot"):WaitForChild("module")),
	} :: { any },
	config = require(script.Balance),
	-- Coins are sold for Robux (CoinPack), so the Coin-priced Chest is a paid random item too.
	compliance = { paidCurrencies = { "Coins" } },
	items = require(script.Items),
	products = require(script.Products),
	events = require(script.Events),
	client = { palette = require(script.Palette) },
	analytics = {
		funnel = { "Joined", "FirstCollect", "FirstUpgrade", "FirstRebirth" },
		clientSteps = {},
	},
}

return Config
