--[[
	A save session stolen by another server (core-v1.3.0 step 4b-IIb, framework Store/Data).
	Real framework Data + real ProfileStore 1.0.3 (LIVE mode) on the shared mock DataStore.

	When ProfileStore reports that another server took the session, the old server must
	  1. kick the player at once with Server.KICK_SESSION_ENDED, and
	  2. never write that profile again: no autosave, no leave save, no BindToClose save, no late
	     tx.after effect and no Shop settle save,
	so the new server's data is never overwritten. Both ways ProfileStore reports it are covered:
	"External" (the new server asked over MessagingService) and a normal save that finds the lock
	gone (MessagingService down; the old server only learns at its next save).
]]

local F = require(script.Parent.Fixtures)

local KICK = "Your save data was opened in another server. Please rejoin." -- Server.KICK_SESSION_ENDED

local function withShop(s)
	s:onProduct("Coins100", function(tx)
		tx.use(s:ref("Economy")).grant(100)
	end)
	return s
end

local function joinLoaded(world, s, userId: number, within: number?)
	local p = s:join(userId)
	assert(
		world:advanceUntil(function()
			return s:isLoaded(p)
		end, within or 30, 0.25),
		"loaded"
	)
	return p
end

local function save(world, s, p)
	local h = s:spawn(function()
		return s:save(p)
	end)
	assert(
		world:advanceUntil(function()
			return h.done
		end, 40),
		"saveAsync returned"
	)
	assert(h.result == true, "saveAsync succeeded")
end

local function kicksOf(s, userId: number): { string }
	local out = {}
	for _, k in s.kicks do
		if k.userId == userId then
			table.insert(out, k.message or "")
		end
	end
	return out
end

-- Committed writes by `server` to the user's save at or after virtual time `since`.
local function writesBy(world, server, userId: number, since: number): { any }
	local out = {}
	for _, w in world.log do
		if w.store == F.STORE and w.key == F.key(userId) and w.writer == server.jobId and w.at >= since then
			table.insert(out, w)
		end
	end
	return out
end

local function dataChanged(w): boolean
	return not F.sameValue(w.before and w.before.Data, w.after and w.after.Data)
end

describe("stolen save session (multi-server)", function()
	it("lock found gone by an in-flight save: A kicks at once and never writes again", function()
		local world = F.world()
		world.messagingEnabled = false -- A never hears B's request; it learns at its next save
		local a = withShop(F.server(world))
		local p = joinLoaded(world, a, 81)
		a:use("Economy").grant(p, 10, "test")
		save(world, a, p)

		-- 1. B steals the session (after ProfileStore's SESSION_STEAL wait) and moves on.
		local b = withShop(F.server(world))
		local q = joinLoaded(world, b, 81, 100)
		local stolenAt = world.scheduler.now
		expect(F.lockHolder(world, 81)).toBe(b.jobId)
		b:use("Economy").grant(q, 5, "test")
		save(world, b, q)
		expect(F.section(world, 81, "economy").currency.Coins).toBe(15)

		-- 2. A still thinks it owns the profile: it changes its copy, then has an autosave-style
		--    save AND a Robux purchase (Shop settle save + tx.after effects) in flight together.
		world.latency = 2
		a:use("Economy").grant(p, 999, "test")
		expect(#kicksOf(a, 81)).toBe(0)
		local inflightAt = world.scheduler.now
		local inflight = a:spawn(a.save, a, p)
		local buy = a:purchase(F.receipt(81, "stolen-1"))

		-- 3. A kicks right away: as soon as that save sees the lock gone, within one save round trip.
		expect(world:advanceUntil(function()
			return #kicksOf(a, 81) > 0
		end, 15, 0.05)).toBe(true)
		expect(world.scheduler.now - inflightAt).toBeLessThan(10)
		local kicks = kicksOf(a, 81)
		expect(#kicks).toBe(1)
		expect(kicks[1]).toBe(KICK)
		expect(a:isLoaded(p)).toBe(false) -- the record is gone the moment the loss is seen

		-- 4. Every later save path on A writes nothing.
		expect(world:advanceUntil(function()
			return inflight.done and buy.done
		end, 60)).toBe(true)
		expect(inflight.result).toBe(false) -- the in-flight save is NOT reported as confirmed
		expect(buy.result).toBe("NotProcessedYet") -- Shop settle: no grant confirmed here
		expect(#F.grants(a, p, "product:Coins100")).toBe(0) -- its tx.after effects never ran
		expect(a:update(p, function(d)
			d.economy.currency.Coins = 123456
		end)).toBe(false)
		local late = a:spawn(a.save, a, p)
		world:advance(400, 0.5) -- past ProfileStore's AUTO_SAVE_PERIOD (300 s): no autosave either
		expect(late.done).toBe(true)
		expect(late.result).toBe(false)
		a:leave(p) -- leave save (already removed by the kick; must stay a no-op)
		local shutdown = a:shutdown() -- BindToClose save
		expect(world:advanceUntil(function()
			return shutdown.done
		end, 40)).toBe(true)
		for _, w in writesBy(world, a, 81, stolenAt) do
			expect(dataChanged(w)).toBe(false)
		end

		-- 5. B's data is never overwritten: A's 999, its purchase and its update never land.
		expect(F.section(world, 81, "economy").currency.Coins).toBe(15)
		expect(F.lockHolder(world, 81)).toBe(b.jobId)
		b:use("Economy").grant(q, 1, "test")
		save(world, b, q)
		expect(F.section(world, 81, "economy").currency.Coins).toBe(16)
		expect(#F.writerViolations(world, 81)).toBe(0)
		expect(#world:errors()).toBe(0)
	end)

	it('"External" (B asks over MessagingService): A kicks at once, later saves write nothing', function()
		local world = F.world()
		local a = withShop(F.server(world))
		local p = joinLoaded(world, a, 82)
		a:use("Economy").grant(p, 20, "test")
		save(world, a, p)

		-- an autosave-style save is in flight on A when B asks for the session
		world.latency = 1
		local inflight = a:spawn(a.save, a, p)
		local b = withShop(F.server(world))
		local askedAt = world.scheduler.now
		local q = b:join(82)
		expect(world:advanceUntil(function()
			return #kicksOf(a, 82) > 0
		end, 30, 0.05)).toBe(true)
		expect(world.scheduler.now - askedAt).toBeLessThan(10)
		local kicks = kicksOf(a, 82)
		expect(#kicks).toBe(1)
		expect(kicks[1]).toBe(KICK)
		expect(a:isLoaded(p)).toBe(false)
		local releasedAt = world.scheduler.now

		expect(world:advanceUntil(function()
			return b:isLoaded(q) and inflight.done
		end, 90, 0.25)).toBe(true)
		expect(b:section(q, "economy").currency.Coins).toBe(20)
		b:use("Economy").grant(q, 7, "test")
		save(world, b, q)

		-- every later path on A: update, saveAsync, purchase settle, autosave period, BindToClose
		expect(a:update(p, function(d)
			d.economy.currency.Coins = 999
		end)).toBe(false)
		local late = a:spawn(a.save, a, p)
		local buy = a:purchase(F.receipt(82, "external-1"))
		world:advance(400, 0.5)
		expect(late.result).toBe(false)
		expect(buy.done).toBe(true)
		expect(buy.result).toBe("NotProcessedYet")
		expect(#F.grants(a, p, "product:Coins100")).toBe(0)
		local shutdown = a:shutdown()
		expect(world:advanceUntil(function()
			return shutdown.done
		end, 40)).toBe(true)
		-- ProfileStore's own "External" release write happens as part of the hand-over, before
		-- B loads; after B owns the lock, nothing from A changes the save.
		for _, w in writesBy(world, a, 82, releasedAt + 5) do
			expect(dataChanged(w)).toBe(false)
		end
		expect(F.section(world, 82, "economy").currency.Coins).toBe(27)
		expect(F.lockHolder(world, 82)).toBe(b.jobId)
		expect(#F.writerViolations(world, 82)).toBe(0)
		expect(#world:errors()).toBe(0)
	end)
end)
