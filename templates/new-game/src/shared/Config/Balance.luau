--!strict
-- Sandbox balance: every number the sandbox loop uses, as each kit module's config
-- (GameConfig.config.<Name>). The keys inside each module are the v1.2 `balance` keys.
-- Each module's config is merged over its defaults and checked against its schema at boot
-- (unknown keys are warnings). Commented lines show the other keys with their default values:
-- uncomment one to change it (docs/framework/override-levels.md level 2, kit pages for meanings).
local Balance = {
	-- @if Economy
	Economy = {
		primaryCurrency = "Coins",
		startingCurrency = { Coins = 0 },
		income = { tickSeconds = 1, source = "displayed" }, -- @if Plot
		-- @unless Plot: income = { tickSeconds = 1, source = "owned" },
		multiplierStacking = "multiply", -- or "add": 1 + sum(factor - 1)
	},
	-- @end
	-- @if Inventory
	Inventory = {
		inventory = { cap = 50 },
		starterItems = { "pebble" }, -- first reward: earning starts the moment you join
		-- defaults: inventory = { cap = 50 }, starterItems = {}
	},
	-- @end
	-- @if Plot
	Plot = {
		plot = { slotCount = 8, autoDisplay = true },
		-- plot = { keepDisplayedOnRebirth = false },
		assetsFolderName = "GameAssets",
		-- plotTag = "CorePlot", -- CollectionService tag of the plot models
	},
	-- @end
	-- @if Rarity
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
			-- @if Economy
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
			-- @end
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
	-- @end
	-- @if Upgrades
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
			-- each upgrade: { name, baseCost, costGrowth, currency? (default primary), maxLevel,
			-- effect ("incomeMultiplier" | "inventoryCap" | "custom"), perLevel, resetsOnRebirth? }
		},
	},
	-- @end
	-- @if Rebirth
	Rebirth = {
		rebirth = {
			baseCost = 5000,
			costGrowth = 3,
			multiplierPerRebirth = 0.5,
			keepInventory = false,
			keepDisplayed = false,
			resetCurrencies = { "Coins" },
			-- currency = "Coins", -- cost currency (default Economy's primary)
			-- maxRebirths = nil, -- no limit
		},
		-- What a rebirth wipes (defaults = the v1.2 rules; Robux-bought copies are always kept):
		-- onRebirth = { paid = "keep", paidCurrency = "wipe", earned = "wipe", itemOverrides = true },
	},
	-- @end
	-- @if Offline
	Offline = {
		offline = { capSeconds = 8 * 3600, minSeconds = 60, payoutFraction = 0.5, autoPay = true },
	},
	-- @end
	-- @if Streak
	Streak = {
		streak = {
			graceHours = 6,
			-- utcOffsetHours = 0, -- the streak day boundary (UTC by default)
			-- @if Economy
			rewards = {
				{ day = 1, amount = 100 },
				{ day = 2, amount = 250 },
				{ day = 3, amount = 500 },
				{ day = 7, amount = 2500 },
			},
			loopAfter = 7,
			-- @end
		},
	},
	-- @end
	-- @if Leaderboards
	Leaderboards = {
		-- boards = { -- one entry per board; period = "allTime" | "daily" | "weekly", source = { kind = "submit" | "registered" | "currency" | "rebirths" | "streak" }
		-- 	coins = { period = "allTime", source = { kind = "currency" }, topN = 50 },
		-- },
		boards = {},
		-- defaults: refreshSeconds = 60, writeSeconds = 120, utcOffsetHours = 0, weekStartsOn = "monday", cutToTop = true
	},
	-- @end
	-- @if Badges
	Badges = {
		-- badges = { firstHatch = { id = 0, trigger = { kind = "manual" }, toast = true } }, -- id 0 is a placeholder: recorded, never sent
		badges = {},
		-- defaults: awardInStudio = false, ownershipCheck = true, retry = { base = 5, factor = 2, max = 300, attempts = 6 }
	},
	-- @end
	-- @if Notifications
	Notifications = {
		-- templates = { eggReady = { messageId = "" } }, -- "" is a placeholder: scheduled and limited, never sent
		templates = {},
		-- secret = "OpenCloudNotifications", -- also allow it in ServerConfig.openCloud
		-- defaults: sendInStudio = false, optIn = { minSessionSeconds = 180, cooldownDays = 30 }, limits = { perPlayerPerDay = 1 }
	},
	-- @end
	-- @if Friends
	Friends = {
		friends = { checkIntervalSec = 30, coPlayMultiplier = 1.1 }, -- @if Economy
		-- @unless Economy: friends = { checkIntervalSec = 30 },
	},
	-- @end
	-- @if Mail
	-- Mail = { -- defaults:
	-- 	mail = { giftCap = 100, returnAfterDays = 14, returnKinds = { "core_gift" }, sweepSeconds = 3600 },
	-- },
	-- @end
	-- @if TextFilter
	-- TextFilter = { -- defaults:
	-- 	maxLength = 40, trim = true, perPlayerPerMinute = 20, shownMaxDays = 30, respectContentSharing = true,
	-- },
	-- @end
	-- @if Items
	-- Items has no config: item definitions live in Items.luau (GameConfig.items).
	-- @end
}

return Balance
