--[[
	Session locks across servers (known-issues: "Real DataStore behaviour ... ProfileStore runs in
	Mock mode"). Real Data + real ProfileStore 1.0.3 in LIVE mode (not its Mock) on the shared
	mock DataStore + MessagingService. ProfileStore rules exercised: a waiting server asks the
	holder to release (MessagingService), steals after SESSION_STEAL (40 s) when the holder does
	not answer, takes over at once when the lock is older than ASSUME_DEAD (630 s); a server that
	lost its lock ends the session on its next save and never writes Data again.
]]

local F = require(script.Parent.Fixtures)

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

local function save(world, s, p)
	local h = s:spawn(function()
		return s.services.Data.saveAsync(p)
	end)
	assert(
		world:advanceUntil(function()
			return h.done
		end, 40),
		"saveAsync returned"
	)
	assert(h.result == true, "saveAsync succeeded")
end

local function kickedWith(s, userId: number, text: string): boolean
	for _, k in s.kicks do
		if k.userId == userId and k.message and string.find(k.message, text, 1, true) then
			return true
		end
	end
	return false
end

describe("session lock held by another server", function()
	it("crashed holder: the new server waits, steals after ~40 s and loads the SAVED data", function()
		local world = F.world()
		local a = F.server(world)
		local p = joinLoaded(world, a, 71)
		a.services.Economy.grant(p, 300, "test")
		save(world, a, p)
		a:crash() -- lock stays in the store, nobody answers MessagingService

		local b = F.server(world)
		local start = world.scheduler.now
		local q = b:join(71)
		world:advance(20, 0.25)
		expect(b:isLoaded(q)).toBe(false) -- still waiting: never default data meanwhile
		expect(#b.signals.DataLoaded.history).toBe(0)
		expect(world:advanceUntil(function()
			return b:isLoaded(q)
		end, 100, 0.25)).toBe(true)
		local waited = world.scheduler.now - start
		expect(waited).toBeGreaterThanOrEqual(35)
		expect(waited).toBeLessThan(120)
		expect(b:data(q).currency.Coins).toBe(300)
		expect(b:data(q).stats.sessions).toBe(2)
		expect(F.lockHolder(world, 71)).toBe(b.jobId)
		expect(#F.writerViolations(world, 71)).toBe(0)
		expect(#world:errors()).toBe(0)
	end)

	it("lock older than ASSUME_DEAD (630 s): taken over at once", function()
		local world = F.world()
		local a = F.server(world)
		local p = joinLoaded(world, a, 72)
		a.services.Economy.grant(p, 40, "test")
		save(world, a, p)
		a:crash()
		world:advance(700, 5)
		local b = F.server(world)
		local start = world.scheduler.now
		local q = b:join(72)
		expect(world:advanceUntil(function()
			return b:isLoaded(q)
		end, 10)).toBe(true)
		expect(world.scheduler.now - start).toBeLessThan(2)
		expect(b:data(q).currency.Coins).toBe(40)
	end)

	it("holder alive but MessagingService down: steal, old server stops writing and kicks", function()
		local world = F.world()
		world.messagingEnabled = false
		local a = F.server(world)
		local p = joinLoaded(world, a, 73)
		a.services.Economy.grant(p, 10, "test")
		save(world, a, p)

		local b = F.server(world)
		local q = b:join(73)
		expect(world:advanceUntil(function()
			return b:isLoaded(q)
		end, 100, 0.25)).toBe(true)
		expect(b:data(q).currency.Coins).toBe(10)
		-- A still thinks it owns the profile and keeps changing its copy...
		a.services.Economy.grant(p, 999, "test")
		b.services.Economy.grant(q, 5, "test")
		-- ...until its next autosave (ProfileStore AUTO_SAVE_PERIOD = 300 s) finds the lock gone.
		expect(world:advanceUntil(function()
			return not a:isLoaded(p)
		end, 400, 0.5)).toBe(true)
		-- ProfileStore ends a session it finds stolen during a normal save with OnSessionEnd but
		-- WITHOUT OnLastSave("External"); the framework treats that as a lost session too and
		-- kicks at once (core-v1.3.0 step 4b-IIb closed the old no-kick gap). Safety below.
		expect(kickedWith(a, 73, "another server")).toBe(true)
		expect(a.services.Data.update(p, function() end)).toBe(false)
		save(world, b, q)
		expect(F.stored(world, 73).currency.Coins).toBe(15) -- A's 999 never landed
		expect(F.lockHolder(world, 73)).toBe(b.jobId)
		expect(#F.writerViolations(world, 73)).toBe(0)
	end)

	it("DataStore outage at load: waits it out and loads the real profile, not defaults", function()
		local world = F.world()
		local a = F.server(world)
		local p = joinLoaded(world, a, 74)
		a.services.Economy.grant(p, 77, "test")
		a:leave(p)
		world:advanceUntil(function()
			return F.lockHolder(world, 74) == nil
		end, 30)

		world:failFor(25)
		local b = F.server(world)
		local q = b:join(74)
		expect(world:advanceUntil(function()
			return b:isLoaded(q)
		end, 100, 0.25)).toBe(true)
		expect(world.scheduler.now).toBeGreaterThan(25)
		expect(b:data(q).currency.Coins).toBe(77)
	end)

	it("long outage: never loads defaults, keeps retrying; leaving cancels without a write", function()
		-- Data passes a Cancel callback to StartSessionAsync, which disables ProfileStore's
		-- START_SESSION_TIMEOUT: the player waits (no kick) for as long as they stay.
		local world = F.world()
		local a = F.server(world)
		local p = joinLoaded(world, a, 75)
		a.services.Economy.grant(p, 55, "test")
		a:leave(p)
		world:advanceUntil(function()
			return F.lockHolder(world, 75) == nil
		end, 30)
		local before = F.stored(world, 75)

		world:failFor(400)
		local b = F.server(world)
		local q = b:join(75)
		world:advance(300, 0.5)
		expect(b:isLoaded(q)).toBe(false)
		expect(#b.signals.DataLoaded.history).toBe(0)
		expect(#b.kicks).toBe(0)
		b:leave(q)
		world:advance(200, 0.5) -- outage over; the cancelled load must not take the lock
		expect(F.lockHolder(world, 75)).toBeNil()
		expect(F.sameValue(F.stored(world, 75), before)).toBe(true)
		expect(#world:errors()).toBe(0)
	end)

	it("data saved by NEWER code: kicked with a rejoin message, nothing overwritten", function()
		local world = F.world()
		local a = F.server(world)
		local p = joinLoaded(world, a, 76)
		a.services.Economy.grant(p, 66, "test")
		a:leave(p)
		world:advanceUntil(function()
			return F.lockHolder(world, 76) == nil
		end, 30)
		local raw = world:peek(F.STORE, F.key(76))
		raw.Data._framework.schemaVersion = 99 -- v1.3: the framework section's version (§6)
		world:seed(F.STORE, F.key(76), raw)

		local b = F.server(world)
		local q = b:join(76)
		expect(world:advanceUntil(function()
			return q.Parent == nil
		end, 30)).toBe(true)
		expect(#b.kicks).toBe(1)
		expect(#b.signals.DataLoaded.history).toBe(0)
		world:advanceUntil(function()
			return F.lockHolder(world, 76) == nil
		end, 30)
		local stored = F.stored(world, 76)
		expect(stored.schemaVersion).toBe(99)
		expect(stored.currency.Coins).toBe(66)
		expect(F.sameValue(F.storedRaw(world, 76), raw.Data)).toBe(true)
	end)
end)
