--!strict
-- Sandbox balance: every number the sandbox loop uses. Core reads these; it has no defaults.
local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Balance: Types.BalanceConfig = {
	primaryCurrency = "Coins",
	startingCurrency = { Coins = 0 },
	starterItems = { "pebble" }, -- first reward: earning starts the moment you join
	income = { tickSeconds = 1, source = "displayed" },
	multiplierStacking = "multiply",
	inventory = { cap = 50 },
	plot = { slotCount = 8, autoDisplay = true },

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
		-- in-game currency roll (RequestRoll)
		Chest = {
			entries = {
				{ itemId = "acorn", weight = 50 },
				{ itemId = "crystal", weight = 35 },
				{ itemId = "feather", weight = 12 },
				{ itemId = "comet", weight = 3 },
			},
			cost = { currency = "Coins", amount = 250 },
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

	rebirth = {
		baseCost = 5000,
		costGrowth = 3,
		multiplierPerRebirth = 0.5,
		keepInventory = false,
		keepDisplayed = false,
		resetCurrencies = { "Coins" },
	},

	offline = { capSeconds = 8 * 3600, minSeconds = 60, payoutFraction = 0.5, autoPay = true },
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
	friends = { checkIntervalSec = 30, coPlayMultiplier = 1.1 },
}

return Balance
