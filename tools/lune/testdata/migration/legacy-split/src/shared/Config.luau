--!strict
-- tools/test-migration's second example game (StudWork v1.6.0): a synthetic old save split over
-- two stores (a map of sources), pets as { id, uid } tables, receipts as { [id]: true }, and a
-- sold stat (modules/legacygame/server). Test data only.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")

return {
	gameId = "legacy-split",
	modules = {
		require(Modules:WaitForChild("Items"):WaitForChild("module")),
		require(Modules:WaitForChild("Inventory"):WaitForChild("module")),
		require(Modules:WaitForChild("Economy"):WaitForChild("module")),
	} :: { any },
	config = {
		Economy = { primaryCurrency = "Coins" },
		Inventory = { inventory = { cap = 50 } },
	},
	compliance = { paidCurrencies = { "Coins" } },
	items = {
		{ id = "pebble", name = "Pebble", rarity = "Common" },
		{ id = "gem", name = "Gem", rarity = "Epic" },
	},
}
