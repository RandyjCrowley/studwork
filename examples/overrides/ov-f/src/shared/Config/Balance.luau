--!strict
-- Sandbox balance: every number the sandbox loop uses, as each kit module's config
-- (GameConfig.config.<Name>). The keys inside each module are the v1.2 `balance` keys.
-- Each module's config is merged over its defaults and checked against its schema at boot
-- (unknown keys are warnings). Commented lines show the other keys with their default values:
-- uncomment one to change it (docs/framework/override-levels.md level 2, kit pages for meanings).
local Balance = {
	Economy = {
		primaryCurrency = "Coins",
		startingCurrency = { Coins = 0 },
		income = { tickSeconds = 1, source = "owned" },
		multiplierStacking = "multiply", -- or "add": 1 + sum(factor - 1)
	},
	Inventory = {
		inventory = { cap = 50 },
		-- override (f): no starter item, so the only Coins a fresh player gets are the ones the spec
		-- grants (owned-item income would add to SessionLeaderboard's points)
		starterItems = {},
		-- defaults: inventory = { cap = 50 }, starterItems = {}
	},
	Rarity = {
		-- tiers = "standard7", -- the default: Common .. Secret. Or your own ordered list; items'
		-- `rarity` must then use these ids, and the UI takes each tier's look from here:
		-- tiers = {
		-- 	{ id = "Bronze", color = "#CD7F32", soundKey = "rarity_common" },
		-- 	{ id = "Silver", color = "#C0C0C0", soundKey = "rarity_rare" },
		-- 	{ id = "Gold", color = "#FFD23F", glow = "#FFF2B3", glowStrength = 0.6, soundKey = "rarity_epic" },
		-- 	{ id = "Diamond", color = "#7DF9FF", glow = "#FFFFFF", glowStrength = 1, soundKey = "rarity_secret" },
		-- },
		rarityTables = {
			-- free: touching the collect block
			Block = {
				entries = {
					{ itemId = "pebble", weight = 50 },
					{ itemId = "twig", weight = 30 },
					{ itemId = "acorn", weight = 12 },
					{ itemId = "shell", weight = 6 },
					{ itemId = "crystal", weight = 2 },
				},
				luckMinTier = "Rare",
				mutationChance = 0.05,
			},
			-- in-game currency roll (Rarity's client action `roll`)
			Chest = {
				entries = {
					{ itemId = "acorn", weight = 50 },
					{ itemId = "crystal", weight = 35 },
					{ itemId = "feather", weight = 12 },
					{ itemId = "comet", weight = 3 },
				},
				cost = { currency = "Coins", amount = 250 },
				-- odds are disclosed per player WITH their luck (Rarity.setLuck), so this paid
				-- (Coins are sold for Robux) roll may use luck. The Robux Egg is not: luck there errors.
				luckDisclosed = true,
				pity = { threshold = 10, minTier = "Epic" },
				mutationChance = 0.1,
			},
			-- Robux roll (developer product "EggRoll"): paid random item rules apply
			Egg = {
				entries = {
					{ itemId = "crystal", weight = 60 },
					{ itemId = "feather", weight = 30 },
					{ itemId = "comet", weight = 9 },
					{ itemId = "nebula", weight = 1 },
				},
				paid = true,
				pity = { threshold = 20, minTier = "Legendary" },
				mutationChance = 0.15,
			},
		},
		mutations = {
			{ id = "Gold", name = "Gold", multiplier = 2, color = "#FFD23F", weight = 8 },
			{ id = "Rainbow", name = "Rainbow", multiplier = 5, color = "#FF5DA8", weight = 2 },
		},
	},
	-- Items has no config: item definitions live in Items.luau (GameConfig.items).
	-- override (f): the example module's config (its README, step 3)
	SessionLeaderboard = { top = 5 },
}

return Balance
