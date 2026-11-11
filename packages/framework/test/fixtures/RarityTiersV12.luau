--!strict
--[[
	TEST FIXTURE (v1.3.0: the v1.2 shared RarityTiers.luau, kept only
	as the reference Theme.spec compares the framework's default rarity theme against).
	Shared rarity tiers (from docs/research/art-direction.md: rarity reads through colour, glow and
	particles, not detail; a distinct sound per rarity). Pure module.

	Tier order is part of the contract: Common < Uncommon < Rare < Epic < Legendary < Mythic < Secret.
	Colours reference Palette keys so a game's palette override recolours rarities too.
]]

local Types = require(script.Parent.Parent.Parent.shared.Types)

type RarityTier = Types.RarityTier
type RarityTierDef = Types.RarityTierDef

local RarityTiers = {}

local ORDER: { RarityTier } = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }

local DEFS: { [RarityTier]: RarityTierDef } = {
	Common = {
		id = "Common",
		order = 1,
		color = "#C9CFD9",
		glow = "#E6EAF0",
		glowStrength = 0.0,
		soundKey = "rarity_common",
	},
	Uncommon = {
		id = "Uncommon",
		order = 2,
		color = "#6BD66B",
		glow = "#A6F0A6",
		glowStrength = 0.15,
		soundKey = "rarity_uncommon",
	},
	Rare = {
		id = "Rare",
		order = 3,
		color = "#4DA3FF",
		glow = "#9CCBFF",
		glowStrength = 0.35,
		soundKey = "rarity_rare",
	},
	Epic = {
		id = "Epic",
		order = 4,
		color = "#B26BFF",
		glow = "#D7B0FF",
		glowStrength = 0.55,
		soundKey = "rarity_epic",
	},
	Legendary = {
		id = "Legendary",
		order = 5,
		color = "#FFB547",
		glow = "#FFE0A3",
		glowStrength = 0.75,
		soundKey = "rarity_legendary",
	},
	Mythic = {
		id = "Mythic",
		order = 6,
		color = "#FF5DA8",
		glow = "#FFB3D6",
		glowStrength = 0.9,
		soundKey = "rarity_mythic",
	},
	Secret = {
		id = "Secret",
		order = 7,
		color = "#2EF2E0",
		glow = "#B8FFF8",
		glowStrength = 1.0,
		soundKey = "rarity_secret",
	},
}

RarityTiers.ORDER = ORDER

function RarityTiers.get(tier: RarityTier): RarityTierDef
	return DEFS[tier]
end

function RarityTiers.isTier(value: any): boolean
	return type(value) == "string" and DEFS[value :: any] ~= nil
end

function RarityTiers.order(tier: RarityTier): number
	local def = DEFS[tier]
	return if def then def.order else 0
end

-- true when `tier` is at least `minTier`
function RarityTiers.atLeast(tier: RarityTier, minTier: RarityTier): boolean
	return RarityTiers.order(tier) >= RarityTiers.order(minTier)
end

function RarityTiers.all(): { RarityTierDef }
	local list: { RarityTierDef } = {}
	for _, id in ORDER do
		table.insert(list, (DEFS :: any)[id] :: RarityTierDef)
	end
	return list
end

return RarityTiers
