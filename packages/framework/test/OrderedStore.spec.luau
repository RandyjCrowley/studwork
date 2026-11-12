--!nocheck
--[[
	ctx.data.ordered (module-api.md §23.3): store names, caller errors, retries with backoff,
	`increment` never retried, the module-wide experience back-off, the per-type request budget
	(storeBudgets.orderedReserve, §23.5), the live adapter and its Studio fallback.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local Server = script.Parent.Parent.server
local OrderedStore = (require :: any)(Server.OrderedStore)
local PlatformStores = (require :: any)(Server.PlatformStores)
local StoreBudget = (require :: any)(Server.StoreBudget)
local OrderedFake = (require :: any)(script.Parent.Fakes.OrderedStore)

local THROTTLE_429 = "502: API Services rejected request with error. HTTP 429 (Too Many Requests)"

local function probe(name)
	local captured = {}
	local ref = StudWork.defineModule({ name = name, version = "1.0.0", framework = "^1.7.0" })
	return ref, {
		init = function(ctx)
			captured.ctx = ctx
		end,
	}, captured
end

-- two probe modules, A and B; returns h, ctxA, ctxB
local function boot(opts)
	local refA, partA, a = probe("ProbeA")
	local refB, partB, b = probe("ProbeB")
	local o = { modules = { refA, refB }, servers = { ProbeA = partA, ProbeB = partB } }
	for k, v in opts or {} do
		o[k] = v
	end
	local h = StudWork.test.harness(o)
	return h, a.ctx, b.ctx
end

local function warnings(h, needle)
	local n = 0
	for _, entry in h.logs do
		if string.find(entry.msg, needle, 1, true) then
			n += 1
		end
	end
	return n
end

-- a layer over one fake, with a recorded wait and a settable clock
local function layer(opts)
	local o = opts or {}
	local t = { now = 1000, waits = {}, logs = {} }
	local fake = OrderedFake.new({ name = "SW/M/b" })
	local budget = o.budget
	local store = OrderedStore.new({
		backend = o.backend or function()
			return fake
		end,
		budget = budget,
		now = function()
			return t.now
		end,
		wait = function(s)
			table.insert(t.waits, s)
			t.now += s
		end,
		log = function(m)
			table.insert(t.logs, m)
		end,
	})
	t.store = store
	t.fake = fake
	t.open = store.forModule("M")
	return t
end

describe("ctx.data.ordered: names and caller errors", function()
	it("opens SW/<Module>/<name>, with the _Studio suffix in Studio", function()
		local h, a = boot()
		a.data.ordered("wins").set("1", 3)
		expect(h:orderedStore("ProbeA", "wins").entries()).toEqual({ ["1"] = 3 })
		local hs, as = boot({ isStudio = true })
		as.data.ordered("wins").set("1", 4)
		expect(hs.stores.orderedNames()).toEqual({ "SW/ProbeA/wins_Studio" })
	end)

	it("raises for a long name or key, a non-integer value, a bad count or order", function()
		local _, a = boot()
		expect(pcall(a.data.ordered, string.rep("n", 45))).toBe(false)
		local board = a.data.ordered("b")
		expect(pcall(board.get, string.rep("k", 51))).toBe(false)
		expect(pcall(board.set, "k", 1.5)).toBe(false)
		expect(pcall(board.set, "k", math.huge)).toBe(false)
		expect(pcall(board.increment, "k", 0 / 0)).toBe(false)
		expect(pcall(board.top, 101, "desc")).toBe(false)
		expect(pcall(board.top, 10, "up")).toBe(false)
	end)

	it(
		"an update fn returning a non-integer, or raising, is an error in the caller; nothing is written",
		function()
			local h, a = boot()
			local board = a.data.ordered("b")
			board.set("k", 1)
			local ok, err = pcall(board.update, "k", function()
				return 2.5
			end)
			expect(ok).toBe(false)
			expect(string.find(tostring(err), "finite integer", 1, true) ~= nil).toBe(true)
			expect(pcall(board.update, "k", function()
				error("boom")
			end)).toBe(false)
			expect(h:orderedStore("ProbeA", "b").entries()).toEqual({ k = 1 })
		end
	)

	it("update returns the new value, or the current one when fn cancels", function()
		local _, a = boot()
		local board = a.data.ordered("b")
		board.set("k", 5)
		local ok, v = board.update("k", function(old)
			return math.max(old or 0, 3)
		end)
		expect(ok).toBe(true)
		expect(v).toBe(5)
		local _, v2 = board.update("k", function()
			return nil
		end)
		expect(v2).toBe(5)
	end)

	it("top honours count, order, min and max, ties by key", function()
		local h, a = boot()
		h:orderedStore("ProbeA", "b").seed({ a = 5, b = 5, c = 9, d = 1 })
		local board = a.data.ordered("b")
		local _, rows = board.top(3, "desc")
		expect(rows).toEqual({ { key = "c", value = 9 }, { key = "a", value = 5 }, { key = "b", value = 5 } })
		local _, mid = board.top(10, "asc", 2, 8)
		expect(mid).toEqual({ { key = "a", value = 5 }, { key = "b", value = 5 } })
	end)
end)

describe("ctx.data.ordered: retries, increment, warnings", function()
	it("retries a failed call twice, after 1 s then 2 s, then succeeds", function()
		local t = layer()
		local board = t.open("b")
		t.fake.failNext(2)
		expect(board.set("k", 7)).toBe(true)
		expect(t.waits).toEqual({ 1, 2 })
		expect(t.fake.entries()).toEqual({ k = 7 })
	end)

	it('gives up after three tries with (false, "failed") and one warning per store per minute', function()
		local t = layer()
		local board = t.open("b")
		t.fake.failNext(6)
		local ok, reason = board.get("k")
		expect(ok).toBe(false)
		expect(reason).toBe("failed")
		expect(board.get("k")).toBe(false)
		expect(#t.logs).toBe(1)
		t.now += 60
		t.fake.failNext(3)
		board.get("k")
		expect(#t.logs).toBe(2)
	end)

	it('never retries increment: one call, (false, "failed")', function()
		local t = layer()
		local board = t.open("b")
		t.fake.failNext(1)
		local ok, reason = board.increment("k", 1)
		expect(ok).toBe(false)
		expect(reason).toBe("failed")
		expect(#t.fake.calls).toBe(1)
		expect(t.waits).toEqual({})
		local ok2, value = board.increment("k", 2)
		expect(ok2).toBe(true)
		expect(value).toBe(2)
	end)

	it("never raises for a platform failure, through the harness", function()
		local h, a = boot()
		h:orderedStore("ProbeA", "b").failNext(3, "boom")
		local ok, reason = a.data.ordered("b").top(5, "desc")
		expect(ok).toBe(false)
		expect(reason).toBe("failed")
		expect(warnings(h, "SW/ProbeA/b")).toBe(1)
	end)
end)

describe("ctx.data.ordered: experience-level throttle", function()
	it("backs off every ordered store of the module (30 s), not other modules", function()
		local t = layer()
		local wins, coins = t.open("wins"), t.open("coins")
		local other = t.store.forModule("Other")("wins")
		t.fake.failNext(1, THROTTLE_429)
		local ok, reason = wins.set("k", 1)
		expect(ok).toBe(false)
		expect(reason).toBe("budget")
		expect(t.waits).toEqual({}) -- not retried
		local calls = #t.fake.calls
		expect(select(2, coins.get("k"))).toBe("budget")
		expect(#t.fake.calls).toBe(calls) -- Roblox not called
		expect(t.store.backoffSeconds("M")).toBe(30)
		expect(other.set("k", 2)).toBe(true) -- another module is unaffected
		t.now += 30
		expect(coins.set("k", 3)).toBe(true)
	end)

	it("doubles while throttles keep coming, up to 5 minutes, and resets after a success", function()
		local t = layer()
		local board = t.open("b")
		local seen = {}
		for _ = 1, 6 do
			t.fake.failNext(1, THROTTLE_429)
			board.get("k")
			table.insert(seen, t.store.backoffSeconds("M"))
			t.now += t.store.backoffSeconds("M")
		end
		expect(seen).toEqual({ 30, 60, 120, 240, 300, 300 })
		expect(board.get("k")).toBe(true)
		t.fake.failNext(1, THROTTLE_429)
		board.get("k")
		expect(t.store.backoffSeconds("M")).toBe(30)
	end)

	it("knows the throttle text", function()
		expect(OrderedStore.isExperienceThrottle(THROTTLE_429)).toBe(true)
		expect(OrderedStore.isExperienceThrottle("301: GetAsync request dropped. Request was throttled")).toBe(
			false
		)
	end)
end)

describe("ctx.data.ordered: the request budget (storeBudgets.orderedReserve)", function()
	it("refuses reads once the minute's read budget is down to the reserve, and recovers", function()
		local h, a = boot()
		local board = a.data.ordered("b")
		-- no players: read limit 60/min, reserve 0.25 -> 45 reads, then "budget"
		for i = 1, 45 do
			assert(board.get("k") == true, "read " .. i)
		end
		local calls = #h:orderedStore("ProbeA", "b").calls
		local ok, reason = board.get("k")
		expect(ok).toBe(false)
		expect(reason).toBe("budget")
		expect(#h:orderedStore("ProbeA", "b").calls).toBe(calls)
		-- the other module shares this server's budget
		expect(select(2, a.data.ordered("c").get("k"))).toBe("budget")
		h:tick(61)
		expect(board.get("k")).toBe(true)
	end)

	it("scales with the players in the server, and an update uses a read and a write", function()
		local h, a = boot()
		local board = a.data.ordered("b")
		-- write limit 30 + 5 x players; reserve 0.25
		for _ = 1, 23 do
			assert(board.update("k", function(old)
				return (old or 0) + 1
			end) == true, "update allowed")
		end
		expect(select(2, board.set("k", 1))).toBe("budget")
		h:addPlayer({ userId = 1 })
		h:addPlayer({ userId = 2 }) -- write limit 40: 30 left > 10
		expect(board.set("k", 1)).toBe(true)
	end)

	it("refuses when the platform's remaining budget is at or below the reserve, without calling", function()
		local remaining = 100
		local fake = OrderedFake.new({ name = "SW/M/b" })
		local backend = setmetatable({
			requestBudget = function()
				return remaining
			end,
		}, { __index = fake })
		local budget = StoreBudget.new({ config = { orderedReserve = 0.5 } })
		local t = layer({
			budget = budget,
			backend = function()
				return backend
			end,
		})
		local board = t.open("b")
		expect(board.get("k")).toBe(true)
		remaining = 30 -- read limit 60 at 0 players: 30 <= 0.5 x 60
		local calls = #fake.calls
		expect(select(2, board.get("k"))).toBe("budget")
		expect(#fake.calls).toBe(calls)
	end)

	it("orderedReserve = 0 allows the whole budget", function()
		local _, a = boot({ storeBudgets = { orderedReserve = 0 } })
		local board = a.data.ordered("b")
		for _ = 1, 5 do
			assert(board.top(1, "desc") == true, "list allowed")
		end
		expect(select(2, board.top(1, "desc"))).toBe("budget") -- list limit 5 at 0 players
	end)
end)

describe("ctx.data.ordered: live adapter", function()
	local function fakeDataStoreService(opts)
		local o = opts or {}
		local stores = {}
		local service = { opened = {} }
		function service.GetOrderedDataStore(_self, name)
			if o.raise then
				error(o.raise, 0)
			end
			table.insert(service.opened, name)
			stores[name] = stores[name] or PlatformStores.memoryOrdered(name)
			return stores[name]
		end
		return service
	end

	it("talks to GetOrderedDataStore(storeName) through the layer", function()
		local svc = fakeDataStoreService()
		local live = PlatformStores.live({ dataStoreService = svc, isStudio = false })
		local open = OrderedStore.new({ backend = live.ordered }).forModule("M")
		local board = open("wins")
		expect(board.set("1", 9)).toBe(true)
		expect(board.set("2", 4)).toBe(true)
		local _, v = board.get("1")
		expect(v).toBe(9)
		local _, inc = board.increment("2", 3)
		expect(inc).toBe(7)
		local _, rows = board.top(2, "desc")
		expect(rows).toEqual({ { key = "1", value = 9 }, { key = "2", value = 7 } })
		expect(board.remove("1")).toBe(true)
		expect(select(2, board.get("1"))).toBe(nil)
		expect(svc.opened).toEqual({ "SW/M/wins" })
	end)

	it("Studio without API access falls back to memory with one warning; live passes the error on", function()
		local logs = {}
		local svc = fakeDataStoreService({ raise = "502: Studio access to APIs is not allowed." })
		local live = PlatformStores.live({
			dataStoreService = svc,
			isStudio = true,
			log = function(m)
				table.insert(logs, m)
			end,
		})
		local a = live.ordered("SW/M/a")
		a.set("k", 2)
		expect(a.get("k")).toBe(2)
		live.ordered("SW/M/b").set("k", 1)
		expect(#logs).toBe(1)
		local notStudio = PlatformStores.live({ dataStoreService = svc, isStudio = false })
		expect(pcall(notStudio.ordered("SW/M/a").get, "k")).toBe(false)
	end)
end)
