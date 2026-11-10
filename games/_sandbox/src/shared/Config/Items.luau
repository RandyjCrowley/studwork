--!strict
-- Sandbox items: a minimal set covering every rarity tier. Ids are saved forever; never reuse.
local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Items: { Types.ItemDef } = {
	{
		id = "pebble",
		name = "Pebble",
		rarity = "Common",
		incomePerSec = 1,
		source = "drop",
		tags = { "Rock" },
	},
	{ id = "twig", name = "Twig", rarity = "Common", incomePerSec = 1.5, source = "drop" },
	{ id = "acorn", name = "Acorn", rarity = "Uncommon", incomePerSec = 3, source = "drop" },
	{ id = "shell", name = "Shell", rarity = "Uncommon", incomePerSec = 4, source = "drop" },
	{
		id = "crystal",
		name = "Crystal",
		rarity = "Rare",
		incomePerSec = 10,
		source = "drop",
		tags = { "Rock" },
	},
	{ id = "feather", name = "Golden Feather", rarity = "Epic", incomePerSec = 30, source = "roll" },
	{ id = "comet", name = "Comet Shard", rarity = "Legendary", incomePerSec = 100, source = "roll" },
	{ id = "nebula", name = "Nebula Jar", rarity = "Mythic", incomePerSec = 400, source = "roll" },
	{ id = "void", name = "???", rarity = "Secret", incomePerSec = 2000, source = "event" },
}

return Items
