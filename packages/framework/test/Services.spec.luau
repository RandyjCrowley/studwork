--!nocheck
-- v1.3.0: every framework service behind ctx is real. Module
-- actions (§9), Replication's per-section cache (§10, M2), Policy, Analytics, Events, and the
-- framework Shop keeping the v1.1/v1.2 receipt guarantees (§7), the exclusive ProcessReceipt
-- owner (§7.1) and N9 (after-purchase effects when the player has left).
local StudWork = require(script.Parent.Parent.shared)
local Harness = require(script.Parent.harness)
local Store = require(script.Parent.Parent.server.Store)

local def = StudWork.defineModule

local function mod(name, extra)
	local spec = { name = name, version = "1.0.0", framework = "^1.3.0" }
	for k, v in extra or {} do
		spec[k] = v
	end
	return def(spec)
end

local function count(list, pred)
	local n = 0
	for _, x in list do
		if pred(x) then
			n += 1
		end
	end
	return n
end

local function customs(h, name)
	return count(h.fake.analytics, function(a)
		return a.kind == "custom" and a.name == name
	end)
end

-- ===================================================================== net: module actions

describe("ctx.net: module actions (§9)", function()
	local Upgrades = mod("Upgrades", { data = { key = "upgrades", version = 1, default = { level = 0 } } })

	local function boot(netModule, extraActions)
		local c
		local calls = {}
		local actions = {
			upgrade = {
				limit = { rate = 1, burst = 2 },
				handler = function(player, id)
					table.insert(calls, id)
					if id == "boom" then
						error("upgrade blew up")
					end
					c.data.update(player, function(s)
						s.level += 1
					end)
					return "ok:" .. tostring(id)
				end,
			},
		}
		for k, v in extraActions or {} do
			actions[k] = v
		end
		local h = Harness.new({
			modules = { Upgrades },
			servers = {
				Upgrades = {
					net = netModule,
					actions = actions,
					init = function(ctx)
						c = ctx
					end,
				},
			},
		})
		return h, calls, function()
			return c
		end
	end

	it("routes the module's own Blink event to its action: rate limit, pcall, loaded check", function()
		local log = {}
		local ev = Harness.fakeEvent("Upgrade", log)
		local h, calls, ctx = boot({ Upgrade = ev })
		local p = h:addPlayer({ userId = 1 })
		h:fireCustom(ev, p, "a")
		h:fireCustom(ev, p, "boom") -- pcall'd: Net survives
		h:fireCustom(ev, p, "c") -- burst 2 used up: dropped
		expect(table.concat(calls, ",")).toBe("a,boom")
		expect(ctx().data.get(p).level).toBe(1)
		expect(table.concat(h:warnings(), "\n")).toContain("action:Upgrades.upgrade handler error")
		expect(h.runtime.net.stats.limited).toBe(1)
		h:tick(2) -- refill
		h:fireCustom(ev, p, "d")
		expect(calls[#calls]).toBe("d")
	end)

	it("blocks calls until the player's data loads and drops calls from players who left", function()
		local ev = Harness.fakeEvent("Upgrade", {})
		local h, calls = boot({ Upgrade = ev })
		local early = Harness.player(5)
		h.inGame[early] = true -- joined, not loaded yet
		h:fireCustom(ev, early, "early")
		expect(#calls).toBe(0)
		expect(h.runtime.net.stats.notLoaded).toBe(1)
		h:fireCustom(ev, Harness.player(99), "ghost") -- never in the game
		expect(#calls).toBe(0)
		local p = h:addPlayer({ userId = 2 })
		h:removePlayer(p)
		h:fireCustom(ev, p, "gone")
		expect(#calls).toBe(0)
	end)

	it("requests that arrive before Net.start are queued and released at start (boot step 6)", function()
		-- Net is created in boot step 3 and started in step 6; drive one directly to observe it.
		local Net = require(script.Parent.Parent.server.Net)
		local early = Harness.player(3)
		local events = { StateInit = Harness.fakeEvent("StateInit", {}) }
		local net = Net.new({
			events = events,
			isPlayer = function(p)
				return p == early
			end,
			isLoaded = function()
				return true
			end,
			clock = function()
				return 0
			end,
			spawn = function(fn, ...)
				fn(...)
			end,
			log = function() end,
		})
		local served = 0
		net.claim("framework", "StateInit", function()
			served += 1
		end)
		events.StateInit.listeners[1](early)
		expect(served).toBe(0) -- queued, not served
		net.start()
		expect(served).toBe(1) -- released at start
	end)

	it("h:action goes through the same checks; bad declarations are boot errors", function()
		local h, calls = boot(nil, {
			ping = function(_player, n)
				return n * 2
			end,
		})
		local p = h:addPlayer({ userId = 4 })
		local ok, res = h:action(p, Upgrades, "ping", 21)
		expect(ok).toBe(true)
		expect(res).toBe(42)
		expect(select(2, h:action(Harness.player(77), Upgrades, "ping", 1))).toBe("left")
		h:action(p, Upgrades, "upgrade", "x")
		h:action(p, Upgrades, "upgrade", "y")
		expect(select(2, h:action(p, Upgrades, "upgrade", "z"))).toBe("rate_limited")
		expect(#calls).toBe(2)
		local okErr, err = h:action(p, Upgrades, "ping", "not a number")
		expect(okErr).toBe(false)
		expect(tostring(err)).toContain("arithmetic")
		local _, bootErr = Harness.boot({
			modules = { Upgrades },
			servers = {
				Upgrades = { actions = { bad = { limit = { rate = 0, burst = 1 }, handler = print } } },
			},
		})
		expect(bootErr).toContain("Upgrades.actions.bad: limit must be")
	end)
end)

-- ===================================================================== replicate

describe("ctx.replicate: per-section cache", function()
	it("an unrelated section's commit does not re-copy this module's replicated data", function()
		local A = mod("A", { data = { key = "a", version = 1, default = { n = 0 }, replicate = { "n" } } })
		local B = mod("B", { data = { key = "b", version = 1, default = { m = 0 }, replicate = { "m" } } })
		local ca, cb
		local h = Harness.new({
			modules = { A, B },
			servers = {
				A = {
					init = function(ctx)
						ca = ctx
					end,
				},
				B = {
					init = function(ctx)
						cb = ctx
					end,
				},
			},
		})
		local p = h:addPlayer({ userId = 1 })
		h:fire(p, "StateInit")
		local a1 = h:state(p).modules.A.data
		cb.data.update(p, function(s)
			s.m = 5
		end)
		local st = h:state(p)
		expect(st.modules.B.data.m).toBe(5)
		expect(st.modules.A.data).toBe(a1) -- same table: skipped, nothing re-copied
		ca.data.update(p, function(s)
			s.n = s.n -- no change: no version bump
		end)
		expect(h:state(p).modules.A.data).toBe(a1)
	end)
end)

-- ===================================================================== policy

describe("ctx.policy", function()
	it("fails closed while unknown, retries in the background, then publishes the real value", function()
		local Pol = require(script.Parent.Parent.server.Policy)
		local answers = { "fail", "fail", "fail", "fail", "fail", false }
		local timers = {}
		local published = {}
		local pol = Pol.new({
			lookup = function()
				local a = table.remove(answers, 1)
				if a == "fail" then
					error("PolicyService down")
				end
				return { ArePaidRandomItemsRestricted = a }
			end,
			isPlayer = function()
				return true
			end,
			wait = function() end,
			delay = function(s, fn)
				table.insert(timers, { s = s, fn = fn })
			end,
			publish = function(_p, v)
				table.insert(published, v)
			end,
			log = function() end,
		})
		local p = Harness.player(1)
		pol.track(p) -- 4 attempts fail, then a background timer (no busy loop)
		expect(pol.isKnown(p)).toBe(false)
		expect(pol.paidRandomRestricted(p)).toBe(true)
		expect(#timers).toBe(1)
		expect(timers[1].s).toBe(Pol.BACKGROUND_RETRY)
		table.remove(timers, 1).fn() -- 5th: fails again, re-armed
		expect(#timers).toBe(1)
		table.remove(timers, 1).fn() -- 6th: answers
		expect(pol.isKnown(p)).toBe(true)
		expect(pol.paidRandomRestricted(p)).toBe(false)
		expect(#timers).toBe(0)
		expect(published[#published]).toBe(false)
	end)

	it("through the runtime: a lookup that keeps failing never hangs, and the timer retries", function()
		local c
		local Mod = mod("PolMod")
		local h = Harness.new({
			modules = { Mod },
			servers = { PolMod = {
				init = function(ctx)
					c = ctx
				end,
			} },
			policy = { [1] = "fail" },
		})
		local p = h:addPlayer({ userId = 1 })
		expect(c.policy.isKnown(p)).toBe(false)
		expect(c.policy.paidRandomRestricted(p)).toBe(true)
		expect(#h.timers).toBe(1)
		h:tick(31)
		expect(#h.timers).toBe(1) -- still failing: re-armed, not spinning
	end)
end)

-- ===================================================================== analytics

describe("ctx.analytics", function()
	it(
		"funnel steps log once (recorded in _framework), Joined is automatic; economy/custom validated",
		function()
			local c
			local Mod = mod("An")
			local h = Harness.new({
				modules = { Mod },
				servers = { An = {
					init = function(ctx)
						c = ctx
					end,
				} },
				analytics = { funnel = { "Joined", "FirstRoll", "Tutorial" }, clientSteps = { "Tutorial" } },
			})
			local p = h:addPlayer({ userId = 1 })
			c.analytics.funnel(p, "FirstRoll")
			c.analytics.funnel(p, "FirstRoll")
			c.analytics.funnel(p, "NotAStep")
			local funnels = {}
			for _, a in h.fake.analytics do
				if a.kind == "funnel" then
					table.insert(funnels, a.index .. ":" .. a.name)
				end
			end
			expect(table.concat(funnels, ",")).toBe("1:Joined,2:FirstRoll")
			expect(h.runtime.data.frameworkField(p, "funnel").FirstRoll).Not.toBeNil()
			h:fire(p, "ClientFunnel", "FirstRoll") -- not a client step: refused
			h:fire(p, "ClientFunnel", "Tutorial")
			expect(count(h.fake.analytics, function(a)
				return a.kind == "funnel"
			end)).toBe(3)
			c.analytics.economy(p, "Source", "Coins", 10, 110, "quest")
			c.analytics.economy(p, "Source", "Coins", 0 / 0, 110, "quest") -- NaN: dropped
			c.analytics.economy(p, "Sideways", "Coins", 1, 1, "x") -- bad flow: dropped
			expect(count(h.fake.analytics, function(a)
				return a.kind == "economy"
			end)).toBe(1)
			c.analytics.custom(p, "Thing")
			c.analytics.custom(p, "Thing", math.huge) -- dropped
			expect(customs(h, "Thing")).toBe(1)
		end
	)
end)

-- ===================================================================== events

describe("ctx.events", function()
	it("trigger / isActive / onEnded, replicated activeEvents, admin trigger gated", function()
		local c
		local Mod = mod("Ev")
		local started, ended = {}, 0
		local h = Harness.new({
			modules = { Mod },
			servers = {
				Ev = {
					init = function(ctx)
						c = ctx
						ctx.events.schedule("Storm", nil, function(e)
							table.insert(started, e.id)
						end)
						ctx.events.onEnded("Storm", function()
							ended += 1
						end)
					end,
				},
			},
			events = { Storm = { durationSec = 10 }, Calm = { durationSec = 5 } },
			serverConfig = { admins = { 9 } },
		})
		local p = h:addPlayer({ userId = 1 })
		local admin = h:addPlayer({ userId = 9 })
		h:fire(p, "StateInit")
		expect(c.events.trigger("Storm")).toBe(true)
		expect(c.events.trigger("Storm")).toBe(false) -- already active
		expect(c.events.isActive("Storm")).toBe(true)
		expect(table.concat(started, ",")).toBe("Storm")
		expect(h:state(p).framework.activeEvents.Storm).Not.toBeNil()
		h:tick(11)
		expect(c.events.isActive("Storm")).toBe(false)
		expect(ended).toBe(1)
		h:fire(p, "AdminTriggerEvent", "Calm") -- not an admin
		expect(c.events.isActive("Calm")).toBe(false)
		h:fire(admin, "AdminTriggerEvent", "Calm")
		expect(c.events.isActive("Calm")).toBe(true)
		expect(function()
			-- a second module scheduling the same id errors (per-module scoping)
			h.runtime.events.forModule("Other").schedule("Storm", nil, function() end)
		end).toThrow("already scheduled by Ev")
	end)
end)

-- ===================================================================== shop

local Bank = mod("Bank", { data = { key = "bank", version = 1, default = { coins = 0 } } })
local Shopper =
	mod("Shopper", { dependsOn = { Bank }, data = { key = "shopper", version = 1, default = { n = 0 } } })
local PRODUCTS = { passes = {}, devProducts = { Coins = 11, Gift = 12 } }

local function bootShop(handlers, extra)
	local ctxs = {}
	local opts = {
		modules = { Bank, Shopper },
		products = PRODUCTS,
		servers = {
			Bank = {
				init = function(ctx)
					ctxs.Bank = ctx
				end,
				purchaseOps = {
					grant = function(tx, amount)
						ctxs.Bank.section(tx).coins += amount
						return true
					end,
				},
			},
			Shopper = {
				init = function(ctx)
					ctxs.Shopper = ctx
					for product, fn in handlers do
						ctx.shop.onProduct(product, function(tx)
							fn(tx, ctxs)
						end)
					end
				end,
			},
		},
	}
	for k, v in extra or {} do
		opts[k] = v
	end
	return Harness.new(opts), ctxs
end

local function receipt(id, product, user)
	return { PlayerId = user or 1, PurchaseId = id, ProductId = product or 11, CurrencySpent = 25 }
end

describe("framework Shop keeps the v1.1/v1.2 receipt guarantees (Receipt.spec cases, end to end)", function()
	it("malformed receipts and an unloaded player are NotProcessedYet; nothing is recorded", function()
		local runs = 0
		local h = bootShop({
			Coins = function()
				runs += 1
			end,
		})
		expect(h:receipt({ PlayerId = 1 })).toBe("NotProcessedYet") -- no PurchaseId
		expect(h:receipt({ PurchaseId = "", PlayerId = 1, ProductId = 11 })).toBe("NotProcessedYet")
		local p = Harness.player(1)
		h.inGame[p] = true -- in the server, data not loaded
		expect(h:receipt(receipt("u1"))).toBe("NotProcessedYet")
		expect(runs).toBe(0)
		expect(table.concat(h:warnings(), "\n")).toContain("bad_receipt")
		expect(table.concat(h:warnings(), "\n")).toContain("not_loaded")
	end)

	it("PurchaseGranted only after the save is confirmed; the retry never runs the handler twice", function()
		local store = Store.memory()
		local confirm = false
		store.saveNow = function()
			return confirm
		end
		local runs, effects = 0, 0
		local h, ctxs = bootShop({
			Coins = function(tx)
				runs += 1
				tx.use(Bank).grant(100)
				tx.after(function()
					effects += 1
				end)
			end,
		}, { store = store })
		local p = h:addPlayer({ userId = 1 })
		expect(h:receipt(receipt("g1"))).toBe("NotProcessedYet") -- save unconfirmed
		expect(h:receipt(receipt("g1"))).toBe("NotProcessedYet") -- still unconfirmed: no regrant
		expect(runs).toBe(1)
		expect(effects).toBe(0)
		expect(ctxs.Bank.data.get(p).coins).toBe(100) -- committed in memory exactly once
		expect(h.runtime.data.frameworkField(p, "purchases").g1).Not.toBeNil() -- same commit
		confirm = true
		expect(h:receipt(receipt("g1"))).toBe("PurchaseGranted")
		expect(h:receipt(receipt("g1"))).toBe("PurchaseGranted")
		expect(runs).toBe(1)
		expect(effects).toBe(1)
		expect(customs(h, "ProductPurchased")).toBe(1)
	end)

	it(
		"retryLater saves nothing; a handler error records nothing; tx.after runs only after commit",
		function()
			local order = {}
			local h, ctxs = bootShop({
				Coins = function(tx)
					tx.use(Bank).grant(5)
					tx.after(function()
						table.insert(order, "after")
					end)
					table.insert(order, "handler")
					tx.retryLater("not yet")
				end,
				Gift = function(tx)
					tx.use(Bank).grant(5)
					tx.after(function()
						table.insert(order, "never")
					end)
					error("boom")
				end,
			})
			local p = h:addPlayer({ userId = 1 })
			expect(h:receipt(receipt("r1", 11))).toBe("NotProcessedYet")
			expect(h:receipt(receipt("r2", 12))).toBe("NotProcessedYet")
			expect(table.concat(order, ",")).toBe("handler")
			expect(ctxs.Bank.data.get(p).coins).toBe(0)
			local purchases = h.runtime.data.frameworkField(p, "purchases")
			expect(purchases == nil or (purchases.r1 == nil and purchases.r2 == nil)).toBe(true)
			h:removePlayer(p)
			local saved = h:saved(p)
			expect(saved.bank.coins).toBe(0)
		end
	)

	it("a crash before the save lands loses the grant and its record: the next server grants once", function()
		local store = Store.memory()
		store.saveNow = function()
			return false
		end
		local runs = 0
		local handlers = {
			Coins = function(tx)
				runs += 1
				tx.use(Bank).grant(7)
			end,
		}
		local h1 = bootShop(handlers, { store = store })
		h1:addPlayer({ userId = 1 })
		expect(h1:receipt(receipt("c1"))).toBe("NotProcessedYet")
		-- crash: no release, nothing persisted. A fresh server with a working store:
		local store2 = Store.memory()
		local h2, ctxs2 = bootShop(handlers, { store = store2 })
		local p2 = h2:addPlayer({ userId = 1 })
		expect(h2:receipt(receipt("c1"))).toBe("PurchaseGranted")
		expect(h2:receipt(receipt("c1"))).toBe("PurchaseGranted")
		expect(runs).toBe(2) -- once per server: one persisted grant overall
		expect(ctxs2.Bank.data.get(p2).coins).toBe(7)
	end)

	it("a granted receipt re-delivered after a rejoin is acknowledged without a grant", function()
		local runs = 0
		local h, ctxs = bootShop({
			Coins = function(tx)
				runs += 1
				tx.use(Bank).grant(3)
			end,
		})
		local p = h:addPlayer({ userId = 1 })
		expect(h:receipt(receipt("d1"))).toBe("PurchaseGranted")
		h:rejoin(p, { secondsAway = 60 })
		expect(h:receipt(receipt("d1"))).toBe("PurchaseGranted")
		expect(runs).toBe(1)
		expect(ctxs.Bank.data.get(p).coins).toBe(3)
	end)
end)

describe("§7.1: the framework owns ProcessReceipt exclusively", function()
	it("detects a replacement on the Heartbeat ticker: warns with the source, analytics, reclaims", function()
		local h = bootShop({
			Coins = function(tx)
				tx.use(Bank).grant(1)
			end,
		})
		h:addPlayer({ userId = 1 })
		local ours = h.fake.receiptFn
		local function rogue()
			return "PurchaseGranted"
		end
		h.fake.receiptFn = rogue -- a vendored script assigns its own ProcessReceipt
		h:tick(1)
		expect(h.fake.receiptFn).toBe(rogue) -- not yet: checked every RECEIPT_CHECK_SECONDS
		h:tick(2)
		expect(h.fake.receiptFn).toBe(ours) -- reclaimed
		local w = table.concat(h:warnings(), "\n")
		expect(w).toContain("ProcessReceipt was replaced (by ")
		expect(w).toContain("Services.spec.luau") -- debug.info names where the rogue was defined
		local hit
		for _, a in h.fake.analytics do
			if a.name == "ProcessReceiptHijacked" then
				hit = a
			end
		end
		expect(hit).Not.toBeNil()
		expect(hit.fields.source).toContain("Services.spec.luau")
		expect(h.runtime.shop.receiptCheck().hijacks).toBe(1)
		expect(h.runtime.shop.receiptCheck().status).toBe("active")
		expect(h:receipt(receipt("h1"))).toBe("PurchaseGranted") -- purchases flow through Shop again
		h:tick(3)
		expect(h.runtime.shop.receiptCheck().hijacks).toBe(1) -- no fight once it's ours
	end)

	it(
		"sourceOf falls back to 'unknown source'; an unreadable platform reports the check unavailable",
		function()
			local Shop = require(script.Parent.Parent.server.Shop)
			expect(Shop.sourceOf(print)).toBe("unknown source")
			expect(Shop.sourceOf(nil)).toContain("unknown source")
			local h = bootShop({})
			h.runtime.platform.marketplace.getProcessReceipt = function()
				return false, nil
			end
			expect(h.runtime.shop.checkReceiptOwner()).toBe(false)
			expect(h.runtime.shop.receiptCheck().status).toContain("unavailable")
		end
	)
end)

describe("N9: after-purchase effects when the player has left", function()
	it(
		"a parked grant is confirmed on leave and its effects run once (a cross-player send survives)",
		function()
			local store = Store.memory()
			local confirm = false
			store.saveNow = function()
				return confirm
			end
			local mailed, granted = {}, 0
			local h = bootShop({
				Gift = function(tx, ctxs)
					tx.use(Bank).grant(1)
					tx.after(function()
						-- needs nothing from the buyer's presence: a message to another user's save
						table.insert(mailed, ctxs.Shopper.data.messages.send(2, { gift = "pebble" }))
					end)
				end,
			}, { store = store })
			h.runtime.frameworkSignals.ProductGranted:Connect(function()
				granted += 1
			end)
			local p = h:addPlayer({ userId = 1 })
			expect(h:receipt(receipt("n1", 12))).toBe("NotProcessedYet") -- save unconfirmed: parked
			expect(#mailed).toBe(0)
			confirm = true
			h:removePlayer(p) -- leaves before Roblox retries the receipt
			expect(#mailed).toBe(1)
			expect(mailed[1]).toBe(true)
			expect(granted).toBe(1)
			expect(customs(h, "ProductPurchased")).toBe(1)
			expect(h:saved(p)._framework.purchases.n1).Not.toBeNil()
			-- Roblox retries on the next join: a duplicate, nothing runs again
			h:addPlayer({ userId = 1 })
			expect(h:receipt(receipt("n1", 12))).toBe("PurchaseGranted")
			expect(#mailed).toBe(1)
		end
	)

	it("if the leave save can't be confirmed either, the effects are dropped with a warning", function()
		local store = Store.memory()
		store.saveNow = function()
			return false
		end
		local effects = 0
		local h = bootShop({
			Coins = function(tx)
				tx.use(Bank).grant(1)
				tx.after(function()
					effects += 1
				end)
			end,
		}, { store = store })
		local p = h:addPlayer({ userId = 1 })
		expect(h:receipt(receipt("n2"))).toBe("NotProcessedYet")
		h:removePlayer(p)
		expect(effects).toBe(0)
		expect(table.concat(h:warnings(), "\n")).toContain("its tx.after effects are dropped (N9")
		expect(customs(h, "ProductPurchased")).toBe(1) -- analytics still logged (v1.2)
	end)
end)

describe("ctx.compliance.tagPaid(sourceId) (§14 form)", function()
	it("returns paidcur:<id> for a registered source and errors for anything else", function()
		local c
		local Src = mod("Src")
		Harness.new({
			modules = { Src },
			servers = {
				Src = {
					init = function(ctx)
						c = ctx
						ctx.compliance.registerRandomSource("Egg", {
							odds = function()
								return {}
							end,
							sample = function()
								return { itemId = "x" }
							end,
							luckDisclosed = false,
						})
					end,
				},
			},
		})
		expect(c.compliance.tagPaid("Egg")).toBe("paidcur:Egg")
		expect(function()
			c.compliance.tagPaid("Nope")
		end).toThrow("not a registered random source")
	end)
end)
