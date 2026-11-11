--[[
	Two-player gifting in one server (known-issues: "Gifting between two players").
	Real Data + Inventory (transfer and the RequestGift remote handler) + Items; Policy is a
	fake driven by world.restricted (PolicyService "paid random items restricted").
]]

local F = require(script.Parent.Fixtures)

local function setup(userA: number, userB: number)
	local world = F.world()
	local s = F.server(world)
	local a = s:join(userA)
	local b = s:join(userB)
	assert(
		world:advanceUntil(function()
			return s:isLoaded(a) and s:isLoaded(b)
		end, 30),
		"both loaded"
	)
	return world, s, a, b
end

describe("two-player gifting in one server (Inventory.transfer)", function()
	it("moves the exact instance and ownership, and both saves agree after leaving", function()
		local world, s, a, b = setup(21, 22)
		local Inventory = s:use("Inventory")
		local item = Inventory.add(a, "gem", { source = "drop", meta = { note = "hi" } })
		local ok, why = Inventory.transfer(a, b, item.uid, "gift")
		expect(ok).toBe(true)
		expect(why).toBeNil()
		expect(Inventory.get(a, item.uid)).toBeNil()
		local got = Inventory.get(b, item.uid)
		expect(got.itemId).toBe("gem")
		expect(got.meta.note).toBe("hi")
		expect(got.source).toBe("drop")
		-- signals fired once each
		expect(s:heard("Inventory.ItemRemoved"):count()).toBe(1)
		expect(s:heard("Inventory.ItemAdded"):count()).toBe(2) -- the add + the transfer
		-- a second transfer of the same uid fails: it is no longer owned
		local again, reason = Inventory.transfer(a, b, item.uid, "gift")
		expect(again).toBe(false)
		expect(reason).toBe("not_owned")

		s:leave(a)
		s:leave(b)
		world:advanceUntil(function()
			return F.lockHolder(world, 21) == nil and F.lockHolder(world, 22) == nil
		end, 30)
		expect(F.section(world, 21, "inventory").inventory[item.uid]).toBeNil()
		expect(F.section(world, 22, "inventory").inventory[item.uid].itemId).toBe("gem")
		expect(#world:errors()).toBe(0)
	end)

	it("refuses paid-source copies when either side is policy-restricted, allows otherwise", function()
		local world, s, a, b = setup(23, 24)
		local Inventory = s:use("Inventory")
		local paid = F.buyItem(world, s, a, "Egg", "egg") -- a real purchase: source "paid:Egg"
		expect(paid.source).toBe("paid:Egg")
		world.restricted[24] = true
		local ok, why = Inventory.transfer(a, b, paid.uid, "gift")
		expect(ok).toBe(false)
		expect(why).toBe("restricted")
		expect(Inventory.get(a, paid.uid)).never.toBeNil()

		world.restricted[24] = nil
		world.restricted[23] = true -- sender restricted counts too
		ok, why = Inventory.transfer(a, b, paid.uid, "gift")
		expect(why).toBe("restricted")

		-- a non-paid copy is fine even for restricted players
		local free = Inventory.add(a, "rock", { source = "drop" })
		ok = Inventory.transfer(a, b, free.uid, "gift")
		expect(ok).toBe(true)

		world.restricted[23] = nil
		ok = Inventory.transfer(a, b, paid.uid, "gift")
		expect(ok).toBe(true)
	end)

	it("refuses when the receiver's inventory is full (cap 3) and keeps the item", function()
		local _, s, a, b = setup(25, 26)
		local Inventory = s:use("Inventory")
		for _ = 1, 3 do
			expect(Inventory.add(b, "dust", { source = "drop" })).never.toBeNil()
		end
		local item = Inventory.add(a, "gem", { source = "drop" })
		local ok, why = Inventory.transfer(a, b, item.uid, "gift")
		expect(ok).toBe(false)
		expect(why).toBe("inventory_full")
		expect(Inventory.get(a, item.uid)).never.toBeNil()
		expect(Inventory.count(b)).toBe(3)
	end)

	it("refuses gifts to self and to a player that already left", function()
		local world, s, a, b = setup(27, 28)
		local Inventory = s:use("Inventory")
		local item = Inventory.add(a, "gem", { source = "drop" })
		local ok, why = Inventory.transfer(a, a, item.uid, "gift")
		expect(ok).toBe(false)
		expect(why).toBe("same_player")
		s:leave(b)
		world:advance(0.1)
		ok, why = Inventory.transfer(a, b, item.uid, "gift")
		expect(ok).toBe(false)
		expect(why).toBe("not_loaded")
		expect(Inventory.get(a, item.uid)).never.toBeNil()
	end)

	it("RequestGift remote: validates arguments and applies the per-sender cooldown", function()
		local world, s, a, b = setup(29, 30)
		local Inventory = s:use("Inventory")
		local one = Inventory.add(a, "rock", { source = "drop" })
		local two = Inventory.add(a, "dust", { source = "drop" })

		-- garbage from the client is ignored without errors
		s:remote("RequestGift", a, "30", one.uid)
		s:remote("RequestGift", a, 30, { one.uid })
		s:remote("RequestGift", a, 29, one.uid) -- self
		s:remote("RequestGift", a, 31337, one.uid) -- not in server
		s:remote("RequestGift", b, 29, one.uid) -- b does not own it
		world:advance(0.1)
		expect(Inventory.get(a, one.uid)).never.toBeNil()

		s:remote("RequestGift", a, 30, one.uid)
		s:remote("RequestGift", a, 30, two.uid) -- within the cooldown: dropped
		world:advance(0.1)
		expect(Inventory.get(b, one.uid)).never.toBeNil()
		expect(Inventory.get(a, two.uid)).never.toBeNil()

		world:advance(2.5)
		s:remote("RequestGift", a, 30, two.uid)
		world:advance(0.1)
		expect(Inventory.get(b, two.uid)).never.toBeNil()
		expect(#world:errors()).toBe(0)
	end)
end)
