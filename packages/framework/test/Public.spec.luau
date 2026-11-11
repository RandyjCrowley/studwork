--!nocheck
--[[
	StudWork.test (module-api.md §15): the public harness reached through the facade. Real kit
	modules (no injected servers), purchases with re-delivery, rejoin with secondsAway, two
	harnesses sharing one store, store failure injection, and the multi-server sim entry.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local Offline = require(Modules:WaitForChild("Offline"):WaitForChild("module"))

local PRODUCTS = { passes = {}, devProducts = { Coins100 = 1001 } }

-- A game-side module selling Coins100 through Economy's purchase ops.
local function coinShop(granted: { string })
	local ref = StudWork.defineModule({
		name = "CoinShop",
		version = "1.0.0",
		framework = "^1.3.0",
		dependsOn = { Economy },
	})
	local part = {
		init = function(ctx)
			ctx.shop.onProduct("Coins100", function(tx)
				table.insert(granted, tx.receipt.PurchaseId)
				tx.use(Economy).grant(100)
			end)
		end,
	}
	return ref, part
end

describe("StudWork.test", function()
	it("is served by the facade and runs the real kit modules", function()
		expect(type(StudWork.test.harness)).toBe("function")
		local h = StudWork.test.harness({
			modules = { Economy, Offline },
			config = { Economy = { startingCurrency = { Coins = 5 } } },
		})
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Economy).balance(p)).toBe(5)
		expect(h:use(Economy).grant(p, 10, "test")).toBe(true)
		h:rejoin(p, { secondsAway = 600 })
		expect(h:use(Economy).balance(p)).toBe(15)
		expect(h:saved(p).economy.currency.Coins).toBe(15)
		h:removePlayer(p)
		expect(h:saved(p)._framework.stats.sessions).toBe(2)
	end)

	it("h:purchase re-delivers a receipt and the grant happens exactly once", function()
		local granted = {}
		local ref, part = coinShop(granted)
		local h = StudWork.test.harness({
			modules = { Economy, ref },
			servers = { CoinShop = part },
			products = PRODUCTS,
		})
		local p = h:addPlayer({ userId = 2 })
		local decision, all = h:purchase(p, "Coins100", { retries = 2, redeliver = true, purchaseId = "r-1" })
		expect(decision).toBe("PurchaseGranted")
		expect(#all).toBe(3)
		expect(#granted).toBe(1)
		expect(h:use(Economy).balance(p)).toBe(100)
		-- a player who is not in the server: NotProcessedYet on every delivery
		local ghost = StudWork.test.player(99)
		local d2, all2 = h:purchase(ghost, 1001, { retries = 2 })
		expect(d2).toBe("NotProcessedYet")
		expect(#all2).toBe(3)
	end)

	it("two harnesses sharing one store see each other's saves; failures are injectable", function()
		local store = StudWork.test.memoryStore()
		local a = StudWork.test.harness({ modules = { Economy }, store = store })
		local p = a:addPlayer({ userId = 3 })
		a:use(Economy).grant(p, 7, "test")
		a:removePlayer(p)
		local b = StudWork.test.harness({ modules = { Economy }, store = store })
		local q = b:addPlayer({ userId = 3 })
		expect(b:use(Economy).balance(q)).toBe(7)
		b:removePlayer(q)
		store.failNext(1)
		local r = b:addPlayer({ userId = 3 })
		expect(r.loaded).toBe(false) -- the load failed: kicked, nothing loaded
		expect(r.kicked ~= nil).toBe(true)
	end)

	it("StudWork.test.sim is the multi-server simulation", function()
		local sim = StudWork.test.sim
		local world = sim.world()
		local s = sim.server(world)
		local p = s:join(4)
		expect(world:advanceUntil(function()
			return s:isLoaded(p)
		end, 30)).toBe(true)
		expect(s:use("Economy").grant(p, 3, "test")).toBe(true)
		expect(s:section(p, "economy").currency.Coins).toBe(3)
	end)
end)
