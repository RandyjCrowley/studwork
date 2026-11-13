--!strict
-- Quests demo items: what the free DemoCrate roll and item rewards hand out. Ids are saved
-- forever; never reuse one.
local Items: { any } = {
	{ id = "gem", name = "Gem", rarity = "Common", source = "drop" },
	{ id = "star", name = "Star", rarity = "Uncommon", source = "drop" },
	{ id = "comet", name = "Comet", rarity = "Rare", source = "drop" },
}

return Items
