--!nocheck
-- v1.6.1 (adopting.md §4.2, §4.3; final review M1, L3): an onLegacyProduct handler that declared
-- writesLegacyData = false and writes an old store anyway fails loudly (tests: the legacy store
-- mock reports the write; Studio: the import's keys are read before/after and compared), and the
-- late-receipt window after legacyReceipts' `until` is configurable (checkDays, default 90).
local StudWork = require(script.Parent.Parent.shared)
local Harness = require(script.Parent.harness)
local Shop = require(script.Parent.Parent.server.Shop)
local Legacy = require(script.Parent.Parent.server.Legacy)

local Store = StudWork.defineModule({
	name = "Store",
	version = "1.0.0",
	framework = "^1.3.0",
	data = { key = "store", version = 1, default = { coins = 0 } },
})

local PRODUCTS = { passes = {}, devProducts = { Coins = 101, OldPack = 202 } }
local HISTORY = "PurchaseHistory"
local OLD = { kind = "datastore", name = "OldData", key = "Player_{userId}" }

-- o.writes (declared flag), o.handler(world, receiptInfo, player) -> answer, o.import (bool),
-- o.studio (Studio mode: a backend WITHOUT write reporting, like the real DataStoreService),
-- o.legacyReceipts (spec or false), o.startTime, o.history
local function setup(o)
	o = o or {}
	local world = { oldRuns = 0, grants = 0 }
	local legacy = Harness.legacyStore({
		datastore = { [HISTORY] = o.history or {}, OldData = { Player_1 = { coins = 5 } } },
	})
	world.legacy = legacy
	world.oldStores = legacy.dataStoreService() -- what the old game code calls
	local backend = legacy
	if o.studio then
		backend = {
			get = function(...)
				return legacy.get(...)
			end,
			latestOrdered = function(...)
				return legacy.latestOrdered(...)
			end,
		}
	end
	local h, err = Harness.boot({
		modules = { Store },
		products = PRODUCTS,
		legacy = backend,
		isStudio = o.studio == true,
		startTime = o.startTime,
		servers = {
			Store = {
				init = function(ctx)
					world.ctx = ctx
					if o.import then
						ctx.data.importLegacy({
							id = "v1-save",
							version = 1,
							source = OLD,
							import = function(tx, old)
								ctx.section(tx).coins = old.coins
							end,
						})
					end
					if o.legacyReceipts ~= false then
						ctx.shop.legacyReceipts(
							o.legacyReceipts or { name = HISTORY, key = "{userId}_{purchaseId}" }
						)
					end
					ctx.shop.onProduct("Coins", function(tx)
						world.grants += 1
						ctx.section(tx).coins += 10
					end)
					ctx.shop.onLegacyProduct("OldPack", function(receiptInfo, player)
						world.oldRuns += 1
						if o.handler then
							return o.handler(world, receiptInfo, player)
						end
						return "PurchaseGranted"
					end, { writesLegacyData = o.writes == true })
				end,
			},
		},
	})
	assert(h, err)
	world.h = h
	return world
end

local function receipt(pid, product)
	return {
		PlayerId = 1,
		PurchaseId = pid,
		ProductId = product or 202,
		CurrencySpent = 5,
		PlaceIdWherePurchased = 1,
	}
end

local function loud(w)
	for _, l in w.h.logs do
		if string.find(l.msg, "UNDECLARED LEGACY WRITE", 1, true) then
			return l.msg
		end
	end
	return nil
end

local function recorded(w, p, pid)
	local saved = w.h:saved(p)
	local fw = saved and saved._framework
	return fw ~= nil and fw.purchases ~= nil and fw.purchases[pid] ~= nil
end

describe("LegacyBridgeWrites: undeclared old-store writes fail loudly (tests)", function()
	it(
		"writesLegacyData = false + SetAsync on the old save -> NotProcessedYet, not recorded, error names product/module/store/key",
		function()
			local w = setup({
				handler = function(world)
					world.oldStores:GetDataStore("OldData"):SetAsync("Player_1", { coins = 99 })
					return "PurchaseGranted"
				end,
			})
			local p = w.h:addPlayer({ userId = 1 })
			expect(w.h:receipt(receipt("u-1"))).toBe("NotProcessedYet")
			expect(w.oldRuns).toBe(1)
			expect(recorded(w, p, "u-1")).toBe(false)
			local msg = loud(w)
			expect(msg).never.toBeNil()
			expect(string.find(msg, "OldPack", 1, true)).never.toBeNil()
			expect(string.find(msg, "(Store)", 1, true)).never.toBeNil()
			expect(string.find(msg, "store OldData key Player_1", 1, true)).never.toBeNil()
			expect(string.find(msg, "writesLegacyData = true", 1, true)).never.toBeNil()
		end
	)

	it(
		"every write kind is caught: UpdateAsync, IncrementAsync, RemoveAsync, ordered, set (ProfileService/DataStore2 style)",
		function()
			local writes = {
				function(s)
					s:GetDataStore("OldData"):UpdateAsync("Player_1", function(v)
						v.coins += 1
						return v
					end)
				end,
				function(s)
					s:GetDataStore("Stats", "v2"):IncrementAsync("Visits_1", 1)
				end,
				function(s)
					s:GetDataStore("OldData"):RemoveAsync("Player_1")
				end,
				function(s)
					s:GetOrderedDataStore("coins/1"):SetAsync("7", 7) -- DataStore2 ordered backups
				end,
				function(s)
					s:GetOrderedDataStore("Leaderboard"):IncrementAsync("1", 3)
				end,
				function(_s, world)
					world.legacy.set("Profiles", "Player_1", { Data = {} }) -- a library writing the mock
				end,
			}
			for i, write in writes do
				local w = setup({
					handler = function(world)
						write(world.oldStores, world)
						return "PurchaseGranted"
					end,
				})
				local p = w.h:addPlayer({ userId = 1 })
				expect(w.h:receipt(receipt("k-" .. i))).toBe("NotProcessedYet")
				expect(recorded(w, p, "k-" .. i)).toBe(false)
				expect(loud(w)).never.toBeNil()
			end
		end
	)

	it("a write from a task the handler spawned (before it returns) is caught too", function()
		local w = setup({
			handler = function(world)
				task.spawn(function()
					world.oldStores:GetDataStore("OldData"):SetAsync("Player_1", { coins = 1 })
				end)
				return "PurchaseGranted"
			end,
		})
		local p = w.h:addPlayer({ userId = 1 })
		expect(w.h:receipt(receipt("s-1"))).toBe("NotProcessedYet")
		expect(recorded(w, p, "s-1")).toBe(false)
		expect(loud(w)).never.toBeNil()
	end)

	it("the failure repeats on redelivery (never granted while the write is there)", function()
		local w = setup({
			handler = function(world)
				world.oldStores:GetDataStore("OldData"):SetAsync("Player_1", { coins = 99 })
				return "PurchaseGranted"
			end,
		})
		local p = w.h:addPlayer({ userId = 1 })
		expect(w.h:receipt(receipt("r-1"))).toBe("NotProcessedYet")
		expect(w.h:receipt(receipt("r-1"))).toBe("NotProcessedYet")
		expect(recorded(w, p, "r-1")).toBe(false)
	end)

	it("writesLegacyData = true that writes (no importLegacy) -> granted as before", function()
		local w = setup({
			writes = true,
			handler = function(world)
				world.oldStores:GetDataStore("OldData"):SetAsync("Player_1", { coins = 99 })
				return "PurchaseGranted"
			end,
		})
		local p = w.h:addPlayer({ userId = 1 })
		expect(w.h:receipt(receipt("t-1"))).toBe("PurchaseGranted")
		expect(recorded(w, p, "t-1")).toBe(true)
		expect(loud(w)).toBeNil()
	end)

	it("a writesLegacyData = false handler that only reads -> granted", function()
		local w = setup({
			import = true,
			handler = function(world)
				local v = world.oldStores:GetDataStore("OldData"):GetAsync("Player_1")
				assert(v.coins == 5, "old save readable")
				return "PurchaseGranted"
			end,
		})
		local p = w.h:addPlayer({ userId = 1 })
		expect(w.h:receipt(receipt("o-1"))).toBe("PurchaseGranted")
		expect(recorded(w, p, "o-1")).toBe(true)
		expect(loud(w)).toBeNil()
	end)

	it("writing the registered legacyReceipts history store is not the old save -> granted", function()
		local w = setup({
			handler = function(world, receiptInfo)
				world.oldStores:GetDataStore(HISTORY):SetAsync(`1_{receiptInfo.PurchaseId}`, true)
				return "PurchaseGranted"
			end,
		})
		local p = w.h:addPlayer({ userId = 1 })
		expect(w.h:receipt(receipt("h-1"))).toBe("PurchaseGranted")
		expect(recorded(w, p, "h-1")).toBe(true)
	end)

	it("onProduct receipts are untouched by the check", function()
		local w = setup()
		local p = w.h:addPlayer({ userId = 1 })
		expect(w.h:receipt(receipt("c-1", 101))).toBe("PurchaseGranted")
		expect(w.grants).toBe(1)
		expect(recorded(w, p, "c-1")).toBe(true)
	end)
end)

describe("LegacyBridgeWrites: Studio mode (before/after key comparison)", function()
	it("an import key changed between the two reads -> NotProcessedYet, not recorded, loud error", function()
		local w = setup({
			studio = true,
			import = true,
			handler = function(world)
				world.oldStores:GetDataStore("OldData"):SetAsync("Player_1", { coins = 99 })
				return "PurchaseGranted"
			end,
		})
		local p = w.h:addPlayer({ userId = 1 })
		expect(w.ctx.data.get(p).coins).toBe(5) -- imported at join
		expect(w.h:receipt(receipt("st-1"))).toBe("NotProcessedYet")
		expect(recorded(w, p, "st-1")).toBe(false)
		local msg = loud(w)
		expect(msg).never.toBeNil()
		expect(string.find(msg, "OldData Player_1", 1, true)).never.toBeNil()
		expect(string.find(msg, "OldPack", 1, true)).never.toBeNil()
	end)

	it("a key read error -> NotProcessedYet (fail closed); the retry with readable keys grants", function()
		local w = setup({ studio = true, import = true, legacyReceipts = false })
		local p = w.h:addPlayer({ userId = 1 })
		w.legacy.failNext(1)
		expect(w.h:receipt(receipt("st-2"))).toBe("NotProcessedYet")
		expect(w.oldRuns).toBe(0) -- the before-read failed: the old handler never ran
		expect(recorded(w, p, "st-2")).toBe(false)
		expect(w.h:receipt(receipt("st-2"))).toBe("PurchaseGranted")
		expect(w.oldRuns).toBe(1)
		expect(recorded(w, p, "st-2")).toBe(true)
	end)

	it("an unchanged key (the handler only reads) -> granted", function()
		local w = setup({ studio = true, import = true })
		local p = w.h:addPlayer({ userId = 1 })
		expect(w.h:receipt(receipt("st-3"))).toBe("PurchaseGranted")
		expect(recorded(w, p, "st-3")).toBe(true)
	end)

	it("the comparison READS only (no write reaches the old store from StudWork)", function()
		local w = setup({ studio = true, import = true })
		w.h:addPlayer({ userId = 1 })
		local writes = 0
		w.legacy.watchWrites(function()
			writes += 1
		end)
		expect(w.h:receipt(receipt("st-4"))).toBe("PurchaseGranted")
		expect(writes).toBe(0)
	end)

	it("Legacy.sameStamp spots a changed value, a changed time and a missing key", function()
		local a = { { store = "S", key = "k", updatedAt = 1, value = { x = 1 } } }
		expect((Legacy.sameStamp(a, { { store = "S", key = "k", updatedAt = 1, value = { x = 1 } } }))).toBe(
			true
		)
		expect((Legacy.sameStamp(a, { { store = "S", key = "k", updatedAt = 1, value = { x = 2 } } }))).toBe(
			false
		)
		expect((Legacy.sameStamp(a, { { store = "S", key = "k", updatedAt = 2, value = { x = 1 } } }))).toBe(
			false
		)
		local same, where = Legacy.sameStamp(a, {})
		expect(same).toBe(false)
		expect(where).toBe("S k")
	end)
end)

describe("LegacyBridgeWrites: the late-receipt window (legacyReceipts.checkDays)", function()
	local START = 1_800_000_000

	it("default stays 90 days (Legacy.RECEIPT_KEEP_DAYS)", function()
		expect(Legacy.RECEIPT_KEEP_DAYS).toBe(90)
		local w = setup({
			startTime = START,
			history = { ["1_late-0"] = true },
			legacyReceipts = { name = HISTORY, key = "{userId}_{purchaseId}", ["until"] = START - 89 * 86400 },
		})
		w.h:addPlayer({ userId = 1 })
		expect(w.h:receipt(receipt("late-0", 101))).toBe("PurchaseGranted")
		expect(w.grants).toBe(0) -- day 89: still checked, legacy_duplicate
	end)

	it("inside a custom window -> checked (legacy_duplicate for a found id)", function()
		local w = setup({
			startTime = START,
			history = { ["1_late-1"] = true },
			legacyReceipts = {
				name = HISTORY,
				key = "{userId}_{purchaseId}",
				["until"] = START - 100 * 86400,
				checkDays = 120,
			},
		})
		local p = w.h:addPlayer({ userId = 1 })
		expect(w.h:receipt(receipt("late-1", 101))).toBe("PurchaseGranted")
		expect(w.grants).toBe(0)
		expect(w.h:saved(p)._framework.legacyPurchases["late-1"]).never.toBeNil()
	end)

	it("after a custom window -> skipped (the store isn't read; a found id grants normally)", function()
		local w = setup({
			startTime = START,
			history = { ["1_late-2"] = true },
			legacyReceipts = {
				name = HISTORY,
				key = "{userId}_{purchaseId}",
				["until"] = START - 31 * 86400,
				checkDays = 30,
			},
		})
		w.h:addPlayer({ userId = 1 })
		local reads = w.legacy.reads
		expect(w.h:receipt(receipt("late-2", 101))).toBe("PurchaseGranted")
		expect(w.legacy.reads).toBe(reads)
		expect(w.grants).toBe(1)
	end)

	it('the validator refuses checkDays = 0, -1, "90", NaN, inf and accepts 1 and 0.5', function()
		local base = { name = HISTORY, key = "{userId}_{purchaseId}" }
		for _, bad in { 0, -1, "90", 0 / 0, math.huge } do
			local spec = table.clone(base)
			spec.checkDays = bad
			local err = Shop.validateLegacyReceipts(spec)
			expect(err).never.toBeNil()
			expect(string.find(err, "checkDays", 1, true)).never.toBeNil()
		end
		for _, good in { 1, 0.5, 365 } do
			local spec = table.clone(base)
			spec.checkDays = good
			expect(Shop.validateLegacyReceipts(spec)).toBeNil()
		end
	end)
end)
