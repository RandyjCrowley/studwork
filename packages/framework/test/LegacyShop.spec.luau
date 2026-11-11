--!nocheck
-- v1.6.0: the purchase bridge (docs/framework/adopting.md §4): exactly one grant across the switch
-- from an old game's receipt code to the framework Shop, end to end through Shop + Data.
local StudWork = require(script.Parent.Parent.shared)
local Harness = require(script.Parent.harness)
local Shop = require(script.Parent.Parent.server.Shop)

local Store = StudWork.defineModule({
	name = "Store",
	version = "1.0.0",
	framework = "^1.3.0",
	data = { key = "store", version = 1, default = { coins = 0 } },
})

local PRODUCTS = { passes = {}, devProducts = { Coins = 101, OldPack = 202, Both = 303 } }
local HISTORY = "PurchaseHistory"

local function setup(o)
	o = o or {}
	local world = { grants = 0, oldRuns = 0, oldAnswer = "PurchaseGranted", ctx = nil }
	local store = Harness.memoryStore()
	local legacy = Harness.legacyStore({ datastore = { [HISTORY] = o.history or {} } })
	local h, err = Harness.boot({
		modules = { Store },
		products = PRODUCTS,
		store = store,
		legacy = legacy,
		startTime = o.startTime,
		servers = {
			Store = {
				init = function(ctx)
					world.ctx = ctx
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
						world.lastOld = { receiptInfo = receiptInfo, player = player }
						if world.oldAnswer == "error" then
							error("old shop crashed")
						end
						return world.oldAnswer
					end, { writesLegacyData = true })
					if o.both then
						ctx.shop.onProduct("Both", function() end)
						ctx.shop.onLegacyProduct("Both", function()
							return "PurchaseGranted"
						end, { writesLegacyData = false })
					end
					if o.init then
						o.init(ctx)
					end
				end,
			},
		},
	})
	world.h, world.err, world.store, world.legacy = h, err, store, legacy
	return world
end

local function receipt(pid, product)
	return {
		PlayerId = 1,
		PurchaseId = pid,
		ProductId = product or 101,
		CurrencySpent = 5,
		PlaceIdWherePurchased = 1,
	}
end

local function coins(w, p)
	return w.ctx.data.get(p).coins
end

describe("LegacyShop: exactly one grant across the switch", function()
	it("(a) a receipt the old game granted (history store) -> 0 grants across 1..N deliveries", function()
		local w = setup({ history = { ["1_old-1"] = true } })
		local p = w.h:addPlayer({ userId = 1 })
		for _ = 1, 4 do
			expect(w.h:receipt(receipt("old-1"))).toBe("PurchaseGranted")
		end
		expect(w.grants).toBe(0)
		expect(coins(w, p)).toBe(0)
		expect(w.h:saved(p)._framework.legacyPurchases["old-1"]).toBe(w.h.clock)
		expect(w.legacy.reads).toBe(1) -- the record answers every redelivery after the first
		-- a fresh server (rejoin): still recorded through the save
		w.h:rejoin(p)
		expect(w.h:receipt(receipt("old-1"))).toBe("PurchaseGranted")
		expect(w.grants).toBe(0)
		expect(w.legacy.reads).toBe(1)
	end)

	it("(a') the legacy duplicate save fails -> NotProcessedYet, then a duplicate, never a grant", function()
		local w = setup({ history = { ["1_old-2"] = true } })
		local p = w.h:addPlayer({ userId = 1 })
		w.store.failNext(1)
		expect(w.h:receipt(receipt("old-2"))).toBe("NotProcessedYet")
		expect(w.h:receipt(receipt("old-2"))).toBe("PurchaseGranted")
		expect(w.h:receipt(receipt("old-2"))).toBe("PurchaseGranted")
		expect(w.grants).toBe(0)
		expect(w.h:saved(p)._framework.legacyPurchases["old-2"]).never.toBeNil()
		for _, a in w.h.fake.analytics do
			expect(a.name == "ProductPurchased").toBe(false) -- nothing was granted here
		end
	end)

	it("(b) an id carried over in _framework.legacyPurchases -> 0 grants, no store read", function()
		local w = setup()
		local p = w.h:addPlayer({
			userId = 1,
			data = { _framework = { schemaVersion = 2, _owners = {}, legacyPurchases = { ["imp-1"] = 1 } } },
		})
		for _ = 1, 3 do
			expect(w.h:receipt(receipt("imp-1"))).toBe("PurchaseGranted")
		end
		expect(w.grants).toBe(0)
		expect(coins(w, p)).toBe(0)
		expect(w.legacy.reads).toBe(0)
		-- an onLegacyProduct receipt with a carried-over id is a duplicate too
		expect(w.h:receipt(receipt("imp-1", 202))).toBe("PurchaseGranted")
		expect(w.oldRuns).toBe(0)
	end)

	it(
		"(c) a receipt the old game never granted -> exactly 1 grant across a failed save and redeliveries",
		function()
			local w = setup()
			local p = w.h:addPlayer({ userId = 1 })
			w.store.failNext(1)
			expect(w.h:receipt(receipt("new-1"))).toBe("NotProcessedYet")
			for _ = 1, 3 do
				expect(w.h:receipt(receipt("new-1"))).toBe("PurchaseGranted")
			end
			expect(w.grants).toBe(1)
			expect(w.h:saved(p).store.coins).toBe(10)
			w.h:rejoin(p)
			expect(w.h:receipt(receipt("new-1"))).toBe("PurchaseGranted")
			expect(w.grants).toBe(1)
			expect(w.h:saved(p)._framework.legacyPurchases).toBeNil()
		end
	)

	it("(d) legacy store read failure -> NotProcessedYet, then success -> 1 grant", function()
		local w = setup()
		local p = w.h:addPlayer({ userId = 1 })
		w.legacy.failNext(2)
		expect(w.h:receipt(receipt("new-2"))).toBe("NotProcessedYet")
		expect(w.h:receipt(receipt("new-2"))).toBe("NotProcessedYet")
		expect(w.grants).toBe(0)
		local warned = false
		for _, m in w.h:warnings() do
			if string.find(m, "legacy_check_failed", 1, true) then
				warned = true
			end
		end
		expect(warned).toBe(true)
		expect(w.h:receipt(receipt("new-2"))).toBe("PurchaseGranted")
		expect(w.h:receipt(receipt("new-2"))).toBe("PurchaseGranted")
		expect(w.grants).toBe(1)
		expect(coins(w, p)).toBe(10)
	end)

	it("(d') past until + the re-delivery window the store isn't read (an outage can't block)", function()
		local start = 1_800_000_000
		local w = setup({
			startTime = start,
			legacyReceipts = { name = HISTORY, key = "{userId}_{purchaseId}", ["until"] = start - 91 * 86400 },
		})
		w.h:addPlayer({ userId = 1 })
		w.legacy.failNext(5)
		expect(w.h:receipt(receipt("late-1"))).toBe("PurchaseGranted")
		expect(w.legacy.reads).toBe(0)
		expect(w.grants).toBe(1)
	end)

	it("(d'') within the window `until` still checks the store", function()
		local start = 1_800_000_000
		local w = setup({
			startTime = start,
			history = { ["1_old-3"] = true },
			legacyReceipts = { name = HISTORY, key = "{userId}_{purchaseId}", ["until"] = start - 10 * 86400 },
		})
		w.h:addPlayer({ userId = 1 })
		expect(w.h:receipt(receipt("old-3"))).toBe("PurchaseGranted")
		expect(w.grants).toBe(0)
		expect(w.legacy.reads).toBe(1)
	end)

	it("(e) onLegacyProduct: the old handler runs once across a failed save + redelivery", function()
		local w = setup()
		local p = w.h:addPlayer({ userId = 1 })
		w.store.failNext(1)
		expect(w.h:receipt(receipt("lp-1", 202))).toBe("NotProcessedYet")
		expect(w.oldRuns).toBe(1)
		expect(w.lastOld.player).toBe(p)
		expect(w.lastOld.receiptInfo.PurchaseId).toBe("lp-1")
		expect(w.h:receipt(receipt("lp-1", 202))).toBe("PurchaseGranted")
		expect(w.h:receipt(receipt("lp-1", 202))).toBe("PurchaseGranted")
		expect(w.oldRuns).toBe(1)
		expect(w.h:saved(p)._framework.purchases["lp-1"]).never.toBeNil()
	end)

	it(
		"(e') onLegacyProduct: NotProcessedYet / an error / a non-string -> NotProcessedYet, nothing recorded",
		function()
			local w = setup()
			local p = w.h:addPlayer({ userId = 1 })
			for _, answer in { "NotProcessedYet", 42, "error", "granted" } do
				w.oldAnswer = answer
				expect(w.h:receipt(receipt("lp-2", 202))).toBe("NotProcessedYet")
			end
			local mem = w.h.runtime.data.frameworkField(p, "purchases")
			expect(mem and mem["lp-2"]).toBeNil() -- nothing recorded, not even in memory
			w.oldAnswer = "PurchaseGranted"
			expect(w.h:receipt(receipt("lp-2", 202))).toBe("PurchaseGranted")
			expect(w.oldRuns).toBe(5)
		end
	)

	it("(e'') onLegacyProduct goes through the old history check first", function()
		local w = setup({ history = { ["1_lp-3"] = true } })
		w.h:addPlayer({ userId = 1 })
		expect(w.h:receipt(receipt("lp-3", 202))).toBe("PurchaseGranted")
		expect(w.oldRuns).toBe(0)
	end)

	it("every onLegacyProduct logs a boot warning naming the product", function()
		local w = setup()
		local found = false
		for _, m in w.h:warnings() do
			if string.find(m, "legacy product OldPack", 1, true) then
				found = true
			end
		end
		expect(found).toBe(true)
	end)
end)

describe("LegacyShop: boot errors and validation", function()
	it("(f) a product with both handlers -> boot error", function()
		local w = setup({ both = true })
		expect(w.h).toBeNil()
		expect(w.err).toContain("product 'Both' already has a handler")
	end)

	it("(f) writesLegacyData + an import -> boot error at claim", function()
		local claimedFn = nil
		local s = Shop.new({
			data = {
				legacyImports = function()
					return { "Inventory" }
				end,
			},
			products = { passes = {}, devProducts = { CoinPack = 7 } },
			marketplace = {
				setProcessReceipt = function(fn)
					claimedFn = fn
				end,
				decision = function(x)
					return x
				end,
			},
			players = {
				list = function()
					return {}
				end,
				byUserId = function() end,
			},
			log = function() end,
			spawn = function() end,
			now = function()
				return 0
			end,
			hasLegacyImport = function()
				return true
			end,
		})
		s.forModule("Shopkeeper").onLegacyProduct("CoinPack", function()
			return "PurchaseGranted"
		end, { writesLegacyData = true })
		local ok, err = pcall(s.claim)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain(
			"legacy product CoinPack writes the old save, but Inventory imports it (importLegacy); migrate CoinPack to ctx.shop.onProduct first"
		)
		expect(claimedFn).toBeNil()
	end)

	it("legacyReceipts / onLegacyProduct from start (not init) -> boot error", function()
		for _, which in { "legacyReceipts", "onLegacyProduct" } do
			local _, err = Harness.boot({
				modules = { Store },
				products = PRODUCTS,
				legacy = Harness.legacyStore(),
				servers = {
					Store = {
						init = function() end,
						start = function(ctx)
							if which == "legacyReceipts" then
								ctx.shop.legacyReceipts({ name = HISTORY, key = "{userId}_{purchaseId}" })
							else
								ctx.shop.onLegacyProduct("OldPack", function()
									return "PurchaseGranted"
								end, { writesLegacyData = false })
							end
						end,
					},
				},
			})
			expect(tostring(err)).toContain(`ctx.shop.{which}: register it in init`)
		end
	end)

	it("writesLegacyData = false + an import boots", function()
		local s = Shop.new({
			data = {},
			products = { passes = {}, devProducts = { CoinPack = 7 } },
			marketplace = {
				setProcessReceipt = function() end,
				decision = function(x)
					return x
				end,
			},
			players = {
				list = function()
					return {}
				end,
				byUserId = function() end,
			},
			log = function() end,
			now = function()
				return 0
			end,
			hasLegacyImport = function()
				return true
			end,
		})
		s.forModule("Shopkeeper").onLegacyProduct("CoinPack", function() end, { writesLegacyData = false })
		expect(pcall(s.claim)).toBe(true)
		expect(s.isClaimed()).toBe(true)
	end)

	it("writesLegacyData is required", function()
		local w = setup({
			init = function(ctx)
				ctx.shop.onLegacyProduct("Both", function() end, {})
			end,
		})
		expect(w.h).toBeNil()
		expect(w.err).toContain("writesLegacyData")
	end)

	it("legacyReceipts: once per game and validated", function()
		local twice = setup({
			init = function(ctx)
				ctx.shop.legacyReceipts({ name = "Other", key = "{purchaseId}" })
			end,
		})
		expect(twice.h).toBeNil()
		expect(twice.err).toContain("once per game")
		local bad = {
			{ name = "", key = "{purchaseId}" },
			{ name = "X", key = "{userId}" },
			{ name = "X", key = "{purchaseId}_{place}" },
			{ name = "X", key = "{purchaseId}", ["until"] = "soon" },
			{ name = "X", key = "{purchaseId}", extra = 1 },
		}
		for _, spec in bad do
			expect(Shop.validateLegacyReceipts(spec)).never.toBeNil()
		end
		expect(Shop.validateLegacyReceipts({
			name = "X",
			scope = "s",
			key = "{userId}_{purchaseId}",
			["until"] = 1,
		})).toBeNil()
	end)

	it("legacyReceipts / onLegacyProduct after boot -> error", function()
		local w = setup()
		expect(pcall(w.ctx.shop.legacyReceipts, { name = "Late", key = "{purchaseId}" })).toBe(false)
		expect(pcall(w.ctx.shop.onLegacyProduct, "Both", function() end, { writesLegacyData = false })).toBe(
			false
		)
	end)
end)
