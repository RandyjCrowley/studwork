--!nocheck
-- SessionLeaderboard through the framework module harness (module-api.md §15), pure Lune:
--   tools/test examples/modules/session-leaderboard
-- With Economy enabled the real Economy DEFINITION is used with a stand-in server part that fires
-- CurrencyChanged (the real Economy server needs the engine; tests/RealKits.spec.luau boots it with
-- the real kit modules in the multi-server sim).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Signal = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Signal"))
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))

local DIR = "examples/modules/session-leaderboard"
local Definition = require(DIR .. "/module.luau")
local Server = require(DIR .. "/server/init.luau")

local KEY = "sessionLeaderboard"

local function economyStandIn()
	local changed = Signal.new("Economy.CurrencyChanged")
	local part = { api = { signals = { CurrencyChanged = changed } } }
	return part, changed
end

local function boot(opts: any?): any
	local o = opts or {}
	local servers = { SessionLeaderboard = Server }
	local modules = { Definition }
	local changed = nil
	if o.economy then
		local part
		part, changed = economyStandIn()
		servers.Economy = part
		modules = { Economy, Definition }
	end
	local h =
		StudWork.test.harness({ modules = modules, servers = servers, config = o.config, store = o.store })
	return h, changed
end

local function subscribe(h: any, p: any)
	h:fire(p, "StateInit")
end

describe("SessionLeaderboard (example third-party module)", function()
	it("boots alone: Economy is optional, its own section is created with the defaults", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		local api = h:use(Definition)
		expect(api.earned(p)).toBe(0)
		expect(api.best(p)).toBe(0)
		expect(api.sessions(p)).toBe(1)
		expect(h.runtime.isEnabled(Economy)).toBe(false)
	end)

	it("counts points reported with api.add when Economy is off", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		local api = h:use(Definition)
		expect(api.add(p, 5)).toBe(true)
		expect(api.add(p, 2.5)).toBe(true)
		expect(api.earned(p)).toBe(7.5)
		expect(function()
			api.add(p, -1)
		end).toThrow("amount must be a finite number > 0")
		expect(function()
			api.add(p, 0 / 0)
		end).toThrow("finite")
		expect(api.add(StudWork.test.player(99), 1)).toBe(false) -- not loaded
	end)

	it("with Economy enabled, positive CurrencyChanged deltas are points (spends are not)", function()
		local h, changed = boot({ economy = true })
		local p = h:addPlayer({ userId = 1 })
		changed:Fire(p, "Coins", 10, 10, "income")
		changed:Fire(p, "Gems", 3, 3, "quest")
		changed:Fire(p, "Coins", 4, -6, "upgrade:IncomeBoost")
		expect(h:use(Definition).earned(p)).toBe(13)
	end)

	it("config.currency limits the points to one currency", function()
		local h, changed = boot({ economy = true, config = { SessionLeaderboard = { currency = "Coins" } } })
		local p = h:addPlayer({ userId = 1 })
		changed:Fire(p, "Coins", 10, 10, "income")
		changed:Fire(p, "Gems", 3, 3, "quest")
		expect(h:use(Definition).earned(p)).toBe(10)
	end)

	it("the shared ticker rebuilds the replicated top list every tickSeconds (config, default 5)", function()
		local h = boot({ config = { SessionLeaderboard = { top = 2, tickSeconds = 2 } } })
		local a = h:addPlayer({ userId = 1, name = "Ann" })
		local b = h:addPlayer({ userId = 2, name = "Bo" })
		local c = h:addPlayer({ userId = 3, name = "Cy" })
		subscribe(h, a)
		local api = h:use(Definition)
		api.add(a, 5)
		api.add(b, 9)
		api.add(c, 7)
		expect(#api.top()).toBe(0) -- nothing until the first tick
		h:tick(2)
		local top = api.top()
		expect(#top).toBe(2)
		expect(top[1].name).toBe("Bo")
		expect(top[1].earned).toBe(9)
		expect(top[2].userId).toBe(3)
		expect(table.isfrozen(top)).toBe(true)
		local slice = h:state(a).modules.SessionLeaderboard
		expect(slice.extra.top[1].name).toBe("Bo")
		expect(#slice.extra.top).toBe(2)
		expect(slice.extra.earned).toBe(5)
		expect(slice.data.best).toBe(5) -- saved on the tick, replicated from its own section
		expect(slice.data.sessions).toBeNil() -- not in data.replicate
	end)

	it("saves the best session in its own section; a weaker session doesn't lower it", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		local api = h:use(Definition)
		local bests = {}
		api.onNewBest(function(player, best)
			table.insert(bests, { player = player, best = best })
		end)
		api.add(p, 40)
		h:rejoin(p, { secondsAway = 600 }) -- leave saves the best; the next session starts at 0
		expect(api.best(p)).toBe(40)
		expect(api.earned(p)).toBe(0)
		expect(api.sessions(p)).toBe(2)
		api.add(p, 15)
		h:tick(5)
		expect(api.best(p)).toBe(40)
		expect(#bests).toBe(1)
		expect(bests[1].best).toBe(40)
		h:removePlayer(p)
		local saved = h:saved(p)
		local root = if saved and saved.Data then saved.Data else saved
		expect(root[KEY].best).toBe(40)
		expect(root[KEY].sessions).toBe(2)
	end)

	it("rejects a bad config at boot (schema), with the module named", function()
		local h, err = StudWork.test.boot({
			modules = { Definition },
			servers = { SessionLeaderboard = Server },
			config = { SessionLeaderboard = { top = 0 } },
		})
		expect(h).toBeNil()
		expect(string.find(err, "SessionLeaderboard", 1, true) ~= nil).toBe(true)
		expect(string.find(err, "top", 1, true) ~= nil).toBe(true)
	end)

	it("hands out a frozen public API", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		expect(function()
			h:use(Definition).earned = nil
		end).toThrow()
		expect(p.loaded).toBe(true)
	end)
end)
