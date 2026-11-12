--!nocheck
--[[
	Leaderboards: a `max` or `sum` submit waits in memory and joins the player's save in one
	update (every 30 s on the player's own phase, before each store write, on leave and on
	shutdown), so a game can submit every tick without a save commit per submit. These specs pin
	the guarantees that change must keep: nothing accepted is lost on leave or shutdown, a lower
	value never overwrites a best, a submit counts in its own period, txApi and pending values add
	up exactly once, and an idle tick reads no player's save.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Harness = require("packages/framework/test/harness.luau")
local Loader = require("packages/framework/server/Loader.luau")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Leaderboards = require(Modules:WaitForChild("Leaderboards"):WaitForChild("module"))

local DAY = 86400
local HOUR = 3600
local NOON = 19000 * DAY + 12 * HOUR -- a UTC noon, years before the real clock
local FOLD = 30 -- the page's fold window (seconds)

local function boot(config: any, opts: any?)
	local o = opts or {}
	config.refreshSeconds = config.refreshSeconds or 1000
	return Harness.new({
		modules = { Leaderboards },
		servers = {
			Leaderboards = Loader.defaultLoadServer({ name = "Leaderboards", server = "Leaderboards" }),
		},
		startTime = o.startTime or NOON,
		config = { Leaderboards = config },
		services = { UserService = StudWork.test.fakes.userService() },
	})
end

local function version(h: any, p: any): number
	return h.runtime.data.sectionVersion(p, "leaderboards")
end

local function saved(h: any, p: any): any
	return h.runtime.data.view(p, "leaderboards")
end

local function mapValue(h: any, name: string): number?
	local rows = h:sortedMap("Leaderboards", name).entries()
	return if rows[1] then rows[1].value.v else nil
end

describe("Leaderboards: pending submits", function()
	it(
		"a sum submit waits in memory (no save commit), rank shows it at once, the save gets it within 30 s",
		function()
			local h = boot({ boards = { total = { mode = "sum" } }, writeSeconds = 1000 })
			local p = h:addPlayer({ userId = 1 })
			local lb = h:use(Leaderboards)
			local store = h:orderedStore("Leaderboards", "total")
			expect(lb.submit(p, "total", 1)).toBe(true)
			h:tick(1) -- the first write is due at once
			expect(store.entries()).toEqual({ ["1"] = 1 })
			local before = version(h, p)
			for _ = 1, 3 do
				expect(lb.submit(p, "total", 5)).toBe(true)
			end
			expect(version(h, p)).toBe(before) -- no transaction per submit
			expect(select(2, lb.rank(p, "total"))).toBe(16)
			h:tick(FOLD + 1)
			expect(saved(h, p).values.total).toBe(16)
			expect(saved(h, p).dirty.total).toBe(true) -- the store write follows on the cadence
			expect(store.entries()).toEqual({ ["1"] = 1 }) -- writeSeconds not over yet
		end
	)

	it("leave: the pending value is saved and written to the store", function()
		local h = boot({ boards = { total = { mode = "sum" } }, writeSeconds = 1000 })
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		lb.submit(p, "total", 1)
		h:tick(1)
		lb.submit(p, "total", 7)
		h:removePlayer(p)
		expect(h:saved(p).leaderboards.values.total).toBe(8)
		expect(h:orderedStore("Leaderboards", "total").entries()).toEqual({ ["1"] = 8 })
	end)

	it("shutdown: every player's pending value is saved and written", function()
		local h = boot({
			boards = { total = { mode = "sum" }, today = { period = "daily", mode = "max" } },
			writeSeconds = 1000,
		})
		local a = h:addPlayer({ userId = 1 })
		local b = h:addPlayer({ userId = 2 })
		local lb = h:use(Leaderboards)
		lb.submit(a, "total", 3)
		lb.submit(b, "today", 9)
		h:tick(1)
		lb.submit(a, "total", 4)
		lb.submit(b, "today", 11)
		h:shutdown()
		expect(h:saved(a).leaderboards.values.total).toBe(7)
		expect(h:saved(b).leaderboards.periods.today.value).toBe(11)
		expect(h:orderedStore("Leaderboards", "total").entries()).toEqual({ ["1"] = 7 })
		expect(mapValue(h, "today/19000/0")).toBe(11)
	end)

	it("max: a lower value never overwrites the best and writes nothing; a better one is kept", function()
		local h = boot({ boards = { best = { mode = "max" } }, writeSeconds = 1000 })
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		lb.submit(p, "best", 10)
		h:tick(1)
		local before = version(h, p)
		expect(lb.submit(p, "best", 4)).toBe(true)
		h:tick(FOLD + 1)
		expect(version(h, p)).toBe(before) -- nothing to fold, nothing committed
		expect(select(2, lb.rank(p, "best"))).toBe(10)
		expect(lb.submit(p, "best", 12)).toBe(true)
		expect(lb.submit(p, "best", 11)).toBe(true)
		expect(select(2, lb.rank(p, "best"))).toBe(12)
		h:removePlayer(p)
		expect(h:saved(p).leaderboards.values.best).toBe(12)
		expect(h:orderedStore("Leaderboards", "best").entries()).toEqual({ ["1"] = 12 })
	end)

	it("a pending daily value counts in its own day when the next submit comes after midnight", function()
		local h = boot(
			{ boards = { today = { period = "daily", mode = "sum" } }, writeSeconds = 5 },
			{ startTime = 19001 * DAY - 10 }
		)
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		lb.submit(p, "today", 3)
		h:tick(1) -- written: day 19000 = 3
		lb.submit(p, "today", 4) -- pending, day 19000
		h.clock += 15 -- past midnight without a tick (no fold ran)
		lb.submit(p, "today", 6) -- day 19001: the day-19000 value joins the save first
		expect(select(2, lb.rank(p, "today"))).toBe(6)
		h:tick(FOLD + 10)
		expect(mapValue(h, "today/19000/0")).toBe(7)
		expect(mapValue(h, "today/19001/0")).toBe(6)
		expect(saved(h, p).periods.today.id).toBe("19001")
		expect(saved(h, p).periods.today.value).toBe(6)
	end)

	it("txApi.submit and a pending submit on the same board add up exactly once", function()
		local h = boot({ boards = { total = { mode = "sum" } }, writeSeconds = 1000 })
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		lb.submit(p, "total", 5)
		h.runtime.data.runTx(p, function(tx)
			expect(h.runtime.txApis[Leaderboards].submit(tx, "total", 3)).toBe(true)
		end)
		expect(select(2, lb.rank(p, "total"))).toBe(8)
		h:tick(FOLD + 1)
		expect(saved(h, p).values.total).toBe(8)
		h:removePlayer(p)
		expect(h:saved(p).leaderboards.values.total).toBe(8)
		expect(h:orderedStore("Leaderboards", "total").entries()).toEqual({ ["1"] = 8 })
	end)

	it("a txApi.submit after midnight takes the earlier day's pending value into that day, once", function()
		local h = boot(
			{ boards = { today = { period = "daily", mode = "sum" } }, writeSeconds = 5 },
			{ startTime = 19001 * DAY - 10 }
		)
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		lb.submit(p, "today", 3)
		h:tick(1)
		lb.submit(p, "today", 4) -- pending, day 19000
		h.clock += 15
		h.runtime.data.runTx(p, function(tx)
			expect(h.runtime.txApis[Leaderboards].submit(tx, "today", 2)).toBe(true)
		end)
		h:tick(FOLD + 10)
		expect(mapValue(h, "today/19000/0")).toBe(7)
		expect(mapValue(h, "today/19001/0")).toBe(2)
		expect(select(2, lb.rank(p, "today"))).toBe(2)
		h:removePlayer(p)
		expect(h:saved(p).leaderboards.periods.today.value).toBe(2)
	end)

	it("two txApi.submits in one tx after midnight both count; the pending value counts once", function()
		local h = boot(
			{ boards = { today = { period = "daily", mode = "sum" } }, writeSeconds = 5 },
			{ startTime = 19001 * DAY - 10 }
		)
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		lb.submit(p, "today", 3)
		h:tick(1)
		lb.submit(p, "today", 4) -- pending, day 19000
		h.clock += 15
		h.runtime.data.runTx(p, function(tx)
			expect(h.runtime.txApis[Leaderboards].submit(tx, "today", 2)).toBe(true)
			expect(h.runtime.txApis[Leaderboards].submit(tx, "today", 5)).toBe(true)
		end)
		h:tick(FOLD + 10)
		expect(mapValue(h, "today/19000/0")).toBe(7)
		expect(mapValue(h, "today/19001/0")).toBe(7)
		expect(select(2, lb.rank(p, "today"))).toBe(7)
		h:removePlayer(p)
		expect(h:saved(p).leaderboards.periods.today.value).toBe(7)
	end)

	it("a rolled-back txApi.submit leaves the pending value pending", function()
		local h = boot({ boards = { total = { mode = "sum" } }, writeSeconds = 1000 })
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		lb.submit(p, "total", 5)
		local ok = pcall(h.runtime.data.runTx, p, function(tx)
			h.runtime.txApis[Leaderboards].submit(tx, "total", 99)
			error("rollback")
		end)
		expect(ok).toBe(false)
		expect(select(2, lb.rank(p, "total"))).toBe(5)
		h:removePlayer(p)
		expect(h:saved(p).leaderboards.values.total).toBe(5)
	end)

	it("an idle tick reads no player's save; a submit wakes only that player", function()
		local h = boot({ boards = { total = { mode = "sum" } }, writeSeconds = 5 })
		local players = {}
		for i = 1, 5 do
			players[i] = h:addPlayer({ userId = i })
		end
		local lb = h:use(Leaderboards)
		h:tick(101) -- each player's first visit, and the board's first (staggered) refresh, which
		-- republishes every player's `mine`; the next refresh is refreshSeconds (1000 s) away
		local data = h.runtime.data
		local view = data.view
		local reads = 0
		data.view = function(player, key)
			if key == "leaderboards" then
				reads += 1
			end
			return view(player, key)
		end
		h:tick(60)
		expect(reads).toBe(0)
		lb.submit(players[3], "total", 2)
		h:tick(2)
		expect(reads > 0).toBe(true)
		expect(reads <= 3).toBe(true) -- one player's fold and write, not five
		data.view = view
		expect(h:orderedStore("Leaderboards", "total").entries()).toEqual({ ["3"] = 2 })
	end)
end)
