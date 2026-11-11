--!strict
--[[
	The GameConfig (core-v1.3.0 shape, module-api.md §3, §11). The server and client scripts both
	pass it to StudWork.start. Template loop: touch the glowing block -> get an item -> it goes on
	your plot -> it earns.

	modules: kit module refs. The game's own module (modules/<gameId>: module.luau + server/) is
	added by the framework; the game never lists itself. A module's hard dependencies must stay
	listed (StudWork.start names the missing one). Calling a module that is not listed errors:
	"<Name> is not enabled in GameConfig.modules". `tools/new-game <name> --modules A,B` writes
	only the chosen modules' lines, config, items fields and game code; to drop a module later by
	hand, also remove it from modules/<gameId>/module.luau `dependsOn`, its section in
	Balance.luau and the game code that uses it.
	config: each module's config (config.<Name>, Balance.luau); compliance.paidCurrencies: the
	Robux-buyable currencies (framework, §14).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")

local Config = {
	gameId = "ov-c",
	modules = {
		require(Modules:WaitForChild("Items"):WaitForChild("module")), -- item definitions; needed by Inventory and Rarity
		require(Modules:WaitForChild("Rarity"):WaitForChild("module")), -- weighted rolls, luck, pity, mutations, odds (needs Items)
		require(Modules:WaitForChild("Inventory"):WaitForChild("module")), -- owned item copies, gifting, cap (needs Items)
		require(Modules:WaitForChild("Economy"):WaitForChild("module")), -- currencies, income ticks, multipliers
		require(Modules:WaitForChild("Upgrades"):WaitForChild("module")), -- level upgrades bought with currency (needs Economy)
		require(Modules:WaitForChild("Rebirth"):WaitForChild("module")), -- reset for a permanent multiplier (needs Economy)
		require(Modules:WaitForChild("Offline"):WaitForChild("module")), -- payout for time away (autoPay needs Economy)
		require(Modules:WaitForChild("Streak"):WaitForChild("module")), -- daily UTC streak with grace (rewards need Economy)
		require(Modules:WaitForChild("Friends"):WaitForChild("module")), -- co-play detection + optional income bonus
		require(Modules:WaitForChild("Mail"):WaitForChild("module")), -- cross-server / offline messages + mailbox (idempotent handlers)
		require(Modules:WaitForChild("Plot"):WaitForChild("module")), -- per-player plots with item display slots (needs Inventory)
	} :: { any },
	config = require(script.Balance),
	-- Coins are sold for Robux (CoinPack), so the Coin-priced Chest is a paid random item too.
	-- List every currency players can buy with Robux: rolls priced in one follow the paid
	-- random item rules (odds disclosure, PolicyService). compliance = {} if none is sold.
	compliance = { paidCurrencies = { "Coins" } },
	items = require(script.Items),
	products = require(script.Products),
	events = require(script.Events),
	client = {
		palette = require(script.Palette), -- legacy per-game colour overrides (hex), applied last
		-- override (c): the whole HUD replaced with this game's layout, mailbox widget removed
		hud = {
			layout = script.Parent:WaitForChild("MyHud"),
			widgets = { ["Social.mailbox"] = false },
		},
		-- Override points (docs/framework/override-levels.md level 3). Uncomment to use.
		-- The HUD (docs/framework/theme.md#hud): nil / "default" = the default slot layout.
		-- hud = false, -- no HUD at all (toasts and screens still work)
		-- hud = script.Parent.MyHud, -- src/shared/MyHud.luau: a ModuleScript returning a React component
		-- hud = {
		-- 	layout = "default", -- or false, or a component / ModuleScript as above
		-- 	widgets = {
		-- 		["Social.mailbox"] = false, -- remove a default widget
		-- 		["Economy.currency"] = { slot = "topRight", order = 1, component = MyCounter },
		-- 		["Game.nextGoal"] = false,
		-- 	},
		-- },
	},
	-- The theme (docs/framework/theme.md): merged as framework-default preset -> each module's
	-- contribution -> this table. Partial: only what you name changes. Colours are "#RRGGBB".
	-- theme = {
	-- 	preset = "framework-default", -- or a preset table (itself layered on framework-default)
	-- 	colors = { accent = "#FFB547", accentAlt = "#5ED1C9", currency = "#FFD23F", background = "#1E2235" },
	-- 	fonts = {
	-- 		display = "rbxasset://fonts/families/FredokaOne.json",
	-- 		body = "rbxasset://fonts/families/BuilderSans.json",
	-- 	},
	-- 	metrics = { cornerRadius = 12, padding = 12, minTouchTarget = 44, text = { body = 18 } },
	-- 	sounds = { coin_tick = { id = 16480580213, volume = 0.35 }, purchase = { id = 17208380755 } },
	-- },
	-- Rarity tiers are config, not theme: config.Rarity.tiers in Balance.luau (Rarity contributes
	-- them to theme.rarity, so the UI picks up their colours, glows and soundKeys).
	analytics = {
		funnel = {
			"Joined",
			"FirstCollect",
			"FirstUpgrade",
			"FirstRebirth",
		},
		clientSteps = {},
	},
}

return Config
