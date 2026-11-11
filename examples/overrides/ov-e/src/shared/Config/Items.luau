--!strict
-- Sandbox items: a minimal set covering every rarity tier. Ids are saved forever; never reuse.
-- Base item fields (framework, module-api.md §12) + the Economy kit's `economy.incomePerSec`.
local Items: { any } = {
	{
		id = "pebble",
		name = "Pebble",
		rarity = "Common",
		source = "drop",
		tags = { "Rock" },
	},
	{
		id = "twig",
		name = "Twig",
		rarity = "Common",
		source = "drop",
	},
	{
		id = "acorn",
		name = "Acorn",
		rarity = "Uncommon",
		source = "drop",
	},
	{
		id = "shell",
		name = "Shell",
		rarity = "Uncommon",
		source = "drop",
	},
	{
		id = "crystal",
		name = "Crystal",
		rarity = "Rare",
		source = "drop",
		tags = { "Rock" },
	},
	{
		id = "feather",
		name = "Golden Feather",
		rarity = "Epic",
		source = "roll",
	},
	{
		id = "comet",
		name = "Comet Shard",
		rarity = "Legendary",
		source = "roll",
	},
	{
		id = "nebula",
		name = "Nebula Jar",
		rarity = "Mythic",
		source = "roll",
	},
	{
		id = "void",
		name = "???",
		rarity = "Secret",
		source = "event",
	},
}

return Items
