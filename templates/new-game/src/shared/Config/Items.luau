--!strict
-- Sandbox items: a minimal set covering every rarity tier. Ids are saved forever; never reuse.
-- Base item fields (framework, module-api.md §12) + the Economy kit's `economy.incomePerSec` + the
-- Companions kit's `companions` (pebble, twig, acorn follow the player when equipped).
local Items: { any } = {
	{
		id = "pebble",
		name = "Pebble",
		rarity = "Common",
		economy = { incomePerSec = 1 }, -- @if Economy
		companions = { movement = "walk" }, -- @if Companions
		source = "drop",
		tags = { "Rock" },
	},
	{
		id = "twig",
		name = "Twig",
		rarity = "Common",
		economy = { incomePerSec = 1.5 }, -- @if Economy
		companions = { movement = "hop" }, -- @if Companions
		source = "drop",
	},
	{
		id = "acorn",
		name = "Acorn",
		rarity = "Uncommon",
		economy = { incomePerSec = 3 }, -- @if Economy
		companions = { movement = "fly" }, -- @if Companions
		source = "drop",
	},
	{
		id = "shell",
		name = "Shell",
		rarity = "Uncommon",
		economy = { incomePerSec = 4 }, -- @if Economy
		source = "drop",
	},
	{
		id = "crystal",
		name = "Crystal",
		rarity = "Rare",
		economy = { incomePerSec = 10 }, -- @if Economy
		source = "drop",
		tags = { "Rock" },
	},
	{
		id = "feather",
		name = "Golden Feather",
		rarity = "Epic",
		economy = { incomePerSec = 30 }, -- @if Economy
		source = "roll",
	},
	{
		id = "comet",
		name = "Comet Shard",
		rarity = "Legendary",
		economy = { incomePerSec = 100 }, -- @if Economy
		source = "roll",
	},
	{
		id = "nebula",
		name = "Nebula Jar",
		rarity = "Mythic",
		economy = { incomePerSec = 400 }, -- @if Economy
		source = "roll",
	},
	{
		id = "void",
		name = "???",
		rarity = "Secret",
		economy = { incomePerSec = 2000 }, -- @if Economy
		source = "event",
	},
}

return Items
