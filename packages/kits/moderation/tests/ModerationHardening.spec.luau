--!nocheck
--[[
	Moderation, Addendum G (after the final review and the first dogfood):
	  H2  audit reads are bounded: a day read = the day directory + at most audit.chunksPerRead chunk
	      keys (newest first, paged); a target read = a/u/<userId> only; the read cache is TTL-only and
	      this server's own entries come from memory
	  M   retention: entries older than retentionDays are never returned; the sweep follows a
	      persisted marker and catches days a short look-back would miss
	  L   flushes: appends made while an update yields are kept; one flush at a time
	  Dogfood: ladder steps may carry `key`, offences `warnKey` (validated at boot)
	  Fix 2: an absent-target punish is refused ("failed") when Admin.limitsOf errors, never sent uncapped
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local H = require("packages/kits/moderation/tests/ModerationHelpers.luau")

local DAY = 86400

-- two harnesses sharing one ctx.data.shared (the harness gives each its own memory backend)
local function link(b, a)
	local from = a.h.runtime.shared.backend
	local to = b.h.runtime.shared.backend
	to.values = from.values
	to.update = function(fullKey, transform)
		return from.update(fullKey, transform)
	end
end

-- counts the shared-store updates (reads are updates) whose key starts with "Moderation/a/"
local function counter(env)
	local backend = env.h.runtime.shared.backend
	local real = backend.update
	local c = { n = 0, keys = {} }
	backend.update = function(fullKey, transform)
		if string.sub(fullKey, 1, 13) == "Moderation/a/" then
			c.n += 1
			table.insert(c.keys, fullKey)
		end
		return real(fullKey, transform)
	end
	function c.reset()
		c.n = 0
		c.keys = {}
	end
	return c
end

describe("H2: bounded audit reads", function()
	it("a day read touches the directory plus chunksPerRead chunks, newest first, paged", function()
		local store = StudWork.test.memoryStore()
		local config = { audit = { chunkSize = 1, chunksPerRead = 4 } }
		local a = H.boot({ store = store, jobId = "server-a", config = config })
		local b = H.boot({ store = store, jobId = "server-b", config = config })
		link(b, a)
		for i = 1, 10 do
			a.h.clock += 1
			a.m.record({ action = "custom", note = "game.note" .. i }, { by = "server" })
		end
		a.h:tick(16)
		local day = a.h.clock // DAY
		expect(#a.shared()[`Moderation/a/{day}/d`]).toBe(10)
		b.h.clock = a.h.clock
		local c = counter(b)
		local ok, page1, more1 = b.m.audit({ by = "server", day = day, limit = 100 })
		expect(ok).toBe(true)
		expect(c.n).toBe(5) -- the directory + 4 chunks, not 11
		expect(#page1).toBe(4)
		expect(page1[1].note).toBe("game.note10") -- newest chunks first
		expect(more1).toBe(true)
		c.reset()
		local _, page2, more2 = b.m.audit({ by = "server", day = day, limit = 100, page = 2 })
		expect(c.n).toBe(5)
		expect(page2[1].note).toBe("game.note6")
		expect(more2).toBe(true)
		c.reset()
		local _, page3, more3 = b.m.audit({ by = "server", day = day, limit = 100, page = 3 })
		expect(c.n).toBe(3)
		expect(#page3).toBe(2)
		expect(more3).toBe(false)
	end)

	it("the read cache is TTL-only; this server's own new entries come from memory", function()
		local store = StudWork.test.memoryStore()
		local a = H.boot({ store = store, jobId = "server-a" })
		local b = H.boot({ store = store, jobId = "server-b" })
		link(b, a)
		a.m.record({ action = "custom", target = 9, note = "game.a" }, { by = "server" })
		a.h:tick(16)
		b.h.clock = a.h.clock
		local c = counter(b)
		local _, first = b.m.audit({ by = "server", limit = 50 })
		expect(#first).toBe(1)
		local reads = c.n
		expect(reads > 0).toBe(true)
		-- a new entry here doesn't clear the cache: no store read, and the entry is shown from memory
		b.m.record({ action = "custom", target = 9, note = "game.b" }, { by = "server" })
		local _, second = b.m.audit({ by = "server", limit = 50 })
		expect(c.n).toBe(reads)
		expect(#second).toBe(2)
		expect(second[1].note).toBe("game.b")
		-- still shown after it was flushed (memory), still no store read inside readCacheSeconds
		b.h:tick(16)
		c.reset()
		local _, third = b.m.audit({ by = "server", limit = 50 })
		expect(c.n).toBe(0)
		expect(#third).toBe(2)
	end)

	it("a target read touches only a/u/<userId>", function()
		local env = H.boot({ config = { audit = { chunkSize = 1 } } })
		for i = 1, 6 do
			env.m.record({ action = "custom", target = 9, note = "game.n" .. i }, { by = "server" })
		end
		env.h:tick(16)
		local c = counter(env)
		local ok, list = env.m.audit({ by = "server", target = 9, limit = 50 })
		expect(ok).toBe(true)
		expect(#list).toBe(6)
		expect(c.keys).toEqual({ "Moderation/a/u/9" })
	end)

	it("the Audit tab reads the store at most once per request", function()
		local admin = H.fakeAdmin({ ranks = { [10] = 200 }, perms = { [10] = { ["audit.read"] = true } } })
		local store = StudWork.test.memoryStore()
		local config = { audit = { chunkSize = 2, chunksPerRead = 2 }, panel = { auditPageSize = 3 } }
		local a = H.boot({ store = store, jobId = "server-a", config = config })
		local b = H.boot({ store = store, jobId = "server-b", config = config, admin = admin })
		link(b, a)
		for i = 1, 12 do
			a.h.clock += 1
			a.m.record({ action = "custom", note = "game.note" .. i }, { by = "server" })
		end
		a.h:tick(16)
		b.h.clock = a.h.clock
		local staff = b.add(10)
		local tab = admin.registered.tabs.audit
		local c = counter(b)
		local rows1 = tab.fetch(staff, 1).rows
		expect(#rows1).toBe(3)
		expect(c.n).toBe(3) -- the directory + 2 chunks
		-- page 2 is inside the first chunk page (4 entries): from the cache
		c.reset()
		local rows2 = tab.fetch(staff, 2).rows
		expect(#rows2).toBe(1)
		expect(c.n).toBe(0)
		-- page 3 needs the second chunk page: one more read (after readSecondsPerStaff), and only
		-- one: the rows a third chunk page would add wait for the next request
		b.h:tick(5)
		c.reset()
		local rows3 = tab.fetch(staff, 3).rows
		expect(c.n).toBe(3)
		expect(#rows3).toBe(2)
	end)

	it("the Audit tab reads once per request even with no per-staff read throttle", function()
		local admin = H.fakeAdmin({ ranks = { [10] = 200 }, perms = { [10] = { ["audit.read"] = true } } })
		local store = StudWork.test.memoryStore()
		local config = {
			audit = { chunkSize = 2, chunksPerRead = 2, readSecondsPerStaff = 0 },
			panel = { auditPageSize = 3 },
		}
		local a = H.boot({ store = store, jobId = "server-a", config = config })
		local b = H.boot({ store = store, jobId = "server-b", config = config, admin = admin })
		link(b, a)
		for i = 1, 12 do
			a.h.clock += 1
			a.m.record({ action = "custom", note = "game.note" .. i }, { by = "server" })
		end
		a.h:tick(16)
		b.h.clock = a.h.clock
		local staff = b.add(10)
		local tab = admin.registered.tabs.audit
		local c = counter(b)
		-- page 3 wants 9 rows: chunk pages 1 and 2 (8 entries) would need a third; only one store
		-- page is read per request (the directory + 2 chunks), the rest waits for the next request
		local rows3 = tab.fetch(staff, 3).rows
		expect(c.n).toBe(3)
		expect(#rows3).toBe(0)
	end)
end)

describe("retention", function()
	it("entries older than retentionDays are never returned (the per-target view included)", function()
		local env = H.boot({ config = { audit = { retentionDays = 30 } } })
		env.m.record({ action = "custom", target = 4 }, { by = "server" })
		env.h:tick(16)
		expect(#env.audit({ target = 4 })).toBe(1)
		env.h.clock += 31 * DAY
		env.h:tick(1)
		expect(#env.audit({ target = 4 })).toBe(0)
		expect(#env.shared()["Moderation/a/u/4"]).toBe(1) -- untouched in the store, hidden on read
	end)

	it("the sweep follows a persisted marker: a day missed by a short look-back is still deleted", function()
		local env = H.boot({ config = { audit = { retentionDays = 2 } } })
		local day = env.h.clock // DAY
		env.m.record({ action = "custom", target = 4 }, { by = "server" })
		env.h:tick(16) -- the start-up sweep (marks the expired days before `day`)
		expect(env.shared()[`Moderation/a/{day}/d`]).never.toBe(nil)
		-- no sweep for 8 days: `day` is now 6 days past retention
		env.h.clock += 8 * DAY
		env.h:tick(16)
		local s = env.shared()
		expect(s[`Moderation/a/{day}/d`]).toBe(nil)
		expect(s[`Moderation/a/{day}/server-a/1`]).toBe(nil)
		expect(s["Moderation/a/s"].day).toBe(day + 8 - 2 - 1)
	end)

	it("a/u/<userId> drops entries older than retentionDays on every write", function()
		local env = H.boot({ config = { audit = { retentionDays = 30 } } })
		env.m.record({ action = "custom", target = 4, note = "game.old" }, { by = "server" })
		env.h:tick(16)
		expect(#env.shared()["Moderation/a/u/4"]).toBe(1)
		env.h.clock += 31 * DAY
		env.m.record({ action = "custom", target = 4, note = "game.new" }, { by = "server" })
		env.h:tick(16)
		local list = env.shared()["Moderation/a/u/4"]
		expect(#list).toBe(1)
		expect(list[1].note).toBe("game.new")
	end)

	it("a sweep after the marker reads only the days that expired since", function()
		local env = H.boot({ config = { audit = { retentionDays = 2 } } })
		env.h:tick(16) -- the start-up sweep: every expired day up to the marker
		expect(env.shared()["Moderation/a/s"]).never.toBe(nil)
		local before = env.h.clock // DAY
		local c = counter(env)
		env.h.clock += 7 * 3600 -- the next sweep (6 h cadence); without the marker it re-reads 9 days
		env.h:tick(16)
		task.wait(0.05)
		local dirReads = 0
		for _, k in c.keys do
			if string.sub(k, -2) == "/d" then
				dirReads += 1
			end
		end
		expect(dirReads).toBe(env.h.clock // DAY - before)
	end)
end)

describe("flushes", function()
	it("an index append made while its update yields is kept for the next flush", function()
		local env = H.boot()
		env.m.record({ action = "custom", target = 9, note = "game.first" }, { by = "server" })
		local backend = env.h.runtime.shared.backend
		local real = backend.update
		local injected = false
		backend.update = function(fullKey, transform)
			local result = real(fullKey, transform)
			if fullKey == "Moderation/a/u/9" and not injected then
				injected = true
				env.m.record({ action = "custom", target = 9, note = "game.second" }, { by = "server" })
			end
			return result
		end
		env.h:tick(16)
		expect(injected).toBe(true)
		env.h:tick(16)
		local list = env.shared()["Moderation/a/u/9"]
		expect(#list).toBe(2)
		expect(list[2].note).toBe("game.second")
	end)

	it("one flush at a time: a second flush waits for the running one", function()
		local env = H.boot()
		local audit = env.part.debug().audit
		env.m.record({ action = "custom", target = 9 }, { by = "server" })
		local backend = env.h.runtime.shared.backend
		local real = backend.update
		local depth, maxDepth, nested = 0, 0, false
		backend.update = function(fullKey, transform)
			depth += 1
			maxDepth = math.max(maxDepth, depth)
			if not nested and string.find(fullKey, "Moderation/a/", 1, true) then
				nested = true
				env.m.record({ action = "custom", target = 9 }, { by = "server" })
				task.spawn(audit.flush) -- e.g. the shutdown flush during a tick flush
			end
			local result = real(fullKey, transform)
			depth -= 1
			return result
		end
		env.h:tick(16)
		task.wait(0.2) -- the waiting flush runs once the first is done
		expect(nested).toBe(true)
		expect(maxDepth).toBe(1)
		expect(audit.buffered()).toBe(0)
		expect(#env.shared()["Moderation/a/u/9"]).toBe(2)
	end)
end)

describe("ladder message keys (dogfood)", function()
	it("a step's key, then the offence's warnKey, then warn.presetKeys[1]", function()
		local env = H.boot({
			config = {
				ladders = {
					default = {
						{ action = "warn", key = "Moderation.warn.language" },
						{ action = "warn" },
					},
				},
				offenses = {
					rules = { ladder = "default", displayKey = "Moderation.ban.rules" },
					cheating = {
						ladder = "default",
						displayKey = "Moderation.ban.cheating",
						warnKey = "Moderation.warn.cheating",
					},
				},
			},
		})
		local p = env.add(2)
		expect(env.m.punish(p, "rules", { by = "server" })).toBe(true)
		expect(env.m.punish(p, "rules", { by = "server" })).toBe(true)
		expect(env.m.punish(p, "cheating", { by = "server" })).toBe(true)
		expect(env.m.punish(p, "cheating", { by = "server" })).toBe(true)
		local keys = {}
		for _, n in env.notices do
			table.insert(keys, n.key)
		end
		expect(keys).toEqual({
			"Moderation.warn.language",
			"Moderation.warn.rules",
			"Moderation.warn.language",
			"Moderation.warn.cheating",
		})
	end)

	it("a key that isn't one of the action's presets fails boot", function()
		expect(H.raises(function()
			H.boot({
				config = { ladders = { default = { { action = "warn", key = "Moderation.ban.rules" } } } },
			})
		end, "ladders.default[1].key")).toBe(true)
		expect(H.raises(function()
			H.boot({
				config = {
					offenses = { rules = { ladder = "default", warnKey = "Moderation.mute.generic" } },
				},
			})
		end, "offenses.rules.warnKey")).toBe(true)
	end)
end)

describe("fix 2: role caps on an absent-target punish fail closed", function()
	it("Admin.limitsOf erroring refuses the punish ('failed', audited); nothing is sent", function()
		local admin = H.fakeAdmin({ ranks = { [10] = 200 }, perms = { [10] = { ["*"] = true } } })
		local broken = true
		local realLimits = admin.api.limitsOf
		admin.api.limitsOf = function(p)
			if broken then
				error("limits unavailable")
			end
			return realLimits(p)
		end
		local store = StudWork.test.memoryStore()
		local a = H.boot({ admin = admin, store = store, jobId = "server-a" })
		local b = H.boot({ store = store, jobId = "server-b" })
		local staff = a.add(10)
		expect(select(2, a.m.punish(2, "rules", { by = staff }))).toBe("failed")
		a.h:tick(16)
		local refused = H.find(a.audit({ target = 2 }), function(e)
			return e.status == "refused"
		end)
		expect(#refused).toBe(1)
		expect(refused[1].by).toBe(10)
		-- nothing was delivered: the target joins elsewhere with no strike
		local p = b.add(2)
		b.h:tick(2)
		expect(#b.notices).toBe(0)
		b.h:removePlayer(p)
		local saved = b.h:saved(p).moderation
		expect(saved == nil or #saved.strikes == 0).toBe(true)
		-- with Admin answering again the same punish is sent
		broken = false
		expect(select(2, a.m.punish(3, "rules", { by = staff }))).toBe("sent")
	end)
end)
