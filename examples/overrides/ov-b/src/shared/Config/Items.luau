--!strict
-- Sandbox items: a minimal set covering every rarity tier. Ids are saved forever; never reuse.
-- Base item fields (framework, module-api.md §12) + the Economy kit's `economy.incomePerSec`.
local Items: { any } = {
	{
		id = "pebble",
		name = "Pebble",
		rarity = "Bronze",
		economy = { incomePerSec = 1 },
		source = "drop",
		tags = { "Rock" },
	},
	{
		id = "twig",
		name = "Twig",
		rarity = "Bronze",
		economy = { incomePerSec = 1.5 },
		source = "drop",
	},
	{
		id = "acorn",
		name = "Acorn",
		rarity = "Bronze",
		economy = { incomePerSec = 3 },
		source = "drop",
	},
	{
		id = "shell",
		name = "Shell",
		rarity = "Bronze",
		economy = { incomePerSec = 4 },
		source = "drop",
	},
	{
		id = "crystal",
		name = "Crystal",
		rarity = "Silver",
		economy = { incomePerSec = 10 },
		source = "drop",
		tags = { "Rock" },
	},
	{
		id = "feather",
		name = "Golden Feather",
		rarity = "Gold",
		economy = { incomePerSec = 30 },
		source = "roll",
	},
	{
		id = "comet",
		name = "Comet Shard",
		rarity = "Gold",
		economy = { incomePerSec = 100 },
		source = "roll",
	},
	{
		id = "nebula",
		name = "Nebula Jar",
		rarity = "Diamond",
		economy = { incomePerSec = 400 },
		source = "roll",
	},
	{
		id = "void",
		name = "???",
		rarity = "Diamond",
		economy = { incomePerSec = 2000 },
		source = "event",
	},
}

return Items
