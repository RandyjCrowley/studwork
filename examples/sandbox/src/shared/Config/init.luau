--!strict
--[[
	The sandbox GameConfig (v1.3.0 shape, module-api.md §3, §11). The server and client
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
	-- The sandbox exercises every kit module (the v1.8.0 kits at their defaults, plus the config
	-- in Balance.luau and ServerConfig.luau).
	modules = {
		require(Modules:WaitForChild("Items"):WaitForChild("module")),
		require(Modules:WaitForChild("Rarity"):WaitForChild("module")),
		require(Modules:WaitForChild("Inventory"):WaitForChild("module")),
		require(Modules:WaitForChild("Economy"):WaitForChild("module")),
		require(Modules:WaitForChild("Upgrades"):WaitForChild("module")),
		require(Modules:WaitForChild("Rebirth"):WaitForChild("module")),
		require(Modules:WaitForChild("Offline"):WaitForChild("module")),
		require(Modules:WaitForChild("Streak"):WaitForChild("module")),
		require(Modules:WaitForChild("Leaderboards"):WaitForChild("module")),
		require(Modules:WaitForChild("Badges"):WaitForChild("module")),
		require(Modules:WaitForChild("Notifications"):WaitForChild("module")),
		require(Modules:WaitForChild("Friends"):WaitForChild("module")),
		require(Modules:WaitForChild("Mail"):WaitForChild("module")),
		require(Modules:WaitForChild("TextFilter"):WaitForChild("module")),
		require(Modules:WaitForChild("Plot"):WaitForChild("module")),
		require(Modules:WaitForChild("Admin"):WaitForChild("module")),
		require(Modules:WaitForChild("Carry"):WaitForChild("module")),
		require(Modules:WaitForChild("Codes"):WaitForChild("module")),
		require(Modules:WaitForChild("Companions"):WaitForChild("module")),
		require(Modules:WaitForChild("Goals"):WaitForChild("module")),
		require(Modules:WaitForChild("Moderation"):WaitForChild("module")),
		require(Modules:WaitForChild("Movement"):WaitForChild("module")),
		require(Modules:WaitForChild("Quests"):WaitForChild("module")),
		require(Modules:WaitForChild("Reports"):WaitForChild("module")),
		require(Modules:WaitForChild("Settings"):WaitForChild("module")),
	} :: { any },
	config = require(script.Balance),
	-- Coins are sold for Robux (CoinPack), so the Coin-priced Chest is a paid random item too.
	compliance = { paidCurrencies = { "Coins" } },
	items = require(script.Items),
	products = require(script.Products),
	-- shop = { passPrefetchTimeout = 2 }, -- seconds a join waits for gamepass lookups (0-5)
	events = require(script.Events),
	-- Environments (generated from deploy.json by tools/sync-projects) and feature flags
	-- (docs/framework/kits/environments.md): one normal flag and one testOnly flag.
	environments = require(script.Environments),
	flags = {
		-- gates the HUD's Leaderboards button (src/shared/HudRules.luau): `flags set leaderboardButton
		-- false` in the Studio console hides it live, without a restart
		leaderboardButton = { default = true, description = "the HUD Leaderboards button" },
		newShop = { default = false, studio = true, test = true, description = "the redesigned shop screen" },
		debugPanel = {
			default = false,
			studio = true,
			test = true,
			testOnly = true,
			description = "developer overlay (a debug-only label in the HUD; never on in live)",
		},
	},
	-- Strings (docs/framework/kits/localization.md): a rewording of a UI kit key, and a game key.
	strings = {
		["ui.close"] = "Done",
		["game.welcome"] = "Welcome back, {name}!",
		["game.leaderboards"] = "Leaderboards", -- the HUD button; src/shared/Localization/game.csv has the es text
		["game.debug"] = "debug: {env}",
		["Moderation.ban.appeal"] = "Appeal on our group page.", -- the ban screen's appeal line
	},
	client = {
		palette = require(script.Palette),
		-- Goals draws its own next-goal pill (docs/framework/kits/quests.md), so the framework's
		-- "Game.nextGoal" pill (src/client/Main.client.luau's nextGoal) is hidden.
		hud = { widgets = { ["Game.nextGoal"] = false } },
	},
	analytics = {
		funnel = { "Joined", "FirstCollect", "FirstUpgrade", "FirstRebirth" },
		clientSteps = {},
	},
}

return Config
