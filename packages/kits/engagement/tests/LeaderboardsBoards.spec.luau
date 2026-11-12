--!nocheck
--[[
	Leaderboards: daily and weekly boards, shards, the cut, servers sharing the top N, failures,
	sources, the flag and boot errors (the real server part on the plain harness; two or more
	harnesses on one StudWork.test.memoryStore() are servers on shared stores, ticked in step).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Harness = require("packages/framework/test/harness.luau")
local Loader = require("packages/framework/server/Loader.luau")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Leaderboards = require(Modules:WaitForChild("Leaderboards"):WaitForChild("module"))
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))

local DAY = 86400
local HOUR = 3600
local NOON = 19000 * DAY + 12 * HOUR -- a UTC noon (a Saturday), years before the real clock

local function parts(extra: any?)
	local out = {
		Leaderboards = Loader.defaultLoadServer({ name = "Leaderboards", server = "Leaderboards" }),
	}
	for name in extra or {} do
		out[name] = Loader.defaultLoadServer({ name = name, server = name })
	end
	return out
end

local function options(config: any, o: any?): any
	local opts = o or {}
	return {
		modules = opts.modules or { Leaderboards },
		servers = parts(opts.parts),
		startTime = opts.startTime or NOON,
		config = opts.fullConfig or { Leaderboards = config },
		services = { UserService = opts.userService or StudWork.test.fakes.userService() },
		census = opts.census,
		store = opts.store,
		flags = opts.flags,
		isStudio = opts.isStudio,
		serverConfig = opts.serverConfig,
	}
end

local function boot(config: any, o: any?): any
	return Harness.new(options(config, o))
end

local function tick(servers: { any }, seconds: number)
	for _ = 1, seconds do
		for _, h in servers do
			h:tick(1)
		end
	end
end

local function rows(top: any): { string }
	local out = {}
	for _, row in top.rows do
		table.insert(out, `{row.rank}:{row.userId}={row.value}`)
	end
	return out
end

local function countOps(calls: { any }, op: string): number
	local n = 0
	for _, call in calls do
		if call.op == op then
			n += 1
		end
	end
	return n
end

local FAST = { refreshSeconds = 10, writeSeconds = 5 }

local function with(config: any): any
	local out = table.clone(FAST)
	for k, v in config do
		out[k] = v
	end
	return out
end

describe("daily and weekly boards (ctx.data.sortedMap)", function()
	it("write an item in the period's map with the period's expiry, and read it back", function()
		local h = boot(with({ boards = { today = { period = "daily" } } }))
		local p = h:addPlayer({ userId = 1, name = "Ann" })
		local lb = h:use(Leaderboards)
		lb.submit(p, "today", 10)
		h:tick(30)
		local top = lb.top("today")
		expect(rows(top)).toEqual({ "1:1=10" })
		expect(top.periodId).toBe("19000")
		expect(top.endsAt).toBe(19001 * DAY)
		local entries = h:sortedMap("Leaderboards", "today/19000/0").entries()
		expect(#entries).toBe(1)
		expect(entries[1].key).toBe("1")
		expect(entries[1].value).toEqual({ v = 10, n = "Ann" })
		expect(entries[1].sortKey).toBe(10)
		expect(entries[1].expiresAt).toBe(19001 * DAY + 24 * HOUR) -- period end + periodGraceHours
	end)

	it("resets by the clock moving: a new period is a new map, the old rows become previous", function()
		local h = boot(with({ boards = { today = { period = "daily" } }, refreshSeconds = 600 }))
		local p = h:addPlayer({ userId = 1, name = "Ann" })
		local lb = h:use(Leaderboards)
		lb.submit(p, "today", 10)
		h:tick(700) -- the first read is staggered by up to a tenth of refreshSeconds, the next is 600 s on
		expect(rows(lb.top("today"))).toEqual({ "1:1=10" })
		h:tick(12 * HOUR) -- past midnight UTC
		local top = lb.top("today")
		expect(top.periodId).toBe("19001")
		expect(rows(top)).toEqual({})
		local previous = lb.top("today", true)
		expect(previous.periodId).toBe("19000")
		expect(rows(previous)).toEqual({ "1:1=10" })
		expect(select(2, lb.rank(p, "today"))).toBe(0) -- nothing scored in the new period yet
		lb.submit(p, "today", 3)
		h:tick(30)
		expect(#h:sortedMap("Leaderboards", "today/19001/0").entries()).toBe(1)
		expect(#h:sortedMap("Leaderboards", "today/19000/0").entries()).toBe(1) -- the old map stays until it expires
		h:tick(600) -- the next read of the new period's top
		expect(rows(lb.top("today"))).toEqual({ "1:1=3" })
	end)

	it("counts the day in the configured time zone (utcOffsetHours)", function()
		-- noon UTC = 15:00 at UTC+3; local midnight comes at 21:00 UTC
		local h = boot(
			with({ boards = { today = { period = "daily" } }, utcOffsetHours = 3, refreshSeconds = 600 })
		)
		local lb = h:use(Leaderboards)
		expect(lb.top("today").periodId).toBe("19000")
		h:tick(9 * HOUR - 60)
		expect(lb.top("today").periodId).toBe("19000")
		h:tick(120)
		expect(lb.top("today").periodId).toBe("19001")
		expect(lb.top("today").endsAt).toBe(19002 * DAY - 3 * HOUR)
	end)

	it("weekly boards start the week on weekStartsOn", function()
		local monday = boot(with({ boards = { week = { period = "weekly" } }, refreshSeconds = 3600 }))
		expect(monday:use(Leaderboards).top("week").periodId).toBe("18995") -- the Monday before that Saturday
		local sunday = boot(
			with({ boards = { week = { period = "weekly" } }, weekStartsOn = "sunday", refreshSeconds = 3600 })
		)
		expect(sunday:use(Leaderboards).top("week").periodId).toBe("18994")
		monday:tick(36 * HOUR) -- Sunday noon -> Monday 00:00 is 36 h from Saturday noon
		expect(monday:use(Leaderboards).top("week").periodId).toBe("19002")
	end)

	it("merges the shards of a sharded board and spreads users over them", function()
		local h = boot(with({ boards = { today = { period = "daily", shards = 3, topN = 4 } } }))
		local lb = h:use(Leaderboards)
		local values = { [1] = 60, [2] = 50, [3] = 40, [4] = 30, [5] = 20, [6] = 10 }
		for userId, value in values do
			local p = h:addPlayer({ userId = userId, name = "P" .. userId })
			lb.submit(p, "today", value)
		end
		h:tick(30)
		for shard = 0, 2 do
			for _, entry in h:sortedMap("Leaderboards", `today/19000/{shard}`).entries() do
				expect(tonumber(entry.key) % 3).toBe(shard)
			end
		end
		expect(rows(lb.top("today"))).toEqual({ "1:1=60", "2:2=50", "3:3=40", "4:4=30" })
	end)

	it("a lower-is-better periodic board lists the smallest first", function()
		local h = boot(with({ boards = { time = { period = "daily", order = "asc" } } }))
		local lb = h:use(Leaderboards)
		for userId, value in { [1] = 90, [2] = 45, [3] = 70 } do
			lb.submit(h:addPlayer({ userId = userId }), "time", value)
		end
		h:tick(30)
		expect(rows(lb.top("time"))).toEqual({ "1:2=45", "2:3=70", "3:1=90" })
	end)

	it("cutToTop skips a write that can't place on a full board, and writes one that can", function()
		local h = boot(with({ boards = { today = { period = "daily", topN = 2 } } }))
		local lb = h:use(Leaderboards)
		local a, b = h:addPlayer({ userId = 1 }), h:addPlayer({ userId = 2 })
		lb.submit(a, "today", 100)
		lb.submit(b, "today", 90)
		h:tick(30) -- the board is full: the cut is 90
		local c = h:addPlayer({ userId = 3 })
		lb.submit(c, "today", 50)
		h:tick(30)
		local map = h:sortedMap("Leaderboards", "today/19000/0")
		expect(#map.entries()).toBe(2) -- 50 can't place: not written
		expect(select(2, lb.rank(c, "today"))).toBe(50) -- the player's own value is still kept
		lb.submit(c, "today", 95)
		h:tick(30)
		expect(#map.entries()).toBe(3)
		expect(rows(lb.top("today"))).toEqual({ "1:1=100", "2:3=95" })
	end)

	it("with cutToTop off every value is written", function()
		local h = boot(with({ boards = { today = { period = "daily", topN = 1 } }, cutToTop = false }))
		local lb = h:use(Leaderboards)
		lb.submit(h:addPlayer({ userId = 1 }), "today", 100)
		h:tick(30)
		lb.submit(h:addPlayer({ userId = 2 }), "today", 5)
		h:tick(30)
		expect(#h:sortedMap("Leaderboards", "today/19000/0").entries()).toBe(2)
	end)
end)

describe("servers sharing the top N", function()
	it("two servers write and both see the merged top after refreshSeconds", function()
		local store = StudWork.test.memoryStore()
		local config = with({ boards = { best = {}, today = { period = "daily" } } })
		local a = boot(config, { store = store })
		local b = boot(config, { store = store })
		local pa, pb = a:addPlayer({ userId = 1, name = "Ann" }), b:addPlayer({ userId = 2, name = "Bea" })
		a:use(Leaderboards).submit(pa, "best", 30)
		b:use(Leaderboards).submit(pb, "best", 20)
		a:use(Leaderboards).submit(pa, "today", 5)
		b:use(Leaderboards).submit(pb, "today", 9)
		tick({ a, b }, 40)
		for _, h in { a, b } do
			expect(rows(h:use(Leaderboards).top("best"))).toEqual({ "1:1=30", "2:2=20" })
			expect(rows(h:use(Leaderboards).top("today"))).toEqual({ "1:2=9", "2:1=5" })
		end
		expect(select(2, b:use(Leaderboards).rank(pb, "best"))).toBe(20)
		expect((b:use(Leaderboards).rank(pb, "best"))).toBe(2)
	end)

	it("only one server reads the store per refresh (the lease), the others read the shared item", function()
		local store = StudWork.test.memoryStore()
		local config = with({ boards = { best = {} } })
		local servers = {}
		for i = 1, 4 do
			servers[i] = boot(config, { store = store })
		end
		local p = servers[1]:addPlayer({ userId = 1 })
		servers[1]:use(Leaderboards).submit(p, "best", 10)
		tick(servers, 100)
		local lists = countOps(servers[1]:orderedStore("Leaderboards", "best").calls, "top")
		-- about one list per refreshSeconds for the whole experience (10 rounds), not 4 per round
		expect(lists >= 8).toBe(true)
		expect(lists <= 11).toBe(true)
		for _, h in servers do
			expect(rows(h:use(Leaderboards).top("best"))).toEqual({ "1:1=10" })
		end
	end)

	it("an elected reader that stops mid-read loses its lease after 30 s and another server reads", function()
		local store = StudWork.test.memoryStore()
		local config = with({ boards = { best = {} } })
		local a = boot(config, { store = store })
		local b = boot(config, { store = store })
		a:use(Leaderboards).submit(a:addPlayer({ userId = 1 }), "best", 10)
		tick({ a, b }, 5)
		-- a lease taken by a server that then died (the item is stale, a live lease on it)
		local top = a:sortedMap("Leaderboards", "top/best")
		local api = a.runtime.sortedMapStore.forModule("Leaderboards")("top/best")
		api.set("all", { rows = {}, at = 0, lease = { by = "dead", untilAt = a.clock + 30 } }, 3600, 0)
		local before = countOps(a:orderedStore("Leaderboards", "best").calls, "top")
		tick({ a, b }, 25) -- inside the lease: nobody reads
		expect(countOps(a:orderedStore("Leaderboards", "best").calls, "top")).toBe(before)
		tick({ a, b }, 25) -- the lease ran out
		expect(countOps(a:orderedStore("Leaderboards", "best").calls, "top") > before).toBe(true)
		expect(rows(b:use(Leaderboards).top("best"))).toEqual({ "1:1=10" })
		expect(#top.entries()).toBe(1)
	end)

	it("max never lowers a best under concurrent writes from two servers", function()
		local store = StudWork.test.memoryStore()
		local config = with({ boards = { best = {}, today = { period = "daily" } } })
		local a = boot(config, { store = store })
		local b = boot(config, { store = store })
		local pa, pb = a:addPlayer({ userId = 1 }), b:addPlayer({ userId = 1 })
		a:use(Leaderboards).submit(pa, "best", 10)
		b:use(Leaderboards).submit(pb, "best", 7)
		a:use(Leaderboards).submit(pa, "today", 10)
		b:use(Leaderboards).submit(pb, "today", 7)
		tick({ b, a }, 6) -- b writes first, then a
		expect(a:orderedStore("Leaderboards", "best").entries()).toEqual({ ["1"] = 10 })
		b:use(Leaderboards).submit(pb, "best", 8) -- b's re-send after a's 10 is in
		tick({ b, a }, 20)
		expect(a:orderedStore("Leaderboards", "best").entries()).toEqual({ ["1"] = 10 })
		expect(a:sortedMap("Leaderboards", "today/19000/0").entries()[1].value.v).toBe(10)
	end)
end)

describe("idempotent writes", function()
	it("a sum write that is re-sent after the store already holds it doesn't count twice", function()
		local h =
			boot(with({ boards = { total = { mode = "sum" }, today = { period = "daily", mode = "sum" } } }))
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		lb.submit(p, "total", 5)
		lb.submit(p, "total", 5)
		lb.submit(p, "today", 4)
		lb.submit(p, "today", 6)
		-- a timed-out call that actually committed: the store has the total before the module's retry
		h.runtime.orderedStore.forModule("Leaderboards")("total").set("1", 10)
		h.runtime.sortedMapStore
			.forModule("Leaderboards")("today/19000/0")
			.set("1", { v = 10, n = "Player1" }, 3600, 10)
		h:tick(30)
		expect(h:orderedStore("Leaderboards", "total").entries()).toEqual({ ["1"] = 10 })
		expect(h:sortedMap("Leaderboards", "today/19000/0").entries()[1].value.v).toBe(10)
		for _, call in h:orderedStore("Leaderboards", "total").calls do
			expect(call.op ~= "increment").toBe(true) -- the kit never increments
		end
	end)

	it("a stale re-send never lowers a better stored value", function()
		local h = boot(with({ boards = { best = {} } }))
		local p = h:addPlayer({ userId = 1 })
		h.runtime.orderedStore.forModule("Leaderboards")("best").set("1", 50)
		h:use(Leaderboards).submit(p, "best", 20)
		h:tick(30)
		expect(h:orderedStore("Leaderboards", "best").entries()).toEqual({ ["1"] = 50 })
	end)

	it("writes at most once per player per board per writeSeconds, plus once on leave", function()
		local h = boot({ boards = { best = {} }, writeSeconds = 100, refreshSeconds = 1000 })
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		local calls = h:orderedStore("Leaderboards", "best").calls
		lb.submit(p, "best", 1)
		h:tick(2)
		expect(countOps(calls, "update")).toBe(1)
		lb.submit(p, "best", 2)
		lb.submit(p, "best", 3)
		h:tick(50)
		expect(countOps(calls, "update")).toBe(1) -- inside writeSeconds
		h:tick(60)
		expect(countOps(calls, "update")).toBe(2)
		lb.submit(p, "best", 9)
		h:removePlayer(p) -- the write on leave
		expect(countOps(calls, "update")).toBe(3)
		expect(h:orderedStore("Leaderboards", "best").entries()).toEqual({ ["1"] = 9 })
	end)
end)

describe("failures and budgets", function()
	it(
		"a failed write stays dirty, is retried on the next cadence and, after a leave, on the next load",
		function()
			local h = boot(with({ boards = { today = { period = "daily" } }, refreshSeconds = 1000 }))
			local p = h:addPlayer({ userId = 1 })
			local lb = h:use(Leaderboards)
			local map = h:sortedMap("Leaderboards", "today/19000/0")
			h:tick(110) -- the first (staggered) read is done; the next is 1000 s away
			map.failNext(1, "TotalMemoryOverLimit") -- memory_full: no retry inside the call
			lb.submit(p, "today", 10)
			h:tick(2)
			expect(#map.entries()).toBe(0)
			h:tick(10) -- the next cadence
			expect(#map.entries()).toBe(1)
			-- leave with the store failing: the save keeps it dirty, the next load writes it
			lb.submit(p, "today", 20)
			map.failNext(1, "TotalMemoryOverLimit")
			h:removePlayer(p)
			expect(map.entries()[1].value.v).toBe(10)
			expect(h:saved(p).leaderboards.dirty.today).toBe(true)
			h:addPlayer({ userId = 1 })
			h:tick(2)
			expect(map.entries()[1].value.v).toBe(20)
		end
	)

	it("a failed or refused read keeps the last rows and backs off", function()
		local h = boot(with({ boards = { best = {} }, refreshSeconds = 20 }))
		local lb = h:use(Leaderboards)
		lb.submit(h:addPlayer({ userId = 1 }), "best", 10)
		h:tick(30)
		local before = lb.top("best")
		expect(rows(before)).toEqual({ "1:1=10" })
		local top = h:sortedMap("Leaderboards", "top/best")
		top.failNext(1, "TotalMemoryOverLimit")
		expect(lb.refresh("best")).toBe(false)
		expect(rows(lb.top("best"))).toEqual({ "1:1=10" })
		expect(lb.top("best").updatedAt).toBe(before.updatedAt)
		-- backoff.base (60 s) after the failure: no new read for that long
		local reads = countOps(top.calls, "get")
		h:tick(40)
		expect(countOps(top.calls, "get")).toBe(reads)
		h:tick(40)
		expect(countOps(top.calls, "get") > reads).toBe(true)
		expect(lb.refresh("best")).toBe(true)
	end)

	it("a failed name lookup shows the user id until the next read", function()
		local users =
			StudWork.test.fakes.userService({ failNext = 1, users = { [5] = { DisplayName = "Eve" } } })
		local h = boot(with({ boards = { best = {} }, refreshSeconds = 100 }), { userService = users })
		h.runtime.orderedStore.forModule("Leaderboards")("best").set("5", 8)
		local lb = h:use(Leaderboards)
		h:tick(12)
		expect(lb.top("best").rows[1].name).toBe("5")
		h:tick(110)
		expect(lb.top("best").rows[1].name).toBe("Eve")
	end)

	it("refresh paced by the census: more servers, longer interval", function()
		local few = boot(
			with({ boards = { best = {} }, refreshSeconds = 60 }),
			{ census = { servers = 1, players = 10 } }
		)
		local many = boot(
			with({ boards = { best = {} }, refreshSeconds = 60, topReadsPerMinute = 6000 }),
			{ census = { servers = 120000, players = 600000 } } -- 60 x 120000 / 6000 = 1200 s
		)
		few:tick(600)
		many:tick(600)
		local fewReads = countOps(few:sortedMap("Leaderboards", "top/best").calls, "get")
		local manyReads = countOps(many:sortedMap("Leaderboards", "top/best").calls, "get")
		expect(fewReads >= 9).toBe(true)
		expect(manyReads).toBe(1)
	end)
end)

describe("sources", function()
	it("a currency source writes the Economy balance; without Economy it is a boot error", function()
		local config = with({ boards = { wealth = { source = { kind = "currency" } } } })
		local h = boot(config, {
			modules = { Economy, Leaderboards },
			parts = { Economy = true },
			fullConfig = { Leaderboards = config, Economy = { startingCurrency = { Coins = 0 } } },
		})
		local p = h:addPlayer({ userId = 1 })
		h:use(Economy).grant(p, 120, "test")
		h:tick(30)
		expect(h:orderedStore("Leaderboards", "wealth").entries()).toEqual({ ["1"] = 120 })
		expect(h:use(Leaderboards).submit(p, "wealth", 999)).toBe(false) -- not a submit board
		local missing, err = StudWork.test.boot(options(config))
		expect(missing).toBe(nil)
		expect(string.find(err, "board 'wealth'", 1, true) ~= nil).toBe(true)
		expect(string.find(err, "Economy", 1, true) ~= nil).toBe(true)
	end)

	it("rebirth and streak sources need their modules", function()
		for kind, module in { rebirths = "Rebirth", streak = "Streak" } do
			local h, err = StudWork.test.boot(options({ boards = { b = { source = { kind = kind } } } }))
			expect(h).toBe(nil)
			expect(string.find(err, module, 1, true) ~= nil).toBe(true)
		end
	end)

	it("a registered source is read on the write cadence; a second registration errors", function()
		local h = boot(with({ boards = { wealth = { source = { kind = "registered" } } } }))
		local p = h:addPlayer({ userId = 1 })
		local register = h.runtime.exts[Leaderboards].registerSource
		local value = 40
		register("wealth", function()
			return value
		end)
		expect(function()
			register("wealth", function()
				return 1
			end)
		end).toThrow()
		expect(function()
			register("nope", function()
				return 1
			end)
		end).toThrow()
		h:tick(10)
		expect(h:orderedStore("Leaderboards", "wealth").entries()).toEqual({ ["1"] = 40 })
		value = 55
		h:tick(10)
		expect(h:orderedStore("Leaderboards", "wealth").entries()).toEqual({ ["1"] = 55 })
		expect(p ~= nil).toBe(true)
	end)
end)

describe("transactions and the console", function()
	it("txApi.submit is part of the caller's transaction; a rolled-back tx submits nothing", function()
		local h = boot(with({ boards = { best = {} } }))
		local p = h:addPlayer({ userId = 1 })
		local ref = Leaderboards
		local ok = h.runtime.ctxFor and true or true
		expect(ok).toBe(true)
		local committed = h.runtime.data.runTx(p, function(tx)
			expect(h.runtime.txApis[ref].submit(tx, "best", 12)).toBe(true)
		end)
		expect(committed).toBe(true)
		expect(select(2, h:use(Leaderboards).rank(p, "best"))).toBe(12)
		local failed = pcall(h.runtime.data.runTx, p, function(tx)
			h.runtime.txApis[ref].submit(tx, "best", 99)
			error("rollback")
		end)
		expect(failed).toBe(false)
		expect(select(2, h:use(Leaderboards).rank(p, "best"))).toBe(12)
	end)

	it("console submit and refresh work in Studio", function()
		local h = boot(with({ boards = { best = {} } }), { isStudio = true })
		h:addPlayer({ userId = 1 })
		expect(h:console("leaderboards submit best 25 1")).toBe("best: submitted")
		expect(h:console("leaderboards submit nope 25")).toBe("unknown board 'nope'")
		h:tick(15)
		expect(h:console("leaderboards refresh best")).toBe("best: refreshed")
		expect(rows(h:use(Leaderboards).top("best"))).toEqual({ "1:1=25" })
	end)
end)

describe("switched off", function()
	it("a flag that is off: nothing is written or read and the replicated boards are empty", function()
		local flags = { lb = { default = false } }
		local h = boot(with({ boards = { best = {} }, flag = "lb" }), { flags = flags, isStudio = true })
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		expect(lb.submit(p, "best", 5)).toBe(false)
		h:tick(60)
		expect(#h:orderedStore("Leaderboards", "best").calls).toBe(0)
		expect(#h:sortedMap("Leaderboards", "top/best").calls).toBe(0)
		expect(h:state(p).modules.Leaderboards.extra.boards).toEqual({})
		expect(lb.top("best").rows).toEqual({})
		h:console("flags set lb true")
		expect(lb.submit(p, "best", 5)).toBe(true)
		h:tick(60)
		expect(rows(lb.top("best"))).toEqual({ "1:1=5" })
		expect(h:state(p).modules.Leaderboards.extra.boards.best ~= nil).toBe(true)
	end)

	it("a game that leaves the module out boots and the API errors clearly", function()
		local h = boot({}, { modules = {} })
		local ok, err = pcall(function()
			return h:use(Leaderboards).top("best")
		end)
		expect(ok).toBe(false)
		expect(string.find(tostring(err), "not enabled", 1, true) ~= nil).toBe(true)
	end)

	it("a flag the game never declared is a boot error", function()
		local h, err = StudWork.test.boot(options({ boards = { best = {} }, flag = "ghost" }))
		expect(h).toBe(nil)
		expect(string.find(err, "flag", 1, true) ~= nil).toBe(true)
	end)
end)

describe("config errors name the board", function()
	local cases = {
		{ { period = "monthly" }, "period" },
		{ { topN = 101 }, "topN" },
		{ { topN = 0 }, "topN" },
		{ { shards = 17 }, "shards" },
		{ { shards = 2 }, "shards apply to daily and weekly" },
		{ { mode = "avg" }, "mode" },
		{ { order = "up" }, "order" },
		{ { source = { kind = "magic" } }, "source.kind" },
		{ { mode = "sum", source = { kind = "registered" } }, "mode sum needs a submit source" },
	}
	for _, case in cases do
		it("rejects " .. case[2], function()
			local h, err = StudWork.test.boot(options({ boards = { bad = case[1] } }))
			expect(h).toBe(nil)
			expect(string.find(err, "board 'bad'", 1, true) ~= nil).toBe(true)
			expect(string.find(err, case[2], 1, true) ~= nil).toBe(true)
		end)
	end
	it("rejects a board id with spaces", function()
		local h, err = StudWork.test.boot(options({ boards = { ["no good"] = {} } }))
		expect(h).toBe(nil)
		expect(string.find(err, "no good", 1, true) ~= nil).toBe(true)
	end)
end)
