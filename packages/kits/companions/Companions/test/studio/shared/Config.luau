--!strict
local RS = game:GetService("ReplicatedStorage")
local M = RS:WaitForChild("Modules")
return {
	gameId = "companions-fixture",
	modules = { require(M.Items.module), require(M.Inventory.module), require(M.Companions.module) },
	config = {
		Inventory = { starterItems = { "walker", "hopper", "flyer" } },
	},
	items = {
		{
			id = "walker",
			name = "Walker",
			rarity = "Common",
			model = "Walker",
			companions = { movement = "walk" },
		},
		{
			id = "hopper",
			name = "Hopper",
			rarity = "Common",
			model = "Hopper",
			companions = { movement = "hop" },
		},
		{
			id = "flyer",
			name = "Flyer",
			rarity = "Common",
			model = "Flyer",
			companions = { movement = "fly", look = "Golden" },
		},
	},
}
