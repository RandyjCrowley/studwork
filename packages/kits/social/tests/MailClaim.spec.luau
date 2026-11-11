--!nocheck
--[[
	Mail's client action claimMail (core-v1.3.1 R19: the module's own net.blink event ClaimMail,
	replacing the framework's RequestMailClaim). The REAL Mail module in the multi-server sim
	(Mail needs HttpService/MessagingService, which the plain harness doesn't fake), driven
	through the runtime's action path (`server.runtime.action`, what h:action calls; Lune has no
	Blink wire): bad ids are ignored, a held gift stays held with the "No room yet" toast, a
	claimable one is delivered once, and the moved 2/s burst 5 limit applies.
]]
local F = require("packages/framework/test/sim/Fixtures.luau")

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

local function claim(s, player, ...)
	return s.runtime.action(player, s:ref("Mail"), "claimMail", ...)
end

local NO_ROOM = "No room yet: free some space and try again"
local FAILED = "Couldn't claim that right now"

-- the claim action's own toasts (other Mail notices, e.g. "held in your mailbox", are not counted)
local function toasts(s, player): { string }
	local out = {}
	for _, f in s.feedback do
		if f.player == player and f.kind == "toast" and (f.text == NO_ROOM or f.text == FAILED) then
			table.insert(out, f.text)
		end
	end
	return out
end

describe("Mail.claimMail (module action, net.blink ClaimMail)", function()
	it("is declared by the Mail server part with the moved limit (2/s burst 5)", function()
		local world = F.world()
		local s = F.server(world)
		expect(s.runtime.net.hasAction("Mail", "claimMail")).toBe(true)
		local p = joinLoaded(world, s, 71)
		for _ = 1, 5 do
			expect((claim(s, p, "nope"))).toBe(true)
		end
		local ok, reason = claim(s, p, "nope")
		expect(ok).toBe(false)
		expect(reason).toBe("rate_limited")
	end)

	it("bad ids (wrong type, empty, too long, unknown) are ignored without a toast", function()
		local world = F.world()
		local s = F.server(world)
		local p = joinLoaded(world, s, 72)
		for _, bad in { 42, "", string.rep("x", 65), "unknown-id" } do
			expect((claim(s, p, bad))).toBe(true)
			world:advance(1)
		end
		expect(#toasts(s, p)).toBe(0)
		expect(#s:use("Mail").pending(p)).toBe(0)
	end)

	it("held gift: claim refused with a toast and kept; after freeing a slot: delivered once", function()
		local world = F.world()
		local a, b = F.server(world), F.server(world)
		local Inventory, Mail = b:use("Inventory"), b:use("Mail")
		local first = joinLoaded(world, b, 76)
		for _ = 1, 3 do
			Inventory.add(first, "dust", { source = "drop" })
		end
		b:leave(first)
		expect(released(world, 76)).toBe(true)

		local sender = joinLoaded(world, a, 75)
		local item = a:use("Inventory").add(sender, "gem", { source = "drop" })
		expect((a:use("Inventory").sendGift(sender, 76, item.uid, "gift"))).toBe(true)
		world:advance(5)

		local receiver = joinLoaded(world, b, 76)
		expect(world:advanceUntil(function()
			return #Mail.pending(receiver) == 1
		end, 400, 0.25)).toBe(true)
		local entry = Mail.pending(receiver)[1]

		expect((claim(b, receiver, entry.id))).toBe(true)
		expect(#Mail.pending(receiver)).toBe(1)
		local t = toasts(b, receiver)
		expect(#t).toBe(1)
		expect(t[1]).toBe(NO_ROOM)

		Inventory.remove(receiver, Inventory.list(receiver)[1].uid)
		world:advance(1)
		expect((claim(b, receiver, entry.id))).toBe(true)
		expect(Inventory.get(receiver, item.uid).itemId).toBe("gem")
		expect(#Mail.pending(receiver)).toBe(0)
		expect((claim(b, receiver, entry.id))).toBe(true) -- already claimed: a no-op
		expect(#toasts(b, receiver)).toBe(1)
		expect(#world:errors()).toBe(0)
	end)
end)
