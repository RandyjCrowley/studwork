--!strict
-- Sandbox balance: every number the sandbox loop uses, as each kit module's config
-- (GameConfig.config.<Name>). The keys inside each module are the v1.2 `balance` keys.
local Balance = {
	Economy = {
		primaryCurrency = "Coins",
		startingCurrency = { Coins = 0 },
		income = { tickSeconds = 1, source = "displayed" },
		multiplierStacking = "multiply",
	},
	Inventory = {
		inventory = { cap = 50 },
		starterItems = { "pebble" }, -- first reward: earning starts the moment you join
	},
	Plot = {
		plot = { slotCount = 8, autoDisplay = true },
		assetsFolderName = "GameAssets",
	},
	Rarity = {
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
	Upgrades = {
		upgrades = {
			IncomeBoost = {
				name = "Income Boost",
				baseCost = 50,
				costGrowth = 1.6,
				maxLevel = 25,
				effect = "incomeMultiplier",
				perLevel = 0.1,
				resetsOnRebirth = true,
			},
			BiggerBag = {
				name = "Bigger Bag",
				baseCost = 100,
				costGrowth = 2,
				maxLevel = 10,
				effect = "inventoryCap",
				perLevel = 5,
				resetsOnRebirth = false,
			},
		},
	},
	Rebirth = {
		rebirth = {
			baseCost = 5000,
			costGrowth = 3,
			multiplierPerRebirth = 0.5,
			keepInventory = false,
			keepDisplayed = false,
			resetCurrencies = { "Coins" },
		},
	},
	Offline = {
		offline = { capSeconds = 8 * 3600, minSeconds = 60, payoutFraction = 0.5, autoPay = true },
	},
	Streak = {
		streak = {
			graceHours = 6,
			rewards = {
				{ day = 1, amount = 100 },
				{ day = 2, amount = 250 },
				{ day = 3, amount = 500 },
				{ day = 7, amount = 2500 },
			},
			loopAfter = 7,
		},
	},
	Friends = {
		friends = { checkIntervalSec = 30, coPlayMultiplier = 1.1 },
	},
	-- v1.7.0 kits (docs/framework/kits/): placeholder ids, so nothing is sent to Roblox
	Leaderboards = {
		boards = {
			coins = { period = "allTime", source = { kind = "currency" }, topN = 50 },
			dailyTouches = { period = "daily", source = { kind = "submit" }, mode = "sum", topN = 25 },
		},
	},
	Badges = {
		-- id = 0 is a placeholder: recorded as awarded, never sent, one warning per server
		badges = {
			firstCollect = { id = 0, trigger = { kind = "manual" }, toast = true },
			streakThree = { id = 0, trigger = { kind = "streak", atLeast = 3 }, toast = true },
		},
	},
	Notifications = {
		-- messageId = "" is a placeholder: scheduled and limited as usual, never sent
		templates = {
			eggReady = { messageId = "", params = {}, category = "egg" },
			streakEnding = { messageId = "", hoursBefore = 4, minStreak = 3 },
		},
	},
	-- TextFilter has no required config (defaults: maxLength 40, trim, 20 filter calls a minute)
	TextFilter = {},
}

return Balance
