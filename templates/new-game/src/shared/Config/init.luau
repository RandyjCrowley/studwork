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
local KitDefs = ReplicatedStorage:WaitForChild("Kits")
local Collection = KitDefs:WaitForChild("Collection")
local Economy = KitDefs:WaitForChild("Economy")
local Base = KitDefs:WaitForChild("Base")
local Social = KitDefs:WaitForChild("Social")
local Engagement = KitDefs:WaitForChild("Engagement")

local Config = {
	gameId = "sandbox",
	modules = {
		require(Collection:WaitForChild("Items")), -- item definitions; needed by Inventory and Rarity
		require(Collection:WaitForChild("Rarity")), -- weighted rolls, luck, pity, mutations, odds (needs Items)
		require(Collection:WaitForChild("Inventory")), -- owned item copies, gifting, cap (needs Items)
		require(Economy:WaitForChild("Economy")), -- currencies, income ticks, multipliers
		require(Economy:WaitForChild("Upgrades")), -- level upgrades bought with currency (needs Economy)
		require(Economy:WaitForChild("Rebirth")), -- reset for a permanent multiplier (needs Economy)
		require(Economy:WaitForChild("Offline")), -- payout for time away (autoPay needs Economy)
		require(Engagement:WaitForChild("Streak")), -- daily UTC streak with grace (rewards need Economy)
		require(Social:WaitForChild("Friends")), -- co-play detection + optional income bonus
		require(Social:WaitForChild("Mail")), -- cross-server / offline messages + mailbox (idempotent handlers)
		require(Base:WaitForChild("Plot")), -- per-player plots with item display slots (needs Inventory)
	} :: { any },
	config = require(script.Balance),
	-- @if Economy
	-- Coins are sold for Robux (CoinPack), so the Coin-priced Chest is a paid random item too.
	compliance = { paidCurrencies = { "Coins" } },
	-- @end
	items = require(script.Items),
	products = require(script.Products),
	events = require(script.Events),
	client = { palette = require(script.Palette) },
	analytics = {
		funnel = {
			"Joined",
			"FirstCollect",
			"FirstUpgrade", -- @if Upgrades
			"FirstRebirth", -- @if Rebirth
		},
		clientSteps = {},
	},
}

return Config
