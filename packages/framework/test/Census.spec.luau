--!nocheck
--[[
	ctx.data.census (module-api.md §23.5): every server reports { servers = 1, players = n } to a
	time bucket of `SW/_/census` every censusSeconds and reads the last complete bucket; the
	day's peak is kept 9 days (peakPlayers = the highest of the last 8); module memory usage
	rides along so every server learns the experience totals; the cost is the framework's.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local Server = script.Parent.Parent.server
local Census = (require :: any)(Server.Census)
local PlatformStores = (require :: any)(Server.PlatformStores)
local StoreBudget = (require :: any)(Server.StoreBudget)

local function probe()
	local captured = {}
	local ref = StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" })
	return ref, {
		init = function(ctx)
			captured.ctx = ctx
		end,
	}, captured
end

local function boot(opts)
	local ref, part, captured = probe()
	local o = { modules = { ref }, servers = { Probe = part } }
	for k, v in opts or {} do
		o[k] = v
	end
	local h = StudWork.test.harness(o)
	return h, captured.ctx
end

-- a census on a shared in-memory map, its own budget, a shared clock
local function node(world, players)
	local n = { players = players or 0 }
	n.budget = StoreBudget.new({
		now = world.clock,
		players = function()
			return n.players
		end,
	})
	n.census = Census.new({
		map = world.map,
		budget = n.budget,
		players = function()
			return n.players
		end,
		now = world.clock,
	})
	return n
end

local function world()
	local w = { t = 86400 * 20000 }
	function w.clock()
		return w.t
	end
	w.map = PlatformStores.memorySortedMap({ clock = w.clock })
	return w
end

describe("ctx.data.census through the harness", function()
	it("is nil until the first complete bucket, then counts this server and its players", function()
		local h, ctx = boot()
		expect(ctx.data.census()).toBe(nil)
		h:addPlayer({ userId = 1 })
		h:addPlayer({ userId = 2 })
		h:tick(60)
		local c = ctx.data.census()
		expect(c.servers).toBe(1)
		expect(c.players).toBe(0) -- the bucket reported at boot, before anyone joined
		h:tick(60)
		c = ctx.data.census()
		expect(c.players).toBe(2)
		expect(c.peakPlayers).toBe(2)
		expect(c.at).toBe(h.clock)
	end)

	it("several servers on one store count each other", function()
		local store = StudWork.test.memoryStore()
		local h1, c1 = boot({ store = store })
		local h2 = boot({ store = store })
		local h3 = boot({ store = store })
		h2:addPlayer({ userId = 2 })
		h3:addPlayer({ userId = 3 })
		h3:addPlayer({ userId = 4 })
		for _ = 1, 2 do
			h1:tick(60)
			h2:tick(60)
			h3:tick(60)
		end
		local c = c1.data.census()
		expect(c.servers).toBe(3)
		expect(c.players).toBe(3)
	end)

	it(
		"runs every storeBudgets.censusSeconds, costs the framework (not the module) 3 units a cycle",
		function()
			local h, ctx = boot({ storeBudgets = { censusSeconds = 120 } })
			local budget = h.runtime.storeBudget
			h:tick(60)
			expect(ctx.data.census()).toBe(nil)
			local before = #h.stores.sortedMap(Census.MAP).calls
			h:tick(60)
			expect(ctx.data.census().servers).toBe(1)
			local calls = h.stores.sortedMap(Census.MAP).calls
			expect(#calls - before).toBe(2) -- one update, one get
			expect(budget.unitsUsed()).toBe(0)
			expect(budget.frameworkUnitsUsed()).toBe(3)
		end
	)

	it("a fixed reading (harness census = {...}) never touches the census map", function()
		local h, ctx = boot({ census = { servers = 9, players = 40 } })
		h:tick(120)
		expect(ctx.data.census().servers).toBe(9)
		expect(h.stores.sortedMapNames()).toEqual({})
	end)

	it("a failing census map logs once a minute, never raises, and keeps the last reading", function()
		local h, ctx = boot()
		h:tick(60)
		expect(ctx.data.census().servers).toBe(1)
		h.stores.sortedMap(Census.MAP).failNext(100, "InternalError")
		h:tick(120)
		expect(ctx.data.census().servers).toBe(1)
		local n = 0
		for _, entry in h.logs do
			if string.find(entry.msg, "census", 1, true) then
				n += 1
			end
		end
		expect(n).toBe(2)
	end)
end)

describe("census: peaks and memory usage", function()
	it("keeps the day's peak 9 days; peakPlayers is the highest of the last 8", function()
		local w = world()
		local a = node(w, 50)
		a.census.cycle()
		w.t += 60
		a.census.cycle()
		expect(a.census.get().peakPlayers).toBe(50)
		a.players = 5
		for day = 1, 9 do
			w.t += 86400
			a.census.cycle()
			w.t += 60
			a.census.cycle()
			local expected = if day <= 7 then 50 else 5
			assert(a.census.get().peakPlayers == expected, "day " .. day)
		end
	end)

	it("a new server learns the peak from the bucket it reads", function()
		local w = world()
		local a = node(w, 30)
		a.census.cycle()
		w.t += 60
		a.census.cycle()
		a.players = 1
		w.t += 86400
		a.census.cycle()
		local b = node(w, 1)
		w.t += 60
		a.census.cycle()
		b.census.cycle()
		expect(b.census.get().servers).toBe(1)
		expect(b.census.get().peakPlayers).toBe(30)
	end)

	it(
		"every server learns each module's memory usage: from the usage items, then from the buckets",
		function()
			local w = world()
			local a = node(w)
			local b = node(w)
			a.census.cycle()
			b.census.cycle()
			local expires = w.t + 3600
			assert(a.budget.chargeMemory("Board", 4000, expires))
			w.t += 60
			a.census.cycle() -- reports Board's 4000 bytes to u/Board and the bucket
			expect(w.map.get("u/Board").h[StoreBudget.hourKey(expires)]).toBe(4000)
			b.census.cycle() -- reads the bucket before the one a just reported to: nothing yet
			w.t += 60
			b.census.cycle()
			expect(b.budget.moduleBytes("Board")).toBe(4000)
			-- a server started later reads the usage items on its first cycle
			local c = node(w)
			c.census.cycle()
			expect(c.budget.moduleBytes("Board")).toBe(4000)
			-- b now refuses what would pass Board's share of the experience quota
			local share = 0.25 * b.budget.quota()
			expect(b.budget.chargeMemory("Board", share - 4000 + 1, expires)).toBe(false)
			expect(b.budget.chargeMemory("Board", share - 4000 - 1, expires)).toBe(true)
		end
	)

	it("a removed item's charge is taken off the experience total; expired hours drop out", function()
		local w = world()
		local a = node(w)
		a.census.cycle()
		local soon = w.t + 60
		assert(a.budget.chargeMemory("M", 500, soon))
		assert(a.budget.chargeMemory("M", 300, w.t + 7200))
		w.t += 60
		a.census.cycle()
		a.budget.releaseMemory("M", 500, soon)
		w.t += 60
		a.census.cycle()
		expect(a.budget.moduleBytes("M")).toBe(300)
		w.t += 3 * 3600
		a.census.cycle()
		expect(a.budget.moduleBytes("M")).toBe(0)
	end)

	it("a failed usage report keeps the charges for the next cycle", function()
		local w = world()
		local failing = true
		local map = setmetatable({
			update = function(key, fn, expiry)
				if failing and string.sub(key, 1, 2) == "u/" then
					error("InternalError", 0)
				end
				return w.map.update(key, fn, expiry)
			end,
		}, { __index = w.map })
		local b = StoreBudget.new({ now = w.clock })
		local c = Census.new({ map = map, budget = b, now = w.clock })
		c.cycle()
		b.chargeMemory("M", 100, w.t + 3600)
		w.t += 60
		c.cycle()
		expect(w.map.get("u/M")).toBe(nil)
		expect(b.moduleBytes("M")).toBe(100)
		failing = false
		w.t += 60
		c.cycle()
		expect(w.map.get("u/M").h[StoreBudget.hourKey(w.t - 120 + 3600)]).toBe(100)
	end)
end)

describe("census bucket shards (M5: no single bucket key every server updates)", function()
	it("shardsFor: one shard up to SHARD_SERVERS servers, then one per SHARD_SERVERS, capped", function()
		expect(Census.shardsFor(nil)).toBe(1)
		expect(Census.shardsFor(Census.SHARD_SERVERS)).toBe(1)
		expect(Census.shardsFor(Census.SHARD_SERVERS + 1)).toBe(2)
		expect(Census.shardsFor(Census.SHARD_SERVERS * 3)).toBe(3)
		expect(Census.shardsFor(10 ^ 7)).toBe(Census.MAX_SHARDS)
	end)

	it("many servers spread over the shard maps and still count every server and player", function()
		local w = world()
		local maps = {}
		local function factory(name)
			name = name or Census.MAP
			if maps[name] == nil then
				maps[name] = if name == Census.MAP
					then w.map
					else PlatformStores.memorySortedMap({ clock = w.clock })
			end
			return maps[name]
		end
		local n = 1200
		local nodes = {}
		for i = 1, n do
			nodes[i] = Census.new({
				map = factory,
				players = function()
					return 2
				end,
				now = w.clock,
				shardDraw = (i - 0.5) / n,
			})
		end
		local function round()
			for _, c in nodes do
				c.cycle()
			end
			w.t += 60
		end
		round() -- bucket 0: nobody has a reading yet, one key
		round() -- bucket 1: still one key; everyone reads bucket 0 (1,200 servers)
		round() -- bucket 2: 3 shards, each in its own map
		round() -- bucket 3: reads the 3 shards of bucket 2
		local bucket = math.floor((w.t - 120) / 60) -- bucket 2
		local most = 0
		for k = 0, 2 do
			local m = if k == 0 then w.map else maps[`{Census.MAP}/{k}`]
			expect(m).never.toBe(nil)
			local key = if k == 0 then `b/60/{bucket}` else `b/60/{bucket}/{k}`
			local v = m.get(key)
			expect(v).never.toBe(nil)
			most = math.max(most, v.s)
		end
		expect(most <= Census.SHARD_SERVERS).toBe(true) -- no key took every server's update
		local reading = nodes[1].get()
		expect(reading.servers).toBe(n)
		expect(reading.players).toBe(2 * n)
	end)

	it("a fixed backend (no factory) keeps every shard in one map, under its own key", function()
		local w = world()
		local nodes = {}
		for i = 1, 1000 + 1 do
			nodes[i] = Census.new({ map = w.map, now = w.clock, shardDraw = (i - 0.5) / 1001 })
		end
		for _ = 1, 4 do
			for _, c in nodes do
				c.cycle()
			end
			w.t += 60
		end
		local bucket = math.floor((w.t - 120) / 60)
		expect(w.map.get(`b/60/{bucket}/1`)).never.toBe(nil)
		expect(nodes[1].get().servers).toBe(1001)
	end)

	it("a failed shard read keeps the last reading (no partial, undercounted sum)", function()
		local w = world()
		local broken = false
		local map = setmetatable({
			get = function(key)
				if broken and string.find(key, "/1$") then
					error("InternalError", 0)
				end
				return w.map.get(key)
			end,
		}, { __index = w.map })
		local nodes = {}
		for i = 1, 600 do
			nodes[i] = Census.new({ map = map, now = w.clock, shardDraw = (i - 0.5) / 600 })
		end
		for _ = 1, 3 do
			for _, c in nodes do
				c.cycle()
			end
			w.t += 60
		end
		expect(nodes[1].get().servers).toBe(600)
		broken = true
		for _, c in nodes do
			c.cycle()
		end
		expect(nodes[1].get().servers).toBe(600) -- unchanged, not the shard-0 half
	end)
end)
