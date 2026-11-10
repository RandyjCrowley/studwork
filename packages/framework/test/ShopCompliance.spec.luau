--!nocheck
-- core-v1.3.0 step 4b: framework Shop (receipts, purchase tx, passes) and Compliance (random
-- sources, paid rolls, paid currencies, luck rule) behind ctx (module-api.md §7, §7.1, §14).
local StudWork = require(script.Parent.Parent.shared)
local Harness = require(script.Parent.harness)

local def = StudWork.defineModule

local function mod(name, extra)
	local spec = { name = name, version = "1.0.0", framework = "^1.3.0" }
	for k, v in extra or {} do
		spec[k] = v
	end
	return def(spec)
end

-- A currency module: Coins (paid, sold for Robux) and Gems (free).
local Bank = mod("Bank", { data = { key = "bank", version = 1, default = { Coins = 100, Gems = 0 } } })
-- A random-source module: "Box" (free table) and "Egg"; purchase ops grant / roll.
local Loot = mod("Loot", {
	dependsOn = { Bank },
	data = { key = "loot", version = 1, default = { items = {}, pity = 0 } },
})
-- The game: sells products using both.
local Game = mod("Game", { dependsOn = { Bank, Loot }, data = { key = "game", version = 1, default = { bought = 0 } } })
local Stranger = mod("Stranger", { data = { key = "stranger", version = 1, default = {} } })

local ctxs = {}
local nextOutcome = "pebble"
local sampleCalls = 0

local function servers(gameHandlers)
	return {
		Bank = {
			init = function(ctx)
				ctxs.Bank = ctx
				ctx.compliance.registerCurrencySpender("Coins", function(tx, amount)
					local s = ctx.section(tx)
					if s.Coins < amount then
						return false
					end
					s.Coins -= amount
					return true
				end)
			end,
			purchaseOps = {
				grant = function(tx, amount)
					local s = ctxs.Bank.section(tx)
					s.Coins += amount
					return true
				end,
			},
		},
		Loot = {
			init = function(ctx)
				ctxs.Loot = ctx
				for _, id in { "Box", "Egg" } do
					ctx.compliance.registerRandomSource(id, {
						odds = function(player)
							return { tableId = id, luck = ctx.data.isLoaded(player) and (ctxs.luck or 1) or 1, items = { pebble = 1 } }
						end,
						sample = function(player, luck, tx)
							sampleCalls += 1
							local s = ctx.section(tx)
							s.pity += 1
							return { itemId = nextOutcome, luck = luck }
						end,
						luckDisclosed = id == "Box",
					})
				end
			end,
			purchaseOps = {
				roll = function(tx, sourceId, luck)
					local c = ctxs.Loot
					local ok, outcome, reason = c.compliance.roll(tx, sourceId, luck)
					if not ok then
						return nil, reason
					end
					local s = c.section(tx)
					table.insert(s.items, { id = outcome.itemId, source = c.compliance.tagPaid(tx, "drop") })
					return outcome
				end,
				addItem = function(tx, itemId)
					local c = ctxs.Loot
					table.insert(c.section(tx).items, { id = itemId, source = c.compliance.tagPaid(tx, "drop") })
					return true
				end,
			},
			api = {
				buyBox = function(player)
					local c = ctxs.Loot
					return c.tx(player, function(tx)
						local ok, outcome, reason = c.compliance.spendForRoll(tx, "Coins", 30, "Box")
						if not ok then
							return reason
						end
						table.insert(c.section(tx).items, { id = outcome.itemId, source = c.compliance.tagPaid(tx, "drop") })
						return outcome.itemId
					end)
				end,
				freeBox = function(player)
					local c = ctxs.Loot
					return c.tx(player, function(tx)
						local ok, outcome = c.compliance.roll(tx, "Box", 5) -- free: any luck
						table.insert(c.section(tx).items, { id = outcome.itemId, source = c.compliance.tagPaid(tx, "reward") })
						return ok
					end)
				end,
			},
		},
		Game = {
			init = function(ctx)
				ctxs.Game = ctx
				for product, fn in gameHandlers or {} do
					ctx.shop.onProduct(product, fn)
				end
			end,
		},
		Stranger = {
			init = function(ctx)
				ctxs.Stranger = ctx
			end,
		},
	}
end

local PRODUCTS = { passes = { Vip = 77, Soon = 0 }, devProducts = { CoinPack = 11, EggRoll = 22, Broken = 33, Later = 0 } }

local function boot(gameHandlers, extra)
	nextOutcome = "pebble"
	sampleCalls = 0
	ctxs = {}
	local opts = {
		modules = { Bank, Loot, Game, Stranger },
		servers = servers(gameHandlers),
		products = PRODUCTS,
		compliance = { paidCurrencies = { "Coins" } },
	}
	for k, v in extra or {} do
		opts[k] = v
	end
	return Harness.new(opts)
end

local function receipt(pid, product, user)
	return { PlayerId = user or 1, PurchaseId = pid, ProductId = product, CurrencySpent = 49 }
end

describe("ctx.shop: receipts", function()
	it("grants once: handler + purchase record in one commit, effects after the save, duplicates skip", function()
		local runs, effects = 0, 0
		local h = boot({
			CoinPack = function(tx)
				runs += 1
				expect(tx.paid).toBe(true)
				expect(tx.productName).toBe("CoinPack")
				tx.use(Bank).grant(1000)
				ctxs.Game.section(tx).bought += 1
				tx.after(function()
					effects += 1
				end)
			end,
		})
		local p = h:addPlayer({ userId = 1 })
		expect(h:receipt(receipt("r1", 11))).toBe("PurchaseGranted")
		expect(h:receipt(receipt("r1", 11))).toBe("PurchaseGranted")
		expect(runs).toBe(1)
		expect(effects).toBe(1)
		expect(ctxs.Bank.data.get(p).Coins).toBe(1100)
		expect(ctxs.Game.data.get(p).bought).toBe(1)
		h:removePlayer(p)
		local saved = h:saved(p)
		expect(saved._framework.purchases.r1).Not.toBeNil()
		expect(saved.bank.Coins).toBe(1100)
		local granted = 0
		for _, a in h.fake.analytics do
			if a.name == "ProductPurchased" then
				granted += 1
			end
		end
		expect(granted).toBe(1)
	end)

	it("handler error / yield / retryLater write nothing and return NotProcessedYet", function()
		local h = boot({
			CoinPack = function(tx)
				tx.use(Bank).grant(5)
				error("nope")
			end,
			EggRoll = function(tx)
				tx.use(Bank).grant(5)
				coroutine.yield()
			end,
			Broken = function(tx)
				tx.use(Bank).grant(5)
				pcall(tx.retryLater, "later") -- a swallowed retry still discards
			end,
		})
		local p = h:addPlayer({ userId = 1 })
		expect(h:receipt(receipt("a", 11))).toBe("NotProcessedYet")
		expect(h:receipt(receipt("b", 22))).toBe("NotProcessedYet")
		expect(h:receipt(receipt("c", 33))).toBe("NotProcessedYet")
		expect(ctxs.Bank.data.get(p).Coins).toBe(100)
		expect(h.runtime.data.frameworkField(p, "purchases").a).toBeNil()
		local w = table.concat(h:warnings(), "\n")
		expect(w).toContain("handler_error")
		expect(w).toContain("handler_yielded")
		expect(w).Not.toContain("retry_later")
	end)

	it("not in server / unknown product / not loaded are retried later, quietly where expected", function()
		local h = boot({ CoinPack = function() end })
		expect(h:receipt(receipt("x", 11, 42))).toBe("NotProcessedYet") -- not in server
		local p = h:addPlayer({ userId = 1 })
		expect(h:receipt(receipt("y", 999))).toBe("NotProcessedYet") -- no handler
		expect(table.concat(h:warnings(), "\n")).toContain("no_handler")
		expect(p.loaded).toBe(true)
	end)

	it("tx.use only reaches declared dependencies; onProduct is owned by one module", function()
		local err
		local h = boot()
		ctxs.Stranger.shop.onProduct("Later", function() end) -- id 0: kept by name
		local _, e2 = pcall(ctxs.Stranger.shop.onProduct, "Later", function() end)
		expect(tostring(e2)).toContain("already has a handler (owned by Stranger)")
		ctxs.Stranger.shop.onProduct(11, function(tx)
			local ok, e = pcall(tx.use, Bank)
			err = e
			assert(not ok)
		end)
		h:addPlayer({ userId = 1 })
		h:receipt(receipt("z", 11))
		expect(tostring(err)).toContain("Stranger must declare Bank in dependsOn/optional")
	end)

	it("ProcessReceipt is claimed at the very end of boot", function()
		local h = boot()
		expect(h.runtime.shop.isClaimed()).toBe(true)
		expect(h.fake.receiptFn).Not.toBeNil()
	end)

	it("a failed save keeps the record: the retry is a duplicate that releases the effects", function()
		local effects = 0
		local store = Harness.player and require(script.Parent.Parent.server.Store).memory()
		local saves = 0
		store.saveNow = function()
			saves += 1
			return saves > 1 -- first confirmation fails
		end
		local h = boot({
			CoinPack = function(tx)
				tx.use(Bank).grant(1)
				tx.after(function()
					effects += 1
				end)
			end,
		}, { store = store })
		local p = h:addPlayer({ userId = 1 })
		expect(h:receipt(receipt("s1", 11))).toBe("NotProcessedYet")
		expect(effects).toBe(0)
		expect(h:receipt(receipt("s1", 11))).toBe("PurchaseGranted")
		expect(effects).toBe(1)
		expect(ctxs.Bank.data.get(p).Coins).toBe(101)
	end)
end)

describe("ctx.shop: gamepasses", function()
	it("ownsPass + onPassOwned run once per player for owned passes", function()
		local fired = 0
		local h = boot(nil, { owned = { [1] = { [77] = true } } })
		ctxs.Game.shop.onPassOwned("Vip", function()
			fired += 1
		end)
		local p = h:addPlayer({ userId = 1 })
		expect(ctxs.Game.shop.ownsPass(p, "Vip")).toBe(true)
		expect(ctxs.Game.shop.ownsPass(p, "Soon")).toBe(false) -- id 0
		expect(fired).toBe(1)
		h.runtime.passPurchased(p, 77, true)
		expect(fired).toBe(1)
	end)
end)

describe("ctx.compliance", function()
	it("a paid (purchase) roll grants through the source's sample, tagged paid:<product>", function()
		local h = boot({
			EggRoll = function(tx)
				assert(tx.use(Loot).roll("Egg"))
			end,
		})
		local p = h:addPlayer({ userId = 1 })
		expect(h:receipt(receipt("e1", 22))).toBe("PurchaseGranted")
		local items = ctxs.Loot.data.get(p).items
		expect(#items).toBe(1)
		expect(items[1].source).toBe("paid:EggRoll")
		expect(ctxs.Loot.data.get(p).pity).toBe(1)
	end)

	it("restricted players get 'restricted' (grant a fixed fallback); unknown policy retries the purchase", function()
		local reasons = {}
		local h = boot({
			EggRoll = function(tx)
				local out, reason = tx.use(Loot).roll("Egg")
				table.insert(reasons, reason or "ok")
				if out == nil then
					assert(tx.use(Loot).addItem("crystal")) -- fixed, non-random fallback
				end
			end,
		}, { policy = { [1] = true, [2] = "fail" } })
		local a = h:addPlayer({ userId = 1 })
		expect(h:receipt(receipt("r1", 22, 1))).toBe("PurchaseGranted")
		expect(reasons[1]).toBe("restricted")
		expect(ctxs.Loot.data.get(a).items[1].id).toBe("crystal")
		expect(sampleCalls).toBe(0)
		local b = h:addPlayer({ userId = 2 })
		expect(h:receipt(receipt("r2", 22, 2))).toBe("NotProcessedYet")
		expect(#ctxs.Loot.data.get(b).items).toBe(0)
		expect(table.concat(h:warnings(), "\n")).Not.toContain("r2")
	end)

	it("spendForRoll spends a paid currency and rolls in one tx; insufficient spends nothing", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Loot).buyBox(p)).toBe(true)
		expect(ctxs.Bank.data.get(p).Coins).toBe(70)
		local items = ctxs.Loot.data.get(p).items
		expect(items[1].source).toBe("paidcur:Box")
		for _ = 1, 2 do
			h:use(Loot).buyBox(p)
		end
		expect(ctxs.Bank.data.get(p).Coins).toBe(10)
		local _, reason = h:use(Loot).buyBox(p)
		expect(reason).toBe("insufficient")
		expect(ctxs.Bank.data.get(p).Coins).toBe(10)
		expect(#ctxs.Loot.data.get(p).items).toBe(3)
	end)

	it("an empty sample after a paid spend discards the whole tx", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		nextOutcome = nil
		expect(function()
			h:use(Loot).buyBox(p)
		end).toThrow("the spend is discarded")
		expect(ctxs.Bank.data.get(p).Coins).toBe(100)
	end)

	it("free rolls (outside a purchase, no paid currency) may use any luck and are tagged as given", function()
		local h = boot(nil, { policy = { [1] = true } })
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Loot).freeBox(p)).toBe(true) -- restricted players may roll free tables
		expect(ctxs.Loot.data.get(p).items[1].source).toBe("reward")
	end)

	it("luck rule: a paid roll with luck ~= 1 needs a luckDisclosed source and the same luck sent", function()
		local h = boot({
			EggRoll = function(tx)
				assert(tx.use(Loot).roll("Egg", 2))
			end,
			CoinPack = function(tx)
				assert(tx.use(Loot).roll("Box", 2))
			end,
		})
		local p = h:addPlayer({ userId = 1 })
		h:fire(p, "StateInit")
		expect(h:receipt(receipt("l1", 22))).toBe("NotProcessedYet")
		expect(table.concat(h:warnings(), "\n")).toContain("does not set luckDisclosed")
		expect(h:receipt(receipt("l2", 11))).toBe("NotProcessedYet") -- disclosed table, but luck 2 never sent
		expect(table.concat(h:warnings(), "\n")).toContain("has not been shown odds with that luck")
		ctxs.luck = 2
		ctxs.Loot.compliance.disclose(p, "Box")
		h:tick(1)
		expect(ctxs.Loot.compliance.disclosed(p, "Box").luck).toBe(2)
		expect(h:receipt(receipt("l3", 11))).toBe("PurchaseGranted")
		ctxs.luck = nil
	end)

	it("paid currencies can't be spent for a roll except through spendForRoll; scoping errors", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		expect(ctxs.Bank.compliance.isPaidCurrency("Coins")).toBe(true)
		expect(ctxs.Bank.compliance.isPaidCurrency("Gems")).toBe(false)
		ctxs.Loot.tx(p, function(tx)
			expect(function()
				ctxs.Loot.compliance.spendForRoll(tx, "Gems", 1, "Box")
			end).toThrow("is not in GameConfig.compliance.paidCurrencies")
		end)
		ctxs.Stranger.tx(p, function(tx)
			expect(function()
				ctxs.Stranger.compliance.roll(tx, "Box")
			end).toThrow("Stranger can't roll 'Box' (owned by Loot)")
		end)
		expect(function()
			ctxs.Stranger.compliance.registerCurrencySpender("Coins", function() end)
		end).toThrow("already has a spender (owned by Bank)")
		expect(function()
			ctxs.Stranger.compliance.registerRandomSource("Box", { odds = print, sample = print, luckDisclosed = false })
		end).toThrow("already registered (by Loot)")
	end)

	it("disclosed odds are replicated per player on load (framework.odds)", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		h:fire(p, "StateInit")
		local s = h:state(p)
		expect(s.framework.odds.Box.tableId).toBe("Box")
		expect(s.framework.odds.Egg.tableId).toBe("Egg")
	end)
end)
