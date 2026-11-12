--!strict
-- tools/test-migration's example game (StudWork v1.6.0): a tiny game that imports a synthetic
-- old save with ctx.data.importLegacy (modules/legacygame/server). Test data only.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")

return {
	gameId = "legacy-game",
	modules = {
		require(Modules:WaitForChild("Items"):WaitForChild("module")),
		require(Modules:WaitForChild("Inventory"):WaitForChild("module")),
		require(Modules:WaitForChild("Economy"):WaitForChild("module")),
	} :: { any },
	config = {
		Economy = { primaryCurrency = "Coins" },
		Inventory = { inventory = { cap = 3 } },
	},
	compliance = { paidCurrencies = { "Coins" } },
	items = {
		{ id = "pebble", name = "Pebble", rarity = "Common" },
		{ id = "gem", name = "Gem", rarity = "Epic" },
	},
}
