--!strict
--[[
	The GameConfig (v1.3.0 shape, module-api.md §3, §11). The server and client scripts both
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
	gameId = "carry-demo",
	modules = {
		require(Modules:WaitForChild("Carry"):WaitForChild("module")),
		require(Modules:WaitForChild("Movement"):WaitForChild("module")),
	} :: { any },
	config = require(script.Balance),
	items = require(script.Items),
	products = require(script.Products),
	-- shop = { passPrefetchTimeout = 2 }, -- seconds a join waits for gamepass lookups (0-5)
	events = require(script.Events),
	-- Environments and flags (docs/framework/kits/environments.md). The test and live place ids
	-- come from deploy.json: `tools/sync-projects` writes Environments.luau. Flags switch behaviour
	-- per environment; a testOnly flag can never be on in live.
	environments = require(script.Environments),
	flags = {},
	-- flags = { newShop = { default = false, studio = true, test = true } },
	-- flagOverride = { enabled = true, keyPrefix = "flag_", refreshSeconds = 30 }, -- live override from Roblox configs
	-- Strings (docs/framework/kits/localization.md): reword any string key or add your own game.*
	-- keys. Translations come from src/shared/Localization/*.csv (mapped into LocalizationService).
	-- The example key below has a Spanish row in src/shared/Localization/game.csv; use it with
	-- StudWork.text("game.welcome", { name = "Sam" }) (client) or ctx.text.format (server).
	strings = {
		["game.welcome"] = "Welcome back, {name}!",
	},
	-- localization = { sourceLocale = "en", useTranslators = true },
	-- storeBudgets = { orderedReserve = 0.25, memory = { reserve = 0.2, defaultShare = 0.25, shares = {} } }, -- module-api.md §23.5
	client = {
		palette = require(script.Palette), -- legacy per-game colour overrides (hex), applied last
		-- Override points (docs/framework/override-levels.md level 3). Uncomment to use.
		-- The HUD (docs/framework/theme.md#hud): nil / "default" = the default slot layout.
		-- hud = false, -- no HUD at all (toasts and screens still work)
		-- hud = script.Parent.MyHud, -- src/shared/MyHud.luau: a ModuleScript returning a React component
		-- hud = {
		-- 	layout = "default", -- or false, or a component / ModuleScript as above
		-- 	widgets = {
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
	analytics = {
		funnel = {
			"Joined",
			"FirstCollect",
		},
		clientSteps = {},
	},
}

return Config
