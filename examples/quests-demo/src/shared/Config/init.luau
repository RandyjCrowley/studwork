--!strict
--[[
	The quests demo's GameConfig (module-api.md §3, §11): the fixture game of the quests kit
	(docs/framework/kits/quests.md). The server and client scripts both pass it to StudWork.start.
	Loop: touch the coin spots (coins, "coinTouched"), visit the guide, open the quest board, claim,
	walk to the far tower. The game's own module (modules/quests-demo) builds the world and is added
	by the framework.

	Every game.* key the config uses (quest titles, objective labels, goal texts, the "what's next"
	text) is in `strings`, so Studio logs no missing-key warning. analytics.funnel lists every goal's
	step in chain order ("Joined" is logged by the framework).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")

local Config = {
	gameId = "quests-demo",
	modules = {
		require(Modules:WaitForChild("Items"):WaitForChild("module")), -- item definitions; needed by Inventory and Rarity
		require(Modules:WaitForChild("Rarity"):WaitForChild("module")), -- the free DemoCrate roll (a quest reward)
		require(Modules:WaitForChild("Inventory"):WaitForChild("module")), -- item and roll rewards land here
		require(Modules:WaitForChild("Economy"):WaitForChild("module")), -- Coins: the currencyEarned / currency sources and rewards
		require(Modules:WaitForChild("Quests"):WaitForChild("module")), -- daily/weekly/story/one-time/repeatable/event quests
		require(Modules:WaitForChild("Goals"):WaitForChild("module")), -- the first-session goal chain: pill + one arrow
	} :: { any },
	config = require(script.Balance),
	compliance = { paidCurrencies = {} }, -- nothing is sold for Robux
	items = require(script.Items),
	products = require(script.Products),
	events = require(script.Events),
	environments = require(script.Environments),
	flags = {},
	strings = {
		["game.welcome"] = "Welcome back, {name}!",
		-- quest titles
		["game.quest.dailyEarn"] = "Earn 50 coins",
		["game.quest.dailyCrate"] = "Coin collector",
		["game.quest.dailyGuide"] = "Say hi to the guide",
		["game.quest.dailyBoard"] = "Check the board",
		["game.quest.dailyRich"] = "Save up 100 coins",
		["game.quest.dailyTower"] = "Visit the tower",
		["game.quest.weeklyEarn"] = "Earn 1,000 coins",
		["game.quest.weeklyTouches"] = "Touch 150 coin spots",
		["game.quest.weeklyTowers"] = "Climb the tower 3 times",
		["game.quest.story1"] = "Meet the guide",
		["game.quest.story2"] = "Gather some coins",
		["game.quest.story3"] = "Reach the tower",
		["game.quest.repeatCoins"] = "Quick coins",
		["game.quest.guideGift"] = "The guide's errand",
		["game.quest.eventCoins"] = "Event: coin rush",
		-- objective lines
		["game.objective.earnCoins"] = "Earn coins",
		["game.objective.touchCoins"] = "Touch coin spots",
		["game.objective.visitGuide"] = "Visit the guide",
		["game.objective.visitBoard"] = "Visit the board",
		["game.objective.haveCoins"] = "Have coins",
		["game.objective.visitTower"] = "Visit the tower",
		-- goal pill texts and what comes after the chain
		["game.goal.firstCoins"] = "Collect 10 coins",
		["game.goal.openBoard"] = "Open your quests",
		["game.goal.firstClaim"] = "Talk to the guide and claim your first quest",
		["game.goal.reachTower"] = "Walk to the tower",
		["game.next.dailies"] = "Finish today's quests at the board",
	},
	client = {},
	analytics = {
		funnel = {
			"Joined",
			"FirstCoins",
			"OpenedBoard",
			"FirstClaim",
			"ReachedTower",
		},
		clientSteps = {},
	},
}

return Config
