--!strict
--[[
	Quests demo balance: each kit module's config (GameConfig.config.<Name>), merged over the kit's
	defaults and checked at boot. The Quests and Goals sections show every quest kind and every goal
	check the Studio checks need (docs/framework/kits/quests.md).

	Fixture-only overrides (never copy them into a real game; listed in the demo's README.md):
	Quests.foldSeconds = 5 and Quests.replicateSeconds = 0.5, so pending progress joins the save and
	reaches the client quickly while you watch.
]]

local Tuning = require(script.Parent.Tuning)

-- the first-session goal chain (a list of mixed shapes: typed as a plain list)
local GOAL_CHAIN: { any } = {
	{
		id = "firstCoins",
		text = "game.goal.firstCoins",
		check = { source = "currency", atLeast = 10 },
		target = { tag = "DemoCoin" },
		funnel = "FirstCoins",
	},
	{
		id = "openBoard",
		text = "game.goal.openBoard",
		check = { ack = true },
		widget = "Quests.button",
		funnel = "OpenedBoard",
	},
	{
		id = "firstClaim",
		text = "game.goal.firstClaim",
		check = { quest = "story1", on = "claimed" },
		target = { path = "Workspace.DemoWorld.DemoGuide" },
		funnel = "FirstClaim",
	},
	{
		id = "reachTower",
		text = "game.goal.reachTower",
		check = { call = true },
		target = { position = Tuning.towerPosition },
		fallback = Tuning.towerPosition,
		funnel = "ReachedTower",
	},
}

local Balance: { [string]: any } = {
	Economy = {
		primaryCurrency = "Coins",
		startingCurrency = { Coins = 0 },
		income = { tickSeconds = 1, source = "owned" }, -- the demo items earn nothing: coins come from the spots
		multiplierStacking = "multiply",
	},
	Inventory = {
		inventory = { cap = 50 },
		starterItems = {},
	},
	Rarity = {
		rarityTables = {
			-- free (no paid = true, no cost): the only kind of table a quest reward may roll
			DemoCrate = {
				entries = {
					{ itemId = "gem", weight = 70 },
					{ itemId = "star", weight = 25 },
					{ itemId = "comet", weight = 5 },
				},
			},
		},
		mutations = {},
	},
	Quests = {
		daily = { count = 3, rerollsPerSlot = 1 },
		weekly = { count = 2, rerollsPerSlot = 0 },
		foldSeconds = 5, -- fixture-only override (default 30)
		replicateSeconds = 0.5, -- fixture-only override (default 1)
		quests = {
			-- daily pool of 6: one currencyEarned source, one roll reward
			dailyEarn = {
				kind = "daily",
				title = "game.quest.dailyEarn",
				objectives = {
					{
						kind = "source",
						source = "currencyEarned",
						target = 50,
						label = "game.objective.earnCoins",
					},
				},
				reward = { { kind = "currency", amount = 25 } },
			},
			dailyCrate = {
				kind = "daily",
				title = "game.quest.dailyCrate",
				objectives = {
					{
						kind = "counter",
						key = "coinTouched",
						target = 8,
						label = "game.objective.touchCoins",
					},
				},
				reward = { { kind = "roll", table = "DemoCrate" } },
			},
			dailyGuide = {
				kind = "daily",
				title = "game.quest.dailyGuide",
				objectives = {
					{
						kind = "counter",
						key = "guideVisited",
						target = 1,
						label = "game.objective.visitGuide",
					},
				},
				reward = { { kind = "currency", amount = 15 } },
			},
			dailyBoard = {
				kind = "daily",
				title = "game.quest.dailyBoard",
				objectives = {
					{
						kind = "counter",
						key = "boardVisited",
						target = 1,
						label = "game.objective.visitBoard",
					},
				},
				reward = { { kind = "currency", amount = 15 } },
			},
			dailyRich = {
				kind = "daily",
				title = "game.quest.dailyRich",
				objectives = {
					{
						kind = "threshold",
						source = "currency",
						target = 100,
						label = "game.objective.haveCoins",
					},
				},
				reward = { { kind = "item", item = "star" } },
			},
			dailyTower = {
				kind = "daily",
				title = "game.quest.dailyTower",
				objectives = {
					{
						kind = "counter",
						key = "towerVisited",
						target = 1,
						label = "game.objective.visitTower",
					},
				},
				reward = { { kind = "currency", amount = 40 } },
			},
			-- weekly: 2 of 3
			weeklyEarn = {
				kind = "weekly",
				title = "game.quest.weeklyEarn",
				objectives = {
					{
						kind = "source",
						source = "currencyEarned",
						target = 1000,
						label = "game.objective.earnCoins",
					},
				},
				reward = { { kind = "currency", amount = 300 } },
			},
			weeklyTouches = {
				kind = "weekly",
				title = "game.quest.weeklyTouches",
				objectives = {
					{
						kind = "counter",
						key = "coinTouched",
						target = 150,
						label = "game.objective.touchCoins",
					},
				},
				reward = { { kind = "roll", table = "DemoCrate" } },
			},
			weeklyTowers = {
				kind = "weekly",
				title = "game.quest.weeklyTowers",
				objectives = {
					{
						kind = "counter",
						key = "towerVisited",
						target = 3,
						label = "game.objective.visitTower",
					},
				},
				reward = { { kind = "currency", amount = 250 } },
			},
			-- the story chain (3 steps)
			story1 = {
				kind = "chain",
				title = "game.quest.story1",
				objectives = {
					{
						kind = "counter",
						key = "guideVisited",
						target = 1,
						label = "game.objective.visitGuide",
					},
				},
				reward = { { kind = "currency", amount = 20 } },
			},
			story2 = {
				kind = "chain",
				title = "game.quest.story2",
				objectives = {
					{
						kind = "counter",
						key = "coinTouched",
						target = 5,
						label = "game.objective.touchCoins",
					},
				},
				reward = { { kind = "currency", amount = 30 } },
			},
			story3 = {
				kind = "chain",
				title = "game.quest.story3",
				objectives = {
					{
						kind = "counter",
						key = "towerVisited",
						target = 1,
						label = "game.objective.visitTower",
					},
				},
				reward = { { kind = "roll", table = "DemoCrate" } },
			},
			-- a repeatable (3 claims a day)
			repeatCoins = {
				kind = "repeatable",
				title = "game.quest.repeatCoins",
				cap = 3,
				period = "daily",
				objectives = {
					{
						kind = "counter",
						key = "coinTouched",
						target = 4,
						label = "game.objective.touchCoins",
					},
				},
				reward = { { kind = "currency", amount = 10 } },
			},
			-- a one-time quest the guide hands out (Quests.grant)
			guideGift = {
				kind = "oneTime",
				title = "game.quest.guideGift",
				offer = "grant",
				objectives = {
					{
						kind = "counter",
						key = "boardVisited",
						target = 1,
						label = "game.objective.visitBoard",
					},
				},
				reward = { { kind = "item", item = "comet" } },
			},
			-- an event quest, active while demoEvent runs
			eventCoins = {
				kind = "event",
				title = "game.quest.eventCoins",
				event = "demoEvent",
				objectives = {
					{
						kind = "counter",
						key = "coinTouched",
						target = 12,
						label = "game.objective.touchCoins",
					},
				},
				reward = { { kind = "currency", amount = 100 } },
			},
		},
		chains = { story = { "story1", "story2", "story3" } },
	},
	Goals = {
		chain = GOAL_CHAIN,
	},
}

return Balance
