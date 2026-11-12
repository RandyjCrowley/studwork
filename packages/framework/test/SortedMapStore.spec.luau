--!nocheck
--[[
	ctx.data.sortedMap (module-api.md §23.4): caller errors, retries and error mapping, this
	server's request-unit cap (storeBudgets.memoryUnits), the memory charges of set / update /
	remove against the module shares (storeBudgets.memory, §23.5), the fake's per-structure /
	per-partition limits and quotaBytes, the live adapter and its Studio fallback.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local Server = script.Parent.Parent.server
local SortedMapStore = (require :: any)(Server.SortedMapStore)
local PlatformStores = (require :: any)(Server.PlatformStores)
local StoreBudget = (require :: any)(Server.StoreBudget)
local SortedMapFake = (require :: any)(script.Parent.Fakes.SortedMap)

local function probe(name)
	local captured = {}
	local ref = StudWork.defineModule({ name = name, version = "1.0.0", framework = "^1.7.0" })
	return ref, {
		init = function(ctx)
			captured.ctx = ctx
		end,
	}, captured
end

-- two probe modules, A and B; the census is fixed so only the modules' own calls count
local function boot(opts)
	local refA, partA, a = probe("ProbeA")
	local refB, partB, b = probe("ProbeB")
	local o = {
		modules = { refA, refB },
		servers = { ProbeA = partA, ProbeB = partB },
		census = { servers = 1, players = 0, peakPlayers = 0 },
	}
	for k, v in opts or {} do
		o[k] = v
	end
	local h = StudWork.test.harness(o)
	return h, a.ctx, b.ctx
end

-- a layer over one fake, with a recorded wait and a settable clock
local function layer(opts)
	local o = opts or {}
	local t = { now = 1000, waits = {}, logs = {} }
	local clock = function()
		return t.now
	end
	t.fake = SortedMapFake.new({ name = "SW/M/m", clock = clock })
	t.budget = o.budget
	t.store = SortedMapStore.new({
		backend = function()
			return t.fake
		end,
		budget = o.budget,
		now = clock,
		wait = function(s)
			table.insert(t.waits, s)
			t.now += s
		end,
		log = function(m)
			table.insert(t.logs, m)
		end,
	})
	t.open = t.store.forModule("M")
	return t
end

describe("ctx.data.sortedMap: caller errors", function()
	it("raises for a value over 32 KB or not JSON-safe, a bad sort key, a NaN expiry", function()
		local _, a = boot()
		local map = a.data.sortedMap("m")
		expect(pcall(map.set, "k", string.rep("x", 33 * 1024), 60)).toBe(false)
		expect(pcall(map.set, "k", { f = function() end }, 60)).toBe(false)
		expect(pcall(map.set, "k", 1, 60, string.rep("s", 129))).toBe(false)
		expect(pcall(map.set, "k", 1, 60, 0 / 0)).toBe(false)
		expect(pcall(map.set, "k", 1, 0 / 0)).toBe(false)
		expect(pcall(map.set, "k", 1, 3888001)).toBe(false)
		expect(pcall(map.range, "asc", 0)).toBe(false)
	end)

	it(
		"an update fn that raises or returns a too-big value is an error in the caller; nothing written",
		function()
			local h, a = boot()
			local map = a.data.sortedMap("m")
			map.set("k", 1, 60)
			expect(pcall(map.update, "k", function()
				error("boom")
			end, 60)).toBe(false)
			expect(pcall(map.update, "k", function()
				return string.rep("x", 33 * 1024)
			end, 60)).toBe(false)
			expect(h:sortedMap("ProbeA", "m").entries()[1].value).toBe(1)
		end
	)

	it("update returning nil cancels the write", function()
		local h, a = boot()
		local map = a.data.sortedMap("m")
		map.set("k", 1, 60, 5)
		local ok, new = map.update("k", function()
			return nil
		end, 60)
		expect(ok).toBe(true)
		expect(new).toBe(nil)
		expect(h:sortedMap("ProbeA", "m").entries()[1].sortKey).toBe(5)
	end)

	it("name may contain a slash", function()
		local h, a = boot()
		a.data.sortedMap("daily/20404/0").set("1", { v = 3 }, 60, 3)
		expect(#h:sortedMap("ProbeA", "daily/20404/0").entries()).toBe(1)
	end)
end)

describe("ctx.data.sortedMap: retries and error mapping", function()
	it("retries a throttle twice (1 s, 2 s) and succeeds", function()
		local t = layer()
		local map = t.open("m")
		t.fake.failNext(2, "PartitionRequestsOverLimit")
		expect(map.set("k", 1, 60)).toBe(true)
		expect(t.waits).toEqual({ 1, 2 })
	end)

	it('gives up with "throttled" or "failed", and one warning per map per minute', function()
		local t = layer()
		local map = t.open("m")
		t.fake.failNext(3, "RequestThrottled")
		expect(select(2, map.get("k"))).toBe("throttled")
		t.fake.failNext(3, "Code: InternalError")
		expect(select(2, map.get("k"))).toBe("failed")
		expect(#t.logs).toBe(1)
		t.now += 60
		t.fake.failNext(3)
		map.get("k")
		expect(#t.logs).toBe(2)
	end)

	it('returns "memory_full" at once for a full quota (not retried)', function()
		for _, code in
			{ "TotalMemoryOverLimit", "DataStructureMemoryOverLimit", "DataStructureItemsOverLimit" }
		do
			local t = layer()
			t.fake.failNext(1, code)
			local ok, reason = t.open("m").set("k", 1, 60)
			expect(ok).toBe(false)
			expect(reason).toBe("memory_full")
			expect(#t.fake.calls).toBe(1)
		end
	end)

	it("never raises for a platform failure, through the harness", function()
		local h, a = boot()
		h:sortedMap("ProbeA", "m").failNext(3, "TotalRequestsOverLimit")
		local ok, reason = a.data.sortedMap("m").range("desc", 10)
		expect(ok).toBe(false)
		expect(reason).toBe("throttled")
	end)
end)

describe("ctx.data.sortedMap: request units (storeBudgets.memoryUnits)", function()
	it("caps this server at base + perPlayer x players units a minute, every module together", function()
		local h, a, b = boot({ storeBudgets = { memoryUnits = { base = 10, perPlayer = 5 } } })
		local map = a.data.sortedMap("m")
		for i = 1, 6 do
			assert(map.get("k") == true, "get " .. i)
		end
		expect(b.data.sortedMap("n").update("k", function()
			return 1
		end, 60)).toBe(true) -- 2 units: 8
		map.get("k")
		map.get("k") -- 10
		local calls = #h:sortedMap("ProbeA", "m").calls
		local ok, reason = map.get("k")
		expect(ok).toBe(false)
		expect(reason).toBe("budget")
		expect(#h:sortedMap("ProbeA", "m").calls).toBe(calls) -- Roblox not called
		h:addPlayer({ userId = 1 }) -- cap 15
		expect(map.get("k")).toBe(true)
		h:tick(61)
		for _ = 1, 15 do
			assert(map.get("k") == true, "get allowed")
		end
		expect(select(2, map.get("k"))).toBe("budget")
	end)

	it("a range costs one unit per row returned plus one", function()
		local _, a = boot({ storeBudgets = { memoryUnits = { base = 20, perPlayer = 0 } } })
		local map = a.data.sortedMap("m")
		for i = 1, 5 do
			map.set(tostring(i), i, 60, i) -- 5 units
		end
		local ok, rows = map.range("asc", 10) -- 1 + 5
		expect(ok).toBe(true)
		expect(#rows).toBe(5)
		for _ = 1, 9 do
			assert(map.get("1") == true, "get allowed") -- 20
		end
		expect(select(2, map.get("1"))).toBe("budget")
	end)
end)

describe("ctx.data.sortedMap: memory shares (storeBudgets.memory)", function()
	-- quota with no players: 64 KB = 65536 bytes; an item of key "kN" (2) + a 300-char string
	-- (302) + 32 = 336 bytes
	local BIG = string.rep("x", 300)

	it(
		"refuses a growing write past the module's share, without calling Roblox; another module still writes",
		function()
			local h, a, b = boot({
				storeBudgets = {
					memoryUnits = { base = 1000, perPlayer = 0 },
					memory = { reserve = 0.2, defaultShare = 0.01, shares = { ProbeB = 0.05 } },
				},
			})
			local map = a.data.sortedMap("m")
			local written = 0
			for i = 1, 10 do
				if map.set("k" .. i, BIG, 600) then
					written += 1
				end
			end
			expect(written).toBe(1) -- 655 bytes share: one 336-byte item
			local calls = #h:sortedMap("ProbeA", "m").calls
			local ok, reason = map.set("k99", BIG, 600)
			expect(ok).toBe(false)
			expect(reason).toBe("memory_budget")
			expect(#h:sortedMap("ProbeA", "m").calls).toBe(calls)
			expect(b.data.sortedMap("n").set("k1", BIG, 600)).toBe(true)
			-- writes that don't grow memory are never refused
			expect(map.get("k1")).toBe(true)
			expect(map.update("k1", function()
				return "small"
			end, 600)).toBe(true)
		end
	)

	it("remove gives back what this server charged; an update charges only the growth", function()
		local _, a = boot({
			storeBudgets = {
				memoryUnits = { base = 1000, perPlayer = 0 },
				memory = { reserve = 0.2, defaultShare = 0.012 }, -- 786 bytes: two items
			},
		})
		local map = a.data.sortedMap("m")
		expect(map.set("k1", BIG, 600)).toBe(true)
		expect(map.set("k2", BIG, 600)).toBe(true)
		expect(select(2, map.set("k3", BIG, 600))).toBe("memory_budget")
		expect(a.data.sortedMap("m").remove("k1")).toBe(true) -- any handle on the map gives it back
		expect(map.set("k3", BIG, 600)).toBe(true)
		-- k2 grows by 200 bytes: over the share -> the update cancels, the item is unchanged
		local ok, reason = map.update("k2", function(old)
			return old .. string.rep("y", 200)
		end, 600)
		expect(ok).toBe(false)
		expect(reason).toBe("memory_budget")
		local _, value = map.get("k2")
		expect(value).toBe(BIG)
		-- shrinking is fine and gives memory back
		expect(map.update("k2", function()
			return "s"
		end, 600)).toBe(true)
		expect(map.update("k3", function(old)
			return old .. string.rep("y", 200)
		end, 600)).toBe(true)
	end)

	it("holds every module together to (1 - reserve) x quota", function()
		local _, a, b = boot({
			storeBudgets = {
				memoryUnits = { base = 1000, perPlayer = 0 },
				memory = { reserve = 0.9, defaultShare = 1 }, -- 6553 bytes for all modules
			},
		})
		local n = 0
		for i = 1, 30 do
			local ctx = if i % 2 == 0 then a else b
			if ctx.data.sortedMap("m").set("k" .. i, BIG, 600) then
				n += 1
			end
		end
		expect(n).toBe(19) -- 19 x 336 = 6384; a 20th would pass 6553
	end)

	it("a failed write gives its charge back", function()
		local h, a = boot({
			storeBudgets = {
				memoryUnits = { base = 1000, perPlayer = 0 },
				memory = { reserve = 0.2, defaultShare = 0.01 }, -- 655 bytes: one item
			},
		})
		local map = a.data.sortedMap("m")
		h:sortedMap("ProbeA", "m").failNext(3, "InternalError")
		expect(select(2, map.set("k1", BIG, 600))).toBe("failed")
		expect(map.set("k1", BIG, 600)).toBe(true)
	end)

	it("charges expire with their items: the hour bucket drops out", function()
		local h, a = boot({
			storeBudgets = {
				memoryUnits = { base = 1000, perPlayer = 0 },
				memory = { reserve = 0.2, defaultShare = 0.01 },
			},
		})
		local map = a.data.sortedMap("m")
		expect(map.set("k1", BIG, 60)).toBe(true)
		expect(select(2, map.set("k2", BIG, 60))).toBe("memory_budget")
		h:tick(2 * 3600)
		expect(map.set("k2", BIG, 60)).toBe(true)
	end)
end)

describe("sorted-map fake: Roblox's limits", function()
	it("per-partition and per-structure limits are shared by every server on one store", function()
		local store = StudWork.test.memoryStore({ sortedMap = { partitionLimit = 4, structureLimit = 6 } })
		local _, a1 = boot({ store = store, storeBudgets = { memoryUnits = { base = 1000, perPlayer = 0 } } })
		local _, a2 = boot({ store = store, storeBudgets = { memoryUnits = { base = 1000, perPlayer = 0 } } })
		expect(a1.data.sortedMap("m").set("a", 1, 60)).toBe(true)
		expect(a2.data.sortedMap("m").set("b", 1, 60)).toBe(true)
		expect(a1.data.sortedMap("m").set("c", 1, 60)).toBe(true)
		expect(a2.data.sortedMap("m").set("d", 1, 60)).toBe(true)
		expect(select(2, a1.data.sortedMap("m").set("e", 1, 60))).toBe("throttled")
		expect(store.stores.sortedMap("SW/ProbeA/m").unitsThisMinute()).toBe(4)
	end)

	it(
		"raises the Roblox codes: DataStructureRequestsOverLimit, PartitionRequestsOverLimit, TotalMemoryOverLimit",
		function()
			local now = 0
			local registry = { quotaBytes = 100 }
			local maps = {}
			function registry.memoryUsed()
				local n = 0
				for _, m in maps do
					n += m.memoryBytes()
				end
				return n
			end
			local function clock()
				return now
			end
			local s = SortedMapFake.new({
				clock = clock,
				structureLimit = 1,
				partitionLimit = 5,
				registry = registry,
			})
			local p = SortedMapFake.new({
				clock = clock,
				structureLimit = 10,
				partitionLimit = 1,
				registry = registry,
			})
			table.insert(maps, s)
			table.insert(maps, p)
			s.set("a", 1, 600)
			expect(select(2, pcall(s.set, "b", 1, 600))).toBe("DataStructureRequestsOverLimit")
			expect(s.unitsThisMinute()).toBe(1) -- a refused call isn't counted
			p.set("a", 1, 600)
			expect(select(2, pcall(p.set, "b", 1, 600))).toBe("PartitionRequestsOverLimit")
			now += 60
			expect(select(2, pcall(p.set, "big", string.rep("x", 60), 60))).toBe("TotalMemoryOverLimit")
			expect(#p.entries()).toBe(1)
		end
	)
end)

describe("ctx.data.sortedMap: live adapter", function()
	local function fakeMemoryStoreService(opts)
		local o = opts or {}
		local service = { opened = {} }
		function service.GetSortedMap(_self, name)
			if o.raise then
				error(o.raise, 0)
			end
			table.insert(service.opened, name)
			local core = PlatformStores.memorySortedMap()
			return {
				GetAsync = function(_m, key)
					return core.get(key)
				end,
				SetAsync = function(_m, key, value, expiry, sortKey)
					core.set(key, value, expiry, sortKey)
					return true
				end,
				UpdateAsync = function(_m, key, fn, expiry)
					return core.update(key, fn, expiry)
				end,
				RemoveAsync = function(_m, key)
					core.remove(key)
				end,
			}
		end
		return service
	end

	it("talks to MemoryStoreService:GetSortedMap(storeName) through the layer", function()
		local svc = fakeMemoryStoreService()
		local live = PlatformStores.live({ memoryStoreService = svc, isStudio = false })
		local map = SortedMapStore.new({ backend = live.sortedMap }).forModule("M")("m")
		expect(map.set("k", { v = 1 }, 60, 1)).toBe(true)
		local ok, value, sortKey = map.get("k")
		expect(ok).toBe(true)
		expect(value.v).toBe(1)
		expect(sortKey).toBe(1)
		local _, new = map.update("k", function(old, oldSortKey)
			return { v = old.v + 1 }, oldSortKey + 1
		end, 60)
		expect(new.v).toBe(2)
		expect(map.remove("k")).toBe(true)
		expect(svc.opened).toEqual({ "SW/M/m" })
	end)

	it("Studio without API access falls back to an in-memory map with one warning", function()
		local logs = {}
		local live = PlatformStores.live({
			memoryStoreService = fakeMemoryStoreService({ raise = "Studio access to APIs is not allowed" }),
			isStudio = true,
			log = function(m)
				table.insert(logs, m)
			end,
		})
		local map = SortedMapStore.new({ backend = live.sortedMap }).forModule("M")("m")
		expect(map.set("k", 1, 60, 1)).toBe(true)
		local _, rows = map.range("asc", 5)
		expect(#rows).toBe(1)
		expect(#logs).toBe(1)
	end)
end)

describe("the in-memory map", function()
	it("orders unsorted items first, then numbers, then strings, with exclusive bounds", function()
		local m = PlatformStores.memorySortedMap()
		m.set("s", 1, 60, "b")
		m.set("n2", 1, 60, 2)
		m.set("u", 1, 60)
		m.set("n1", 1, 60, 1)
		local keys = {}
		for _, row in m.range("asc", 10) do
			table.insert(keys, row.key)
		end
		expect(keys).toEqual({ "u", "n1", "n2", "s" })
		local above = {}
		for _, row in m.range("asc", 10, { sortKey = 1 }) do
			table.insert(above, row.key)
		end
		expect(above).toEqual({ "u", "n2", "s" }) -- a sort-key-only bound skips only numbers <= 1
		local desc = m.range("desc", 2)
		expect(desc[1].key).toBe("s")
		expect(desc[2].key).toBe("n2")
	end)

	it("budget hooks: StoreBudget keeps request accounting separate per server", function()
		local b1 = StoreBudget.new({ config = { memoryUnits = { base = 1, perPlayer = 0 } } })
		local b2 = StoreBudget.new({ config = { memoryUnits = { base = 1, perPlayer = 0 } } })
		expect(b1.chargeUnits("M", 1)).toBe(true)
		expect(b1.chargeUnits("M", 1)).toBe(false)
		expect(b2.chargeUnits("M", 1)).toBe(true)
	end)
end)
