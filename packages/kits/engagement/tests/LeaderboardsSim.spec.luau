--!nocheck
--[[
	Leaderboards in the multi-server simulation (StudWork.test.sim): the real server part on several
	sim servers sharing the World's ordered stores and sorted maps, on the World's clock.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local F = StudWork.test.sim

local function boardConfig(extra: any?): any
	local config =
		{ refreshSeconds = 30, writeSeconds = 10, boards = { best = {}, today = { period = "daily" } } }
	for k, v in extra or {} do
		config[k] = v
	end
	return config
end

local function world(config: any, count: number, opts: any?): (any, { any }, { any })
	local w = F.world({
		epoch = 19000 * 86400 + 12 * 3600,
		config = { modules = { "Leaderboards" }, config = { Leaderboards = config } },
	})
	local servers, players = {}, {}
	for i = 1, count do
		local server = F.server(w, {
			services = { UserService = StudWork.test.fakes.userService() },
			census = opts and opts.census,
		})
		servers[i] = server
		local p = server:join(100 + i)
		assert(
			w:advanceUntil(function()
				return server:isLoaded(p)
			end, 30),
			"loaded"
		)
		players[i] = p
	end
	return w, servers, players
end

local function count(calls: { any }, op: string): number
	local n = 0
	for _, call in calls do
		if call.op == op then
			n += 1
		end
	end
	return n
end

describe("Leaderboards on several sim servers", function()
	it(
		"every server sees the merged top, with one store read per refresh for the whole experience",
		function()
			local w, servers, players = world(boardConfig(), 4)
			for i, server in servers do
				local api = server:use("Leaderboards")
				local p = players[i]
				expect(api.submit(p, "best", i * 10)).toBe(true)
				expect(api.submit(p, "today", i * 5)).toBe(true)
			end
			w:advance(300)
			local expected = { "1:104=40", "2:103=30", "3:102=20", "4:101=10" }
			for _, server in servers do
				local top = server:use("Leaderboards").top("best")
				local got = {}
				for _, row in top.rows do
					table.insert(got, `{row.rank}:{row.userId}={row.value}`)
				end
				expect(got).toEqual(expected)
				expect(#server:use("Leaderboards").top("today").rows).toBe(4)
			end
			-- 300 s at refreshSeconds = 30 is about 10 rounds; four servers each listing would be about 40
			local lists = count(w.memoryStores.ordered("SW/Leaderboards/best_Studio").calls, "top")
				+ count(w.memoryStores.ordered("SW/Leaderboards/best").calls, "top")
			expect(lists >= 8).toBe(true)
			expect(lists <= 12).toBe(true)
		end
	)

	it("a stopped elected reader (crash) doesn't stop the board: another server takes over", function()
		local w, servers, players = world(boardConfig(), 3)
		servers[1]:use("Leaderboards").submit(players[1], "best", 7)
		w:advance(60)
		expect(#servers[2]:use("Leaderboards").top("best").rows).toBe(1)
		servers[1]:crash()
		servers[2]:use("Leaderboards").submit(players[2], "best", 9)
		w:advance(200)
		local rows = servers[3]:use("Leaderboards").top("best").rows
		expect(#rows).toBe(2)
		expect(rows[1].userId).toBe(102)
	end)

	it("many servers keep the shared top near topReadsPerMinute (census-paced refresh)", function()
		local SERVERS, TARGET = 20, 10
		local w = world(
			boardConfig({ refreshSeconds = 30, topReadsPerMinute = TARGET, boards = { best = {} } }),
			SERVERS,
			{ census = { servers = SERVERS, players = SERVERS } }
		)
		local top = w.memoryStores.sortedMap("SW/Leaderboards/top/best")
		local before = count(top.calls, "get")
		w:advance(600) -- ten minutes
		local perMinute = (count(top.calls, "get") - before) / 10
		-- 60 x 20 servers / 10 reads a minute = a 120 s interval: 20 servers read 10 times a minute;
		-- unpaced (30 s) it would be 40 a minute
		expect(perMinute >= TARGET * 0.5).toBe(true)
		expect(perMinute <= TARGET * 1.3).toBe(true)
	end)

	it("two servers writing one user's best leave the larger value", function()
		local w, servers, players = world(boardConfig(), 2)
		-- the same user id on both servers is impossible in the sim (one session lock), so two
		-- users race on the same board and the store keeps each one's best
		local api1, api2 = servers[1]:use("Leaderboards"), servers[2]:use("Leaderboards")
		api1.submit(players[1], "best", 10)
		api2.submit(players[2], "best", 20)
		api1.submit(players[1], "best", 4)
		w:advance(60)
		local rows = api2.top("best").rows
		expect(rows[1].value).toBe(20)
		expect(rows[2].value).toBe(10)
	end)
end)
