--!nocheck
--[[
	Quests boot validation (Quests/shared/Validate.luau, kit page "Config validation (at boot)"):
	one bad config per bullet, every problem collected and reported together, and the configs that
	must pass (no config at all; an empty pool with the default counts; a free roll table).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Validate = require(Modules:WaitForChild("Quests"):WaitForChild("shared"):WaitForChild("Validate"))
local F = require("packages/kits/quests/tests/Fixtures.luau")

local Quests = F.Quests

local ALL_ON = {
	Economy = true,
	Items = true,
	Inventory = true,
	Rarity = true,
	Rebirth = true,
	Streak = true,
	Leaderboards = true,
}

local function env(overrides)
	local e = {
		enabled = ALL_ON,
		sources = { power = true },
		rewards = { badge = true },
		itemKnown = function(id)
			return id == "coin" or id == "gem"
		end,
		oddsDetail = function(tableId)
			if tableId == "FreeCrate" then
				return { entries = {}, paid = false }
			elseif tableId == "PaidCrate" then
				return { entries = {}, paid = true }
			end
			return nil
		end,
		events = { testEvent = {} },
	}
	for k, v in overrides or {} do
		e[k] = v
	end
	return e
end

-- a valid base config plus `quests` merged in
local function cfg(quests, extra)
	local c = {
		daily = { count = 1, rerollsPerSlot = 1 },
		weekly = { count = 1, rerollsPerSlot = 0 },
		quests = {},
		chains = {},
	}
	for id, q in quests or {} do
		c.quests[id] = q
	end
	for k, v in extra or {} do
		c[k] = v
	end
	return c
end

local function has(errors, needle)
	for _, e in errors do
		if string.find(e, needle, 1, true) then
			return true
		end
	end
	return false
end

-- exactly one error, containing every needle
local function expectOne(errors, ...)
	expect(#errors .. " error(s): " .. table.concat(errors, " | ")).toBe("1 error(s): " .. (errors[1] or ""))
	for _, needle in { ... } do
		expect(needle .. "=" .. tostring(has(errors, needle))).toBe(needle .. "=true")
	end
end

describe("Quests validation: what passes", function()
	it("no config at all (every default) is valid", function()
		expect(Validate.check(Quests.config.defaults, {})).toEqual({})
	end)

	it("an empty pool with the default counts is valid", function()
		local c = table.clone(Quests.config.defaults)
		c.quests = { once = F.oneTime() }
		expect(Validate.check(c, env())).toEqual({})
	end)

	it("the fixtures' every-kind config is valid", function()
		expect(Validate.check(F.questsConfig(), env())).toEqual({})
	end)

	it("every built-in source, reward kind and requirement, used correctly, is valid", function()
		local c = cfg({
			a = F.quest("oneTime", {
				F.source("currencyEarned", 10),
				F.source("itemCollected", 2, { item = "coin" }),
				F.source("rebirthDone", 1),
				F.threshold("currency", 5),
			}, { reward = { F.currency(5), F.item("coin", 2), F.roll("FreeCrate"), F.custom("badge") } }),
			b = F.quest("oneTime", {
				F.threshold("rebirths", 1),
				F.threshold("streakDay", 3),
				F.threshold("itemOwned", 1, { item = "gem" }),
				F.threshold("leaderboardRank", 10, { board = "coins" }),
			}, { requires = { quests = { "a" }, rebirths = 1, items = { "coin" } } }),
			c = F.quest("oneTime", { F.threshold("power", 3), F.ack("openShop") }),
		})
		expect(Validate.check(c, env())).toEqual({})
	end)
end)

describe("Quests validation: one bad config per rule", function()
	it("unknown quest kind", function()
		expectOne(
			Validate.check(cfg({ a = F.quest("monthly") }), env()),
			"quest 'a'",
			"unknown kind 'monthly'"
		)
	end)

	it("unknown objective kind", function()
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { { kind = "kill", target = 1 } }) }), env()),
			"objective 1",
			"unknown kind 'kill'"
		)
	end)

	it("unknown reward kind", function()
		expectOne(
			Validate.check(cfg({ a = F.oneTime({ reward = { { kind = "robux", amount = 1 } } }) }), env()),
			"reward 1",
			"unknown kind 'robux'"
		)
	end)

	it("a bad quest id, chain id and counter key", function()
		expectOne(Validate.check(cfg({ ["bad id"] = F.oneTime() }), env()), "quest 'bad id'", "bad id")
		expectOne(Validate.check(cfg({ [string.rep("x", 33)] = F.oneTime() }), env()), "bad id")
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { F.counter("no spaces") }) }), env()),
			"key 'no spaces'"
		)
		expectOne(
			Validate.check(cfg({ s1 = F.chain() }, { chains = { ["bad-chain"] = { "s1" } } }), env()),
			"chain 'bad-chain'",
			"bad id"
		)
	end)

	it("0 or more than 4 objectives, more than 4 rewards", function()
		expectOne(Validate.check(cfg({ a = F.quest("oneTime", {}) }), env()), "1..4 objectives")
		local five = { F.counter("a"), F.counter("b"), F.counter("c"), F.counter("d"), F.counter("e") }
		expectOne(Validate.check(cfg({ a = F.quest("oneTime", five) }), env()), "1..4 objectives")
		local rewards = { F.currency(), F.currency(), F.currency(), F.currency(), F.currency() }
		expectOne(Validate.check(cfg({ a = F.oneTime({ reward = rewards }) }), env()), "0..4 rewards")
	end)

	it("a target that isn't an integer 1..1e9", function()
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { F.counter("k", 0) }) }), env()),
			"target must be an integer"
		)
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { F.counter("k", 2.5) }) }), env()),
			"target must be an integer"
		)
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { F.counter("k", 2e9) }) }), env()),
			"target must be an integer"
		)
	end)

	it("a source that is neither built in nor registered", function()
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { F.threshold("mana", 3) }) }), env()),
			"unknown source 'mana'"
		)
	end)

	it("a built-in source whose module isn't enabled names the quest and the module", function()
		for source, module in
			{
				currencyEarned = "Economy",
				rebirthDone = "Rebirth",
				streakDay = "Streak",
				leaderboardRank = "Leaderboards",
			}
		do
			local enabled = table.clone(ALL_ON)
			enabled[module] = false
			local o = if source == "currencyEarned" or source == "rebirthDone"
				then F.source(source, 1)
				else F.threshold(source, 1, { board = "coins" })
			expectOne(
				Validate.check(cfg({ a = F.quest("oneTime", { o }) }), env({ enabled = enabled })),
				"quest 'a'",
				"needs " .. module
			)
		end
		local noItems = table.clone(ALL_ON)
		noItems.Items = false
		expectOne(
			Validate.check(
				cfg({ a = F.quest("oneTime", { F.source("itemCollected", 1, { rarity = "Rare" }) }) }),
				env({ enabled = noItems })
			),
			"needs Items"
		)
	end)

	it("a threshold on an add source, a source objective on a value source", function()
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { F.threshold("currencyEarned", 5) }) }), env()),
			"is an add source"
		)
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { F.source("currency", 5) }) }), env()),
			"is a value source"
		)
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { F.source("power", 5) }) }), env()),
			"is a value source"
		)
	end)

	it("a missing params.item / params.board", function()
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { F.threshold("itemOwned", 1) }) }), env()),
			"needs params.item"
		)
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { F.threshold("leaderboardRank", 1) }) }), env()),
			"needs params.board"
		)
	end)

	it("a reward handler nobody registered", function()
		expectOne(
			Validate.check(cfg({ a = F.oneTime({ reward = { F.custom("nobody") } }) }), env()),
			"'nobody' is not registered"
		)
	end)

	it("an item Items doesn't know", function()
		expectOne(
			Validate.check(cfg({ a = F.oneTime({ reward = { F.item("unicorn") } }) }), env()),
			"unknown item 'unicorn'"
		)
	end)

	it("an unknown roll table, and a paid one", function()
		expectOne(
			Validate.check(cfg({ a = F.oneTime({ reward = { F.roll("Nope") } }) }), env()),
			"unknown roll table 'Nope'"
		)
		expectOne(
			Validate.check(cfg({ a = F.oneTime({ reward = { F.roll("PaidCrate") } }) }), env()),
			"'PaidCrate' is paid"
		)
	end)

	it("a reward whose module isn't enabled", function()
		local noEconomy = table.clone(ALL_ON)
		noEconomy.Economy = false
		expectOne(
			Validate.check(
				cfg({ a = F.oneTime({ reward = { F.currency() } }) }),
				env({ enabled = noEconomy })
			),
			"needs Economy"
		)
		local noRarity = table.clone(ALL_ON)
		noRarity.Rarity = false
		expectOne(
			Validate.check(
				cfg({ a = F.oneTime({ reward = { F.roll("FreeCrate") } }) }),
				env({ enabled = noRarity })
			),
			"needs Rarity"
		)
	end)

	it("reward amounts and counts out of range", function()
		expectOne(
			Validate.check(cfg({ a = F.oneTime({ reward = { F.currency(0) } }) }), env()),
			"amount must be an integer"
		)
		expectOne(
			Validate.check(cfg({ a = F.oneTime({ reward = { F.item("coin", 11) } }) }), env()),
			"count must be an integer 1..10"
		)
	end)

	it("a quest whose objectives are all ack, and autoClaim on a quest with an ack", function()
		expectOne(
			Validate.check(cfg({ a = F.quest("oneTime", { F.ack("k"), F.ack("j") }) }), env()),
			"every objective is an ack"
		)
		expectOne(
			Validate.check(
				cfg({ a = F.quest("oneTime", { F.counter("c"), F.ack("k") }, { autoClaim = true }) }),
				env()
			),
			"autoClaim = true on a quest with an ack"
		)
	end)

	it(
		"chains: a dangling step, a wrong kind, a chain quest in no chain or two, empty, a step twice",
		function()
			expectOne(
				Validate.check(cfg({ s1 = F.chain() }, { chains = { c = { "s1", "ghost" } } }), env()),
				"'ghost' is not a quest"
			)
			expectOne(
				Validate.check(
					cfg({ s1 = F.chain(), d = F.oneTime() }, { chains = { c = { "s1", "d" } } }),
					env()
				),
				"has kind 'oneTime', not \"chain\""
			)
			expectOne(
				Validate.check(cfg({ s1 = F.chain(), s2 = F.chain() }, { chains = { c = { "s1" } } }), env()),
				"quest 's2': a chain quest in no chain"
			)
			expectOne(
				Validate.check(cfg({ s1 = F.chain() }, { chains = { c = { "s1" }, e = { "s1" } } }), env()),
				"quest 's1': a chain quest in two chains"
			)
			expectOne(Validate.check(cfg({}, { chains = { c = {} } }), env()), "chain 'c': is empty")
			expectOne(
				Validate.check(cfg({ s1 = F.chain() }, { chains = { c = { "s1", "s1" } } }), env()),
				"listed twice"
			)
		end
	)

	it(
		"requires: an unknown quest, itself, a cycle, rebirths without Rebirth, items without Inventory or unknown",
		function()
			expectOne(
				Validate.check(cfg({ a = F.oneTime({ requires = { quests = { "ghost" } } }) }), env()),
				"requires unknown quest 'ghost'"
			)
			expectOne(
				Validate.check(cfg({ a = F.oneTime({ requires = { quests = { "a" } } }) }), env()),
				"requires itself"
			)
			local cycle = Validate.check(
				cfg({
					a = F.oneTime({ requires = { quests = { "b" } } }),
					b = F.oneTime({ requires = { quests = { "c" } } }),
					c = F.oneTime({ requires = { quests = { "a" } } }),
				}),
				env()
			)
			expectOne(cycle, "requirement cycle")
			local noRebirth = table.clone(ALL_ON)
			noRebirth.Rebirth = false
			expectOne(
				Validate.check(
					cfg({ a = F.oneTime({ requires = { rebirths = 2 } }) }),
					env({ enabled = noRebirth })
				),
				"requires.rebirths needs Rebirth"
			)
			local noInventory = table.clone(ALL_ON)
			noInventory.Inventory = false
			expectOne(
				Validate.check(
					cfg({ a = F.oneTime({ requires = { items = { "coin" } } }) }),
					env({ enabled = noInventory })
				),
				"requires.items needs Inventory"
			)
			expectOne(
				Validate.check(cfg({ a = F.oneTime({ requires = { items = { "unicorn" } } }) }), env()),
				"requires unknown item 'unicorn'"
			)
		end
	)

	it("weight not finite or <= 0", function()
		expectOne(
			Validate.check(cfg({ a = F.daily({ weight = 0 }) }), env()),
			"weight must be a finite number > 0"
		)
		expectOne(
			Validate.check(cfg({ a = F.daily({ weight = math.huge }) }), env()),
			"weight must be a finite number > 0"
		)
		expectOne(
			Validate.check(cfg({ a = F.daily({ weight = 0 / 0 }) }), env()),
			"weight must be a finite number > 0"
		)
	end)

	it("daily.count / weekly.count larger than a non-empty pool of non-retired quests", function()
		expectOne(
			Validate.check(
				cfg(
					{ a = F.daily(), b = F.daily({ retired = true }) },
					{ daily = { count = 2, rerollsPerSlot = 0 } }
				),
				env()
			),
			"daily.count 2 is larger than the daily pool (1"
		)
		expectOne(
			Validate.check(cfg({ w = F.weekly() }, { weekly = { count = 3, rerollsPerSlot = 0 } }), env()),
			"weekly.count 3"
		)
	end)

	it("cap out of range", function()
		expectOne(
			Validate.check(cfg({ r = F.repeatable({ cap = 0 }) }), env()),
			"cap must be an integer 1..100"
		)
		expectOne(
			Validate.check(cfg({ r = F.repeatable({ cap = 101 }) }), env()),
			"cap must be an integer 1..100"
		)
	end)

	it("an event quest whose event isn't in GameConfig.events, or has none", function()
		expectOne(
			Validate.check(cfg({ e = F.event("ghostEvent") }), env()),
			"event 'ghostEvent' is not in GameConfig.events"
		)
		expectOne(Validate.check(cfg({ e = F.quest("event") }), env()), "needs event")
	end)
end)

describe("Quests validation: all problems together", function()
	it("collects every problem in one sorted list", function()
		local errors = Validate.check(
			cfg({
				a = F.quest("monthly"),
				b = F.daily({ weight = -1 }),
				c = F.oneTime({ reward = { F.custom("nobody") } }),
			}, { chains = { c = { "ghost" } } }),
			env()
		)
		expect(#errors).toBe(4)
		local sortedCopy = table.clone(errors)
		table.sort(sortedCopy)
		expect(errors).toEqual(sortedCopy)
	end)

	it("fails the boot with every problem in one message", function()
		local _, err = StudWork.test.boot({
			modules = { Quests },
			config = {
				Quests = {
					quests = {
						a = F.quest("oneTime", { F.source("currencyEarned", 5) }),
						b = F.oneTime({ reward = { F.custom("nobody") } }),
					},
				},
			},
		})
		expect(err).never.toBe(nil)
		expect(string.find(err, "source 'currencyEarned' needs Economy", 1, true) ~= nil).toBe(true)
		expect(string.find(err, "'nobody' is not registered", 1, true) ~= nil).toBe(true)
	end)

	it("refuses a paid roll table at boot through Rarity's real odds", function()
		local _, err = StudWork.test.boot({
			modules = {
				F.Quests,
				require(Modules:WaitForChild("Items"):WaitForChild("module")),
				require(Modules:WaitForChild("Rarity"):WaitForChild("module")),
				require(Modules:WaitForChild("Inventory"):WaitForChild("module")),
			},
			items = F.items(),
			config = {
				Rarity = F.rarity(),
				Quests = { quests = { a = F.oneTime({ reward = { F.roll("PaidCrate") } }) } },
			},
		})
		expect(err).never.toBe(nil)
		expect(string.find(err, "'PaidCrate' is paid", 1, true) ~= nil).toBe(true)
		local h, okErr = StudWork.test.boot({
			modules = {
				F.Quests,
				require(Modules:WaitForChild("Items"):WaitForChild("module")),
				require(Modules:WaitForChild("Rarity"):WaitForChild("module")),
				require(Modules:WaitForChild("Inventory"):WaitForChild("module")),
			},
			items = F.items(),
			config = {
				Rarity = F.rarity(),
				Quests = { quests = { a = F.oneTime({ reward = { F.roll("FreeCrate") } }) } },
			},
		})
		expect(okErr).toBe(nil)
		expect(h:use(F.Quests).def("a").reward[1].table).toBe("FreeCrate")
	end)
end)
