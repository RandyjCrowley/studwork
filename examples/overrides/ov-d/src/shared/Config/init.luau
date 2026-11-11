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
	gameId = "ov-d",
	modules = {
		require(Modules:WaitForChild("Items"):WaitForChild("module")), -- item definitions; needed by Inventory and Rarity
		require(Modules:WaitForChild("Rarity"):WaitForChild("module")), -- weighted rolls, luck, pity, mutations, odds (needs Items)
		require(Modules:WaitForChild("Inventory"):WaitForChild("module")), -- owned item copies, gifting, cap (needs Items)
	} :: { any },
	config = require(script.Balance),
	items = require(script.Items),
	products = require(script.Products),
	events = require(script.Events),
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
	-- them to theme.rarity, so the UI picks up their colours, glows and soundKeys).
	analytics = {
		funnel = {
			"Joined",
			"FirstCollect",
		},
		clientSteps = {},
	},
}

return Config
