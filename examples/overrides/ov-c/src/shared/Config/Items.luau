--!strict
-- Sandbox items: a minimal set covering every rarity tier. Ids are saved forever; never reuse.
-- Base item fields (framework, module-api.md §12) + the Economy kit's `economy.incomePerSec`.
local Items: { any } = {
	{
		id = "pebble",
		name = "Pebble",
		rarity = "Common",
		economy = { incomePerSec = 1 },
		source = "drop",
		tags = { "Rock" },
	},
	{
		id = "twig",
		name = "Twig",
		rarity = "Common",
		economy = { incomePerSec = 1.5 },
		source = "drop",
	},
	{
		id = "acorn",
		name = "Acorn",
		rarity = "Uncommon",
		economy = { incomePerSec = 3 },
		source = "drop",
	},
	{
		id = "shell",
		name = "Shell",
		rarity = "Uncommon",
		economy = { incomePerSec = 4 },
		source = "drop",
	},
	{
		id = "crystal",
		name = "Crystal",
		rarity = "Rare",
		economy = { incomePerSec = 10 },
		source = "drop",
		tags = { "Rock" },
	},
	{
		id = "feather",
		name = "Golden Feather",
		rarity = "Epic",
		economy = { incomePerSec = 30 },
		source = "roll",
	},
	{
		id = "comet",
		name = "Comet Shard",
		rarity = "Legendary",
		economy = { incomePerSec = 100 },
		source = "roll",
	},
	{
		id = "nebula",
		name = "Nebula Jar",
		rarity = "Mythic",
		economy = { incomePerSec = 400 },
		source = "roll",
	},
	{
		id = "void",
		name = "???",
		rarity = "Secret",
		economy = { incomePerSec = 2000 },
		source = "event",
	},
}

return Items
