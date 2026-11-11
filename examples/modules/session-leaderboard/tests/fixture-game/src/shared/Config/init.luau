--!strict
-- Fixture game for tests/RealKits.spec.luau (override case f: the example module loaded next to
-- the real kit modules). Test fixture numbers, not a game's balance.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Collection = ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Collection")
local EconomyKit = ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Economy")
local GameModules = ReplicatedStorage:WaitForChild("Modules")

return {
	gameId = "leaderboard-fixture",
	modules = {
		require(Collection:WaitForChild("Items")),
		require(Collection:WaitForChild("Inventory")),
		require(EconomyKit:WaitForChild("Economy")),
		require(GameModules:WaitForChild("SessionLeaderboard"):WaitForChild("module")),
	} :: { any },
	config = {
		Economy = {
			primaryCurrency = "Coins",
			startingCurrency = { Coins = 0 },
			income = { tickSeconds = 1, source = "owned" },
			multiplierStacking = "multiply",
		},
		Inventory = { inventory = { cap = 10 }, starterItems = { "pebble" } },
		SessionLeaderboard = { top = 5, tickSeconds = 2 },
	},
	items = {
		{ id = "pebble", name = "Pebble", rarity = "Common", economy = { incomePerSec = 3 } },
	},
	products = { passes = {}, devProducts = {} },
	events = {},
}
