--!nocheck
--[[
	Badges triggers (v1.7.0, docs/framework/kits/badges.md "Trigger"): each kind, a trigger already
	satisfied at join, and the boot errors for bad config. Real Economy and Streak; Rebirth,
	Inventory (+ Items) and Leaderboards are test doubles that fire their documented signals.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local Modules = ReplicatedStorage:WaitForChild("Modules")
local function kit(name)
	return require(Modules:WaitForChild(name):WaitForChild("module"))
end
local Badges = kit("Badges")
local Economy = kit("Economy")
local Streak = kit("Streak")
local Rebirth = kit("Rebirth")
local Items = kit("Items")
local Inventory = kit("Inventory")
local Leaderboards = kit("Leaderboards")

local fakes = StudWork.test.fakes
local DAY = 86400
local NOON = 19000 * DAY + 12 * 3600

-- a server-part double whose api.signals serves the signals its init creates
local function double(signalNames, api)
	local created = {}
	api.signals = setmetatable({}, {
		__index = function(_, k)
			return created[k]
		end,
	})
	return {
		api = api,
		init = function(ctx)
			for _, n in signalNames do
				created[n] = ctx.signals.new(n)
			end
		end,
		fire = function(name, ...)
			created[name]:Fire(...)
		end,
	}
end

local function boot(badges, extra)
	extra = extra or {}
	local fake = fakes.badgeService(extra.fakeOpts)
	local modules = { Badges }
	for _, m in extra.modules or {} do
		table.insert(modules, m)
	end
	local config = { Badges = { badges = badges } }
	for k, v in extra.config or {} do
		config[k] = v
	end
	local h = StudWork.test.harness({
		modules = modules,
		servers = extra.servers,
		config = config,
		services = { BadgeService = fake },
		startTime = NOON,
	})
	return h, fake
end

local function bootError(badges, extra)
	extra = extra or {}
	local modules = { Badges }
	for _, m in extra.modules or {} do
		table.insert(modules, m)
	end
	local h, err = StudWork.test.boot({
		modules = modules,
		config = { Badges = { badges = badges, flag = extra.flag } },
		services = { BadgeService = fakes.badgeService() },
		flags = extra.flags,
	})
	expect(h).toBe(nil)
	return tostring(err)
end

local ECON = { Economy = { startingCurrency = { Coins = 0 } } }

describe("Badges triggers", function()
	it("join: the player's first load only", function()
		local h, fake = boot({ hello = { id = 11, trigger = { kind = "join" } } })
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Badges).has(p, "hello")).toBe(true)
		expect(fake.owns(1, 11)).toBe(true)
	end)

	it("join: not on a second session", function()
		local store = StudWork.test.memoryStore()
		local h1 = StudWork.test.harness({ modules = {}, store = store })
		local p1 = h1:addPlayer({ userId = 3 })
		h1:removePlayer(p1) -- one session before the game listed Badges
		local h = StudWork.test.harness({
			modules = { Badges },
			config = { Badges = { badges = { hello = { id = 11, trigger = { kind = "join" } } } } },
			services = { BadgeService = fakes.badgeService() },
			store = store,
		})
		local p = h:addPlayer({ userId = 3 })
		expect(h:use(Badges).has(p, "hello")).toBe(false)
	end)

	it("streak: StreakAdvanced reaching atLeast, and a streak already satisfied at join", function()
		local h, fake = boot({
			day1 = { id = 21, trigger = { kind = "streak", atLeast = 1 } },
			day2 = { id = 22, trigger = { kind = "streak", atLeast = 2 } },
		}, { modules = { Economy, Streak }, config = ECON })
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Badges).has(p, "day1")).toBe(true)
		expect(h:use(Badges).has(p, "day2")).toBe(false)
		h:rejoin(p, { secondsAway = DAY })
		expect(h:use(Badges).has(p, "day2")).toBe(true)
		expect(fake.owns(1, 22)).toBe(true)
	end)

	it("rebirths: Rebirthed reaching atLeast", function()
		local rebirth = double({ "Rebirthed" }, {})
		local h, fake = boot({ reborn = { id = 31, trigger = { kind = "rebirths", atLeast = 2 } } }, {
			modules = { Economy, Rebirth },
			config = ECON,
			servers = { Rebirth = rebirth },
		})
		local p = h:addPlayer({ userId = 1 })
		rebirth.fire("Rebirthed", p, 1)
		expect(h:use(Badges).has(p, "reborn")).toBe(false)
		rebirth.fire("Rebirthed", p, 2)
		expect(h:use(Badges).has(p, "reborn")).toBe(true)
		expect(fake.owns(1, 31)).toBe(true)
	end)

	it("item: ItemAdded with that item id, and an item already owned at join", function()
		local list = {}
		local inventory = double({ "ItemAdded" }, {
			list = function()
				return list
			end,
		})
		local h = boot({
			gem = { id = 41, trigger = { kind = "item", item = "gem" } },
			star = { id = 42, trigger = { kind = "item", item = "star" } },
		}, {
			modules = { Items, Inventory },
			servers = { Items = {}, Inventory = inventory },
		})
		list = { { uid = "u1", itemId = "star" } }
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Badges).has(p, "star")).toBe(true) -- satisfied at join
		inventory.fire("ItemAdded", p, { uid = "u2", itemId = "pebble" })
		expect(h:use(Badges).has(p, "gem")).toBe(false)
		inventory.fire("ItemAdded", p, { uid = "u3", itemId = "gem" })
		expect(h:use(Badges).has(p, "gem")).toBe(true)
	end)

	it("currency: CurrencyChanged balance reaching atLeast (default the primary currency)", function()
		local h, fake = boot({ rich = { id = 51, trigger = { kind = "currency", atLeast = 100 } } }, {
			modules = { Economy },
			config = ECON,
		})
		local p = h:addPlayer({ userId = 1 })
		local economy = h:use(Economy)
		economy.grant(p, 60, "test")
		expect(h:use(Badges).has(p, "rich")).toBe(false)
		economy.grant(p, 40, "test")
		expect(h:use(Badges).has(p, "rich")).toBe(true)
		expect(fake.owns(1, 51)).toBe(true)
	end)

	it("currency: a balance already at atLeast fires on load", function()
		local h = boot(
			{ rich = { id = 51, trigger = { kind = "currency", currency = "Coins", atLeast = 10 } } },
			{
				modules = { Economy },
				config = { Economy = { startingCurrency = { Coins = 25 } } },
			}
		)
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Badges).has(p, "rich")).toBe(true)
	end)

	it("leaderboard: at or above rank on a board refresh", function()
		local ranks = {}
		local boards = double({ "BoardRefreshed" }, {
			rank = function(player, boardId)
				local r = ranks[boardId] and ranks[boardId][player.UserId]
				return r, 0
			end,
		})
		local h = boot(
			{ top3 = { id = 61, trigger = { kind = "leaderboard", board = "coins", rank = 3 } } },
			{
				modules = { Leaderboards },
				config = { Leaderboards = { boards = { coins = { period = "allTime" } } } },
				servers = { Leaderboards = boards },
			}
		)
		local p = h:addPlayer({ userId = 1 })
		local q = h:addPlayer({ userId = 2 })
		ranks.coins = { [1] = 5, [2] = 3 }
		boards.fire("BoardRefreshed", "other")
		expect(h:use(Badges).has(q, "top3")).toBe(false)
		boards.fire("BoardRefreshed", "coins")
		expect(h:use(Badges).has(q, "top3")).toBe(true)
		expect(h:use(Badges).has(p, "top3")).toBe(false)
	end)

	it("manual: only award() fires it", function()
		local h = boot({ quest = { id = 71, trigger = { kind = "manual" } } })
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Badges).has(p, "quest")).toBe(false)
		expect(h:use(Badges).award(p, "quest")).toBe(true)
	end)
end)

describe("Badges boot errors", function()
	it("a trigger on a module that isn't enabled names the badge and the module", function()
		local err = bootError({ day7 = { id = 1, trigger = { kind = "streak", atLeast = 7 } } })
		expect(err).toContain("config.Badges.badges.day7: trigger 'streak' needs the Streak module")
	end)

	it("bad keys, ids, kinds and trigger fields", function()
		local err = bootError({
			["bad key"] = { id = 1, trigger = { kind = "manual" } },
			neg = { id = -1, trigger = { kind = "manual" } },
			frac = { id = 1.5, trigger = { kind = "manual" } },
			what = { id = 1, trigger = { kind = "quest" } },
			nokind = { id = 1 },
		})
		expect(err).toContain("key 'bad key' must match")
		expect(err).toContain("config.Badges.badges.neg.id must be a badge id")
		expect(err).toContain("config.Badges.badges.frac.id must be a badge id")
		expect(err).toContain("trigger.kind 'quest' is not one of")
		expect(err).toContain("config.Badges.badges.nokind.trigger must be a table")
		local err2 = bootError(
			{ s = { id = 1, trigger = { kind = "streak", atLeast = 0 } } },
			{ modules = { Economy, Streak } }
		)
		expect(err2).toContain("config.Badges.badges.s.trigger.atLeast must be an integer >= 1")
	end)

	it("an undeclared config.flag is a boot error", function()
		local err = bootError({}, { flag = "nope" })
		expect(err).toContain("config.Badges.flag 'nope' is not declared")
	end)

	it("Rules: backoff, allowance and batches", function()
		local Rules = require("packages/kits/engagement/Badges/server/BadgeRules.luau")
		local retry = { base = 5, factor = 2, max = 300, attempts = 6 }
		expect(Rules.backoff(retry, 1)).toBe(5)
		expect(Rules.backoff(retry, 2)).toBe(10)
		expect(Rules.backoff(retry, 7)).toBe(300)
		expect(Rules.allowance({ base = 50, perPlayer = 35 }, 2)).toBe(120)
		expect(Rules.allowance({ base = 10, perPlayer = 5 }, 0)).toBe(10)
		local b = Rules.batches({ 1, 2, 3, 4, 5 }, 2)
		expect(b).toEqual({ { 1, 2 }, { 3, 4 }, { 5 } })
	end)
end)
