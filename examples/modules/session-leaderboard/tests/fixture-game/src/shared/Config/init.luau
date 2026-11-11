--!strict
-- Fixture game for tests/RealKits.spec.luau (override case f: the example module loaded next to
-- the real kit modules). Test fixture numbers, not a game's balance.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")

return {
	gameId = "leaderboard-fixture",
	modules = {
		require(Modules:WaitForChild("Items"):WaitForChild("module")),
		require(Modules:WaitForChild("Inventory"):WaitForChild("module")),
		require(Modules:WaitForChild("Economy"):WaitForChild("module")),
		require(Modules:WaitForChild("SessionLeaderboard"):WaitForChild("module")),
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
