--[[
	Cross-server gifting through Core.Mail against the real v1.2 code (Inventory.sendGift,
	Mail.pending/claim, Mail.sendInto outbox). Written by agent C against the contract while
	agent A built it; enabled by the lead after merging A (it was gifting_crossserver.pending.luau).
]]

local F = require(script.Parent.Fixtures)

local function joinLoaded(world, s, userId: number)
	local p = s:join(userId)
	assert(
		world:advanceUntil(function()
			return s:isLoaded(p)
		end, 30),
		"loaded " .. userId
	)
	return p
end

local function released(world, userId: number)
	return world:advanceUntil(function()
		return F.lockHolder(world, userId) == nil
	end, 60)
end

-- sendGift that refuses to be quiet about the v1.2 stubs.
local function gift(s, from, toUserId: number, uid: string)
	local ok, result, why = pcall(s.services.Inventory.sendGift, from, toUserId, uid, "gift")
	if not ok then
		error("PENDING: Inventory.sendGift raised (" .. tostring(result) .. "). Merge agent A first.", 2)
	end
	if result ~= true and why == "failed" then
		error(
			"PENDING: Inventory.sendGift returned (false, 'failed') - this is the core-contract-v1.2 "
				.. "stub. Run this file only after agent A's mail/gifting branch is merged.",
			2
		)
	end
	return result, why
end

local function hasUid(data, uid: string): boolean
	return data ~= nil and data.inventory ~= nil and data.inventory[uid] ~= nil
end

describe("cross-server gifting through Mail (PENDING agent A)", function()
	it(
		"gift to an OFFLINE user: leaves the sender at once, arrives on the receiver's next join elsewhere",
		function()
			local world = F.world()
			local a = F.server(world)
			local sender = joinLoaded(world, a, 81)
			local item =
				a.services.Inventory.add(sender, "gem", { source = "drop", meta = { note = "for you" } })
			local ok, why = gift(a, sender, 82, item.uid)
			expect(ok).toBe(true)
			expect(why).toBeNil()
			expect(a.services.Inventory.get(sender, item.uid)).toBeNil()
			world:advance(10)
			a:leave(sender)
			expect(released(world, 81)).toBe(true)
			expect(hasUid(F.stored(world, 81), item.uid)).toBe(false)
			local outbox = F.stored(world, 81).mail.outbox
			expect(outbox == nil or next(outbox) == nil).toBe(true) -- sent, nothing left to retry

			local b = F.server(world)
			local receiver = joinLoaded(world, b, 82)
			expect(world:advanceUntil(function()
				return b.services.Inventory.get(receiver, item.uid) ~= nil
			end, 30)).toBe(true)
			local got = b.services.Inventory.get(receiver, item.uid)
			expect(got.itemId).toBe("gem")
			expect(got.source).toBe("drop")
			expect(got.meta.note).toBe("for you")
			expect(#world:errors()).toBe(0)
		end
	)

	it("gift to a user ONLINE in another server arrives without a rejoin", function()
		local world = F.world()
		local a, b = F.server(world), F.server(world)
		local sender = joinLoaded(world, a, 83)
		local receiver = joinLoaded(world, b, 84)
		local item = a.services.Inventory.add(sender, "rock", { source = "drop" })
		expect((gift(a, sender, 84, item.uid))).toBe(true)
		expect(world:advanceUntil(function()
			return b.services.Inventory.get(receiver, item.uid) ~= nil
		end, 400, 0.25)).toBe(true)
		expect(a.services.Inventory.get(sender, item.uid)).toBeNil()
	end)

	it("receiver's inventory full -> mailbox -> claim after freeing a slot", function()
		local world = F.world()
		local a, b = F.server(world), F.server(world)
		local Inventory, Mail = b.services.Inventory, b.services.Mail
		-- fill the receiver to the cap (3) in an earlier session, so the gift finds it full on
		-- the next load (queued messages are delivered right after load)
		local first = joinLoaded(world, b, 86)
		for _ = 1, 3 do
			Inventory.add(first, "dust", { source = "drop" })
		end
		b:leave(first)
		expect(released(world, 86)).toBe(true)

		local sender = joinLoaded(world, a, 85)
		local item = a.services.Inventory.add(sender, "gem", { source = "drop" })
		expect((gift(a, sender, 86, item.uid))).toBe(true)
		world:advance(5)

		local receiver = joinLoaded(world, b, 86)
		expect(world:advanceUntil(function()
			return #Mail.pending(receiver) == 1
		end, 400, 0.25)).toBe(true)
		local entry = Mail.pending(receiver)[1]
		expect(entry.kind).toBe("core_gift")
		expect(hasUid(b:data(receiver), item.uid)).toBe(false)

		local stillFull, reason = Mail.claim(receiver, entry.id)
		expect(stillFull).toBe(false)
		expect(reason).toBe("still_held")

		local dust = Inventory.list(receiver)[1]
		Inventory.remove(receiver, dust.uid)
		local claimed, why = Mail.claim(receiver, entry.id)
		expect(claimed).toBe(true)
		expect(why).toBeNil()
		expect(Inventory.get(receiver, item.uid).itemId).toBe("gem")
		expect(#Mail.pending(receiver)).toBe(0)
		local again, notFound = Mail.claim(receiver, entry.id)
		expect(again).toBe(false)
		expect(notFound).toBe("not_found")

		-- the claimed entry is gone from the SAVED mailbox too (PlayerData.mail.box)
		b:leave(receiver)
		expect(released(world, 86)).toBe(true)
		expect(next(F.stored(world, 86).mail.box or {})).toBeNil()
	end)

	it("the sender's server crashes right after the gift: the outbox is resent once on rejoin", function()
		local world = F.world()
		world.latency = 2
		local a = F.server(world)
		local sender = joinLoaded(world, a, 87)
		local item = a.services.Inventory.add(sender, "gem", { source = "drop" })
		local h = a:spawn(function()
			return a.services.Data.saveAsync(sender)
		end)
		world:advanceUntil(function()
			return h.done
		end, 30)
		expect((gift(a, sender, 88, item.uid))).toBe(true)
		world:advance(0.5)
		a:crash()

		local b = F.server(world)
		local again = b:join(87)
		world:advanceUntil(function()
			return b:isLoaded(again)
		end, 120, 0.25)
		local receiverOk = 0
		local c = F.server(world)
		local receiver = joinLoaded(world, c, 88)
		world:advance(400, 0.25)
		for _, inst in c.services.Inventory.list(receiver) do
			if inst.uid == item.uid then
				receiverOk += 1
			end
		end
		local senderHas = b.services.Inventory.get(again, item.uid) ~= nil
		-- exactly one copy in the world
		expect(receiverOk + (if senderHas then 1 else 0)).toBe(1)
	end)

	it("rejects restricted paid sources, self gifts and bad targets", function()
		local world = F.world()
		local a = F.server(world)
		local sender = joinLoaded(world, a, 89)
		local paid = a.services.Inventory.add(sender, "egg", { source = "paid:Egg" })
		local ok, why = a.services.Inventory.sendGift(sender, 90, paid.uid, "gift")
		expect(ok).toBe(false)
		expect(why).toBe("restricted_source")
		local free = a.services.Inventory.add(sender, "rock", { source = "drop" })
		ok, why = a.services.Inventory.sendGift(sender, 89, free.uid, "gift")
		expect(why).toBe("same_player")
		ok, why = a.services.Inventory.sendGift(sender, -5, free.uid, "gift")
		expect(why).toBe("bad_target")
		ok, why = a.services.Inventory.sendGift(sender, 90, "no-such-uid", "gift")
		expect(why).toBe("not_owned")
		expect(a.services.Inventory.get(sender, free.uid)).never.toBeNil()
		expect(a.services.Inventory.get(sender, paid.uid)).never.toBeNil()
	end)
end)
