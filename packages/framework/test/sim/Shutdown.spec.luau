--[[
	Server shutdown (BindToClose) while saves are in flight (known-issues: "receipts across a
	real server crash"). Real Data + ProfileStore (its BindToClose ends every session and waits
	for the writes) + Shop (ProcessReceipt -> Receipt.process -> Data.saveAsync) on the mock
	DataStore with 2-4 s write latency.
]]

local F = require(script.Parent.Fixtures)

local PRODUCT = 1001

local function setup(latency: number)
	local world = F.world()
	local s = F.server(world)
	s:onProduct("Coins100", function(tx)
		tx.use(s:ref("Economy")).grant(100)
	end)
	world.latency = latency
	return world, s
end

local function joinLoaded(world, s, userId: number)
	local p = s:join(userId)
	assert(
		world:advanceUntil(function()
			return s:isLoaded(p)
		end, 30),
		"loaded"
	)
	return p
end

local function nextServer(world)
	local s = F.server(world)
	s:onProduct("Coins100", function(tx)
		tx.use(s:ref("Economy")).grant(100)
	end)
	return s
end

describe("BindToClose with saves in flight", function()
	it("waits for a leave save that is still writing, then the data is in the store", function()
		local world, s = setup(4)
		local p = joinLoaded(world, s, 61)
		s:use("Economy").grant(p, 50, "test")
		s:leave(p) -- release save: 4 s
		local shutdown = s:shutdown()
		world:advance(1)
		expect(shutdown.done).toBe(false)
		expect(shutdown.allDead()).toBe(false) -- ProfileStore's BindToClose is still waiting
		expect(world:advanceUntil(function()
			return shutdown.done
		end, 40)).toBe(true)
		expect(shutdown.completed).toBe(true)
		expect(shutdown.elapsed).toBeLessThan(30)
		expect(F.section(world, 61, "economy").currency.Coins).toBe(50)
		expect(F.lockHolder(world, 61)).toBeNil()
		expect(#world:errors()).toBe(0)
	end)

	it("saves and releases every online player within the 30 s limit", function()
		local world, s = setup(3)
		local p1 = joinLoaded(world, s, 62)
		local p2 = joinLoaded(world, s, 63)
		s:use("Economy").grant(p1, 11, "test")
		s:use("Economy").grant(p2, 22, "test")
		local shutdown = s:shutdown()
		expect(world:advanceUntil(function()
			return shutdown.done
		end, 40)).toBe(true)
		expect(shutdown.completed).toBe(true)
		expect(F.section(world, 62, "economy").currency.Coins).toBe(11)
		expect(F.section(world, 63, "economy").currency.Coins).toBe(22)
		expect(F.lockHolder(world, 62)).toBeNil()
		expect(F.lockHolder(world, 63)).toBeNil()
	end)
end)

describe("receipts across shutdown and crash", function()
	it("a receipt whose save is in flight at shutdown is kept and never granted twice", function()
		local world, s = setup(2)
		local p = joinLoaded(world, s, 64)
		local receipt = F.receipt(64, "purchase-A", PRODUCT)
		local first = s:purchase(receipt)
		world:advance(0.5) -- grant committed in memory, its save is writing
		expect(first.done).toBe(false)
		local shutdown = s:shutdown()
		world:advanceUntil(function()
			return shutdown.done
		end, 40)
		expect(shutdown.completed).toBe(true)
		local stored = F.saved(world, 64)
		expect(stored.economy.currency.Coins).toBe(100)
		expect(stored._framework.purchases["purchase-A"]).never.toBeNil()
		-- whatever ProcessReceipt answered, Roblox may deliver the receipt again elsewhere
		local b = nextServer(world)
		local q = joinLoaded(world, b, 64)
		local retry = b:purchase(receipt)
		world:advanceUntil(function()
			return retry.done
		end, 30)
		expect(retry.result).toBe("PurchaseGranted")
		expect(b:section(q, "economy").currency.Coins).toBe(100)
		expect(#F.grants(b, q, "product:Coins100")).toBe(0)
		expect(#world:errors()).toBe(0)
		local _ = p
	end)

	it("a crash before the save lands loses the grant AND its record, so the retry grants once", function()
		local world, s = setup(2)
		joinLoaded(world, s, 65)
		local receipt = F.receipt(65, "purchase-B", PRODUCT)
		local first = s:purchase(receipt)
		world:advance(0.5)
		s:crash() -- no BindToClose, the in-flight write never commits
		expect(first.done).toBe(false) -- Roblox never got PurchaseGranted
		-- Only the empty template written when the session started is in the store.
		local stored = F.saved(world, 65)
		expect(stored.economy).toBeNil()
		expect(stored._framework).toBeNil()

		-- The crashed server still holds the session lock: the next server waits it out.
		local b = nextServer(world)
		local q = b:join(65)
		expect(world:advanceUntil(function()
			return b:isLoaded(q)
		end, 120, 0.25)).toBe(true)
		local retry = b:purchase(receipt)
		world:advanceUntil(function()
			return retry.done
		end, 30)
		expect(retry.result).toBe("PurchaseGranted")
		expect(b:section(q, "economy").currency.Coins).toBe(100)
		-- and once more: still exactly one grant
		local again = b:purchase(receipt)
		world:advanceUntil(function()
			return again.done
		end, 30)
		expect(again.result).toBe("PurchaseGranted")
		expect(b:section(q, "economy").currency.Coins).toBe(100)
		expect(#F.grants(b, q, "product:Coins100")).toBe(1)
	end)

	it("a granted receipt re-delivered on another server is acknowledged without a grant", function()
		local world, s = setup(1)
		local p = joinLoaded(world, s, 66)
		local receipt = F.receipt(66, "purchase-C", PRODUCT)
		local first = s:purchase(receipt)
		world:advanceUntil(function()
			return first.done
		end, 30)
		expect(first.result).toBe("PurchaseGranted")
		expect(s:heard("framework.ProductGranted"):count()).toBe(1)
		s:leave(p)
		world:advanceUntil(function()
			return F.lockHolder(world, 66) == nil
		end, 30)
		local b = nextServer(world)
		local q = joinLoaded(world, b, 66)
		local again = b:purchase(receipt)
		world:advanceUntil(function()
			return again.done
		end, 30)
		expect(again.result).toBe("PurchaseGranted")
		expect(b:section(q, "economy").currency.Coins).toBe(100)
		expect(b:heard("framework.ProductGranted"):count()).toBe(0)
	end)
end)
