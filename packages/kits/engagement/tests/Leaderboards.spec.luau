--!nocheck
--[[
	Leaderboards on the plain StudWork harness (the real server part, in-memory ordered stores and
	sorted maps, the harness clock). Several harnesses on one StudWork.test.memoryStore() are
	several servers on shared stores; they are ticked in step because the stores run on one clock.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Harness = require("packages/framework/test/harness.luau")
local Loader = require("packages/framework/server/Loader.luau")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Leaderboards = require(Modules:WaitForChild("Leaderboards"):WaitForChild("module"))

local DAY = 86400
local HOUR = 3600
local NOON = 19000 * DAY + 12 * HOUR -- a UTC noon (a Tuesday), years before the real clock

local function boot(config: any, opts: any?)
	local o = opts or {}
	local h = Harness.new({
		modules = o.modules or { Leaderboards },
		servers = {
			Leaderboards = Loader.defaultLoadServer({ name = "Leaderboards", server = "Leaderboards" }),
		},
		startTime = o.startTime or NOON,
		config = { Leaderboards = config },
		services = { UserService = o.userService or StudWork.test.fakes.userService() },
		census = o.census,
		store = o.store,
		flags = o.flags,
		isStudio = o.isStudio,
		serverConfig = o.serverConfig,
	})
	return h
end

local function boardOf(h: any, p: any, boardId: string): any
	local state = h:state(p)
	return state.modules.Leaderboards.extra.boards[boardId]
end

local function mineOf(h: any, p: any, boardId: string): any
	return h:state(p).modules.Leaderboards.extra.mine[boardId]
end

local function rowsOf(top: any): { any }
	local out = {}
	for _, row in top.rows do
		table.insert(out, `{row.rank}:{row.userId}={row.value}`)
	end
	return out
end

describe("all-time boards (ctx.data.ordered)", function()
	it("submit modes: max keeps the best, set the latest, sum adds", function()
		local h = boot({
			boards = {
				best = { mode = "max" },
				last = { mode = "set", minValue = 0 },
				total = { mode = "sum" },
			},
		})
		local p = h:addPlayer({ userId = 1, name = "Ann" })
		local lb = h:use(Leaderboards)
		expect(lb.submit(p, "best", 10)).toBe(true)
		expect(lb.submit(p, "best", 4)).toBe(true)
		expect(lb.submit(p, "last", 7)).toBe(true)
		expect(lb.submit(p, "last", 3)).toBe(true)
		expect(lb.submit(p, "total", 5)).toBe(true)
		expect(lb.submit(p, "total", 6)).toBe(true)
		local _, best = lb.rank(p, "best")
		local _, last = lb.rank(p, "last")
		local _, total = lb.rank(p, "total")
		expect(best).toBe(10)
		expect(last).toBe(3)
		expect(total).toBe(11)
		h:tick(2)
		expect(h:orderedStore("Leaderboards", "best").entries()).toEqual({ ["1"] = 10 })
		expect(h:orderedStore("Leaderboards", "last").entries()).toEqual({ ["1"] = 3 })
		expect(h:orderedStore("Leaderboards", "total").entries()).toEqual({ ["1"] = 11 })
	end)

	it("refuses an unknown board, a bad value and a board whose source isn't submit", function()
		local h = boot({
			boards = { best = {}, wealth = { source = { kind = "registered" } } },
		})
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		expect(lb.submit(p, "nope", 1)).toBe(false)
		expect(lb.submit(p, "best", 0 / 0)).toBe(false)
		expect(lb.submit(p, "best", math.huge)).toBe(false)
		expect(lb.submit(p, "best", "9")).toBe(false)
		expect(lb.submit(p, "wealth", 5)).toBe(false)
		expect(lb.submit(p, "best", 3.9)).toBe(true) -- floored
		expect((select(2, lb.rank(p, "best")))).toBe(3)
	end)

	it("a value below minValue is kept but never written", function()
		local h = boot({ boards = { best = { minValue = 5 } } })
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		lb.submit(p, "best", 4)
		h:tick(5)
		expect(h:orderedStore("Leaderboards", "best").entries()).toEqual({})
		lb.submit(p, "best", 6)
		h:tick(5)
		expect(h:orderedStore("Leaderboards", "best").entries()).toEqual({ ["1"] = 6 })
	end)

	it("shows the top N with names from one batched lookup, own rank and replicated rows", function()
		local users = StudWork.test.fakes.userService({
			users = { [2] = { DisplayName = "Bea" }, [3] = { DisplayName = "Cy" } },
		})
		local h = boot({ boards = { best = { topN = 2 } } }, { userService = users })
		local a = h:addPlayer({ userId = 1, name = "Ann" })
		local lb = h:use(Leaderboards)
		local store = h:orderedStore("Leaderboards", "best")
		local board = h.runtime
		expect(board ~= nil).toBe(true)
		-- other servers' players, already in the store
		local ordered = h.runtime.orderedStore.forModule("Leaderboards")("best")
		ordered.set("2", 50)
		ordered.set("3", 40)
		lb.submit(a, "best", 30)
		h:tick(70)
		local top = lb.top("best")
		expect(rowsOf(top)).toEqual({ "1:2=50", "2:3=40" })
		expect(top.rows[1].name).toBe("Bea")
		expect(users.lookups()).toBe(1)
		expect(store.entries()["1"]).toBe(30)
		local rank, value = lb.rank(a, "best")
		expect(rank).toBe(nil) -- beyond topN: no rank, the value is still known
		expect(value).toBe(30)
		local replicated = boardOf(h, a, "best")
		expect(#replicated.rows).toBe(2)
		expect(replicated.title).toBe("Leaderboards.board.best")
		expect(mineOf(h, a, "best").value).toBe(30)
	end)

	it("a lower-is-better board (order asc) keeps the smaller value", function()
		local h = boot({ boards = { fastest = { order = "asc" } } })
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		lb.submit(p, "fastest", 90)
		lb.submit(p, "fastest", 120)
		lb.submit(p, "fastest", 75)
		expect((select(2, lb.rank(p, "fastest")))).toBe(75)
		h:tick(70)
		expect(rowsOf(lb.top("fastest"))).toEqual({ "1:1=75" })
	end)
end)

describe("server authority", function()
	it("a client has no action that submits or raises a value", function()
		local h = boot({ boards = { best = {} } })
		local p = h:addPlayer({ userId = 1 })
		local lb = h:use(Leaderboards)
		lb.submit(p, "best", 5)
		for _, name in { "submit", "setValue", "score", "submitScore", "best" } do
			local called, ok = pcall(h.action, h, p, Leaderboards, name, "best", 9999)
			expect(called and ok == true).toBe(false) -- raises "has no action" or is refused
		end
		expect(h.runtime.net.hasAction("Leaderboards", "submit")).toBe(false)
		expect((select(2, lb.rank(p, "best")))).toBe(5)
		-- nor does the replicated state carry anything a client could write back
		expect(Leaderboards.actions).toBe(nil)
	end)
end)

describe("signals", function()
	it("BoardRefreshed is reachable through the public api and fires after a refresh", function()
		local h = boot({ refreshSeconds = 10, writeSeconds = 5, boards = { best = {} } })
		local p = h:addPlayer({ userId = 1, name = "Ann" })
		local lb = h:use(Leaderboards)
		expect(lb.signals.BoardRefreshed ~= nil).toBe(true)
		local refreshed = {}
		lb.signals.BoardRefreshed:Connect(function(boardId: string)
			table.insert(refreshed, boardId)
		end)
		expect(lb.submit(p, "best", 10)).toBe(true)
		h:tick(40)
		expect(table.find(refreshed, "best") ~= nil).toBe(true)
	end)
end)
