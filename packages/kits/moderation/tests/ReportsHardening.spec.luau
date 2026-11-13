--!nocheck
--[[
	Reports, Addendum G (after the final review):
	  M  the queue and the Admin tab page through the whole index (past one 200-entry range)
	  M  a stale index entry with no open record (a submit/resolve race) is removed on read
	  M  a record older than queue.indexExpiryDays is closed on read (reporter ids dropped); reporter
	     ids older than that are dropped on every write
	  M  the viewer rule: an unknown rank (Admin.rankOfChecked nil) hides the report
	  L  a claimed report is resolved only by its claimer or a higher rank (or trusted code)
	Fix 2 (the delta review):
	  M  a rank known when a report was filed is never used later: unknown now = hidden, and a
	     claimer whose rank is unknown can't be overridden
	  L  a ghost drop re-checks the record after its remove: a submit that raced it keeps its entry
	  L  a Reports tab fetch reads at most two index pages whatever queue.maxOpen is
]]
local H = require("packages/kits/moderation/tests/ReportsHelpers.luau")
local Reports = H.Reports
local TextFilter = H.TextFilter
local Admin = H.Admin
local Moderation = H.Moderation

local DAY = 86400
local ALL = { "reports.read", "reports.resolve", "reports.reporters" }

local function staffBoot(roles, opts)
	opts = opts or {}
	local fa = H.fakeAdmin(roles)
	if opts.unknown then
		fa.api.rankOfChecked = function(who)
			local id = if type(who) == "number" then who else who.UserId
			if opts.unknown[id] then
				return nil
			end
			local r = roles[id]
			return if r then r.rank else 0
		end
	end
	local fm = H.fakeModeration()
	local h = H.boot({
		modules = { Admin, Moderation, TextFilter, Reports },
		servers = { Admin = fa, Moderation = fm },
		config = opts.config,
	})
	return h, fa
end

local function idOf(h, target)
	local ok, list = h:use(Reports).queue({ by = "server", limit = 300 })
	assert(ok, list)
	for _, s in list do
		if s.target == target then
			return s.id
		end
	end
	return nil
end

describe("the whole queue", function()
	it("queue() and the Admin tab reach reports past the first 200 index entries", function()
		local limits = {
			perReporterPerHour = 300,
			perReporterPerDay = 300,
			perPairPerDay = 1,
			perTargetPerDay = 30,
			sentMax = 300,
		}
		local h, fa = staffBoot({ [H.STAFF] = { rank = 200, permissions = ALL } }, {
			config = { Reports = { limits = limits, queue = { maxOpen = 300, indexExpiryDays = 7 } } },
		})
		local api = h:use(Reports)
		local staff = h:addPlayer({ userId = H.STAFF })
		local reporter = h:addPlayer({ userId = H.reporter(1) })
		for n = 1, 210 do
			h:addPlayer({ userId = 90000 + n })
			h.clock += 1
			expect(api.submit(reporter, 90000 + n, "other", nil)).toBe(true)
		end
		local ok, list = api.queue({ by = staff, limit = 300 })
		expect(ok).toBe(true)
		expect(#list).toBe(210)
		-- the oldest report (lowest priority) is on the tab's last page
		local rows = fa.tabs.reports.fetch(staff, 11).rows
		expect(#rows).toBe(10)
		expect(string.find(rows[#rows].target, "(90001)", 1, true)).never.toBe(nil)
	end)
end)

describe("stale and ghost entries", function()
	it("an index entry whose record is gone is removed when staff open it", function()
		local h = staffBoot({ [H.STAFF] = { rank = 200, permissions = ALL } })
		local api = h:use(Reports)
		local staff = h:addPlayer({ userId = H.STAFF })
		h:addPlayer({ userId = H.TARGET })
		local r = h:addPlayer({ userId = H.reporter(1) })
		expect(api.submit(r, H.TARGET, "cheating", nil)).toBe(true)
		local id = idOf(h, H.TARGET)
		-- the race's end state: the record was resolved elsewhere, the index written after it
		h.runtime.shared.backend.values[`Reports/r/t/{H.TARGET}`] = nil
		expect(#h:sortedMap("Reports", "queue").entries()).toBe(1)
		expect(select(2, api.detail(id, { by = staff }))).toBe("not_found")
		expect(#h:sortedMap("Reports", "queue").entries()).toBe(0)
		-- claim and resolve clean up the same way
		expect(api.submit(h:addPlayer({ userId = H.reporter(2) }), H.TARGET, "cheating", nil)).toBe(true)
		local id2 = idOf(h, H.TARGET)
		h.runtime.shared.backend.values[`Reports/r/t/{H.TARGET}`] = nil
		expect(select(2, api.resolve(id2, "dismissed", { by = staff }))).toBe("not_found")
		expect(#h:sortedMap("Reports", "queue").entries()).toBe(0)
	end)

	it("a record older than indexExpiryDays is closed on read: reporter ids dropped", function()
		local h = staffBoot({ [H.STAFF] = { rank = 200, permissions = ALL } })
		local api = h:use(Reports)
		h:addPlayer({ userId = H.TARGET })
		local r = h:addPlayer({ userId = H.reporter(1) })
		expect(api.submit(r, H.TARGET, "cheating", nil)).toBe(true)
		local id = idOf(h, H.TARGET)
		h.clock += 8 * DAY
		expect(select(2, api.detail(id, { by = "server" }))).toBe("not_found")
		local left = h.runtime.shared.backend.values[`Reports/r/t/{H.TARGET}`]
		expect(left == nil or left["$deleted"] == true).toBe(true) -- deleted (a tombstone)
	end)

	it("reporter ids older than indexExpiryDays are dropped on every write", function()
		local h = staffBoot({ [H.STAFF] = { rank = 200, permissions = ALL } })
		local api = h:use(Reports)
		h:addPlayer({ userId = H.TARGET })
		for i = 1, 3 do
			local r = h:addPlayer({ userId = H.reporter(i) })
			expect(api.submit(r, H.TARGET, "cheating", nil)).toBe(true)
			h.clock += 5 * DAY -- the record stays open: each report is less than 7 days after the last
		end
		local ok, rec = api.detail(idOf(h, H.TARGET), { by = "server" })
		expect(ok).toBe(true)
		expect(rec.reporters).toEqual({ H.reporter(2), H.reporter(3) })
		expect(rec.count).toBe(3)
	end)
end)

describe("viewer rule with an unknown rank", function()
	it("a report about a target whose rank Admin doesn't know is hidden from staff", function()
		local OTHER = H.TARGET + 1
		local h = staffBoot(
			{ [H.STAFF] = { rank = 200, permissions = ALL } },
			{ unknown = { [OTHER] = true } }
		)
		local api = h:use(Reports)
		local staff = h:addPlayer({ userId = H.STAFF })
		h:addPlayer({ userId = H.TARGET })
		h:addPlayer({ userId = OTHER })
		local r = h:addPlayer({ userId = H.reporter(1) })
		expect(api.submit(r, H.TARGET, "cheating", nil)).toBe(true)
		expect(api.submit(r, OTHER, "cheating", nil)).toBe(true)
		local ok, list = api.queue({ by = staff })
		expect(ok).toBe(true)
		expect(#list).toBe(1)
		expect(list[1].target).toBe(H.TARGET)
		local okAll, all = api.queue({ by = "server" })
		expect(okAll).toBe(true)
		expect(#all).toBe(2)
	end)
end)

describe("resolving a claimed report", function()
	it("the claimer or a higher rank; an equal rank gets 'claimed'", function()
		local A, B, C = H.STAFF, H.STAFF + 1, H.STAFF + 2
		local h = staffBoot({
			[A] = { rank = 200, permissions = ALL },
			[B] = { rank = 200, permissions = ALL },
			[C] = { rank = 300, permissions = ALL },
		})
		local api = h:use(Reports)
		local a = h:addPlayer({ userId = A })
		local b = h:addPlayer({ userId = B })
		local c = h:addPlayer({ userId = C })
		h:addPlayer({ userId = H.TARGET })
		local r = h:addPlayer({ userId = H.reporter(1) })
		expect(api.submit(r, H.TARGET, "cheating", nil)).toBe(true)
		local id = idOf(h, H.TARGET)
		expect(api.claim(id, { by = a })).toBe(true)
		expect(select(2, api.resolve(id, "dismissed", { by = b }))).toBe("claimed")
		expect(idOf(h, H.TARGET)).toBe(id)
		expect(api.resolve(id, "actioned", { by = c })).toBe(true)
		expect(idOf(h, H.TARGET)).toBe(nil)
		-- the claimer resolves their own claim
		expect(api.submit(h:addPlayer({ userId = H.reporter(2) }), H.TARGET, "cheating", nil)).toBe(true)
		local id2 = idOf(h, H.TARGET)
		expect(api.claim(id2, { by = b })).toBe(true)
		expect(api.resolve(id2, "no_action", { by = b })).toBe(true)
	end)
end)

describe("fix 2: no rank remembered from an earlier report", function()
	it("a target reported at rank 0, then promoted and unknown, is hidden", function()
		local unknown = {}
		local roles = { [H.STAFF] = { rank = 200, permissions = ALL } }
		local h, fa = staffBoot(roles, { unknown = unknown })
		local api = h:use(Reports)
		local staff = h:addPlayer({ userId = H.STAFF })
		h:addPlayer({ userId = H.TARGET })
		local r = h:addPlayer({ userId = H.reporter(1) })
		expect(api.submit(r, H.TARGET, "cheating", nil)).toBe(true)
		local ok, list = api.queue({ by = staff })
		expect(ok).toBe(true)
		expect(#list).toBe(1)
		local id = list[1].id
		-- promoted above the viewer; Admin doesn't know the new rank yet
		roles[H.TARGET] = { rank = 300, permissions = ALL }
		unknown[H.TARGET] = true
		ok, list = api.queue({ by = staff })
		expect(ok).toBe(true)
		expect(#list).toBe(0)
		expect(#fa.tabs.reports.fetch(staff, 1).rows).toBe(0)
		expect(select(2, api.detail(id, { by = staff }))).toBe("not_found")
		-- a report filed while the rank is unknown doesn't make it visible either
		expect(api.submit(h:addPlayer({ userId = H.reporter(2) }), H.TARGET, "cheating", nil)).toBe(true)
		ok, list = api.queue({ by = staff })
		expect(ok).toBe(true)
		expect(#list).toBe(0)
	end)

	it("resolve: a claimer whose current rank is unknown is never overridden", function()
		local A, C = H.STAFF, H.STAFF + 2
		local unknown = {}
		local roles = { [A] = { rank = 200, permissions = ALL } }
		local h = staffBoot(roles, { unknown = unknown })
		local api = h:use(Reports)
		local a = h:addPlayer({ userId = A })
		local c = h:addPlayer({ userId = C })
		h:addPlayer({ userId = H.TARGET })
		local r = h:addPlayer({ userId = H.reporter(1) })
		-- C is reported while a regular player (rank 0 known then)
		expect(api.submit(r, C, "cheating", nil)).toBe(true)
		expect(idOf(h, C)).never.toBe(nil)
		-- C is promoted above A and claims a report
		roles[C] = { rank = 300, permissions = ALL }
		expect(api.submit(r, H.TARGET, "cheating", nil)).toBe(true)
		local id = idOf(h, H.TARGET)
		expect(api.claim(id, { by = c })).toBe(true)
		-- C's rank becomes unknown: A (200) can't override the claim
		unknown[C] = true
		expect(select(2, api.resolve(id, "dismissed", { by = a }))).toBe("claimed")
		expect(idOf(h, H.TARGET)).toBe(id)
		-- known again (300 > 200): still C's
		unknown[C] = nil
		expect(select(2, api.resolve(id, "dismissed", { by = a }))).toBe("claimed")
		expect(api.resolve(id, "dismissed", { by = c })).toBe(true)
	end)
end)

describe("fix 2: ghost drops", function()
	it("a submit that lands between the ghost check and the remove keeps its index entry", function()
		local h = staffBoot({ [H.STAFF] = { rank = 200, permissions = ALL } })
		local api = h:use(Reports)
		local staff = h:addPlayer({ userId = H.STAFF })
		h:addPlayer({ userId = H.TARGET })
		local r = h:addPlayer({ userId = H.reporter(1) })
		expect(api.submit(r, H.TARGET, "cheating", nil)).toBe(true)
		local id = idOf(h, H.TARGET)
		-- the record was resolved elsewhere; its index entry is a ghost
		h.runtime.shared.backend.values[`Reports/r/t/{H.TARGET}`] = nil
		local fake = h:sortedMap("Reports", "queue")
		local realRemove = fake.remove
		local raced = false
		fake.remove = function(key, ...)
			if not raced and key == tostring(H.TARGET) then
				raced = true
				-- another server's submit: a new record, then its index entry
				h.clock += 1
				expect(api.submit(h:addPlayer({ userId = H.reporter(2) }), H.TARGET, "cheating", nil)).toBe(
					true
				)
			end
			return realRemove(key, ...)
		end
		expect(select(2, api.detail(id, { by = staff }))).toBe("not_found")
		expect(raced).toBe(true)
		local entries = fake.entries()
		expect(#entries).toBe(1)
		expect(entries[1].value.id).never.toBe(id)
		local newId = idOf(h, H.TARGET)
		expect(newId).never.toBe(nil)
		expect(api.detail(newId, { by = staff })).toBe(true)
	end)
end)

describe("fix 2: the tab's store reads", function()
	it("each fetch reads at most two index pages; paging forward reaches the oldest report", function()
		local limits = {
			perReporterPerHour = 200,
			perReporterPerDay = 200,
			perPairPerDay = 1,
			perTargetPerDay = 30,
			sentMax = 200,
		}
		local h, fa = staffBoot({ [H.STAFF] = { rank = 200, permissions = ALL } }, {
			config = { Reports = { limits = limits, queue = { maxOpen = 1000, indexExpiryDays = 7 } } },
		})
		local api = h:use(Reports)
		local staff = h:addPlayer({ userId = H.STAFF })
		local n = 0
		for i = 1, 3 do
			local reporter = h:addPlayer({ userId = H.reporter(i) })
			for _ = 1, 150 do
				n += 1
				h:addPlayer({ userId = 90000 + n })
				h.clock += 1
				expect(api.submit(reporter, 90000 + n, "other", nil)).toBe(true)
			end
		end
		local fake = h:sortedMap("Reports", "queue")
		local function ranges()
			local c = 0
			for _, call in fake.calls do
				if call.op == "range" then
					c += 1
				end
			end
			return c
		end
		local seen = 0
		local last
		for p = 1, 23 do
			local before = ranges()
			local rows = fa.tabs.reports.fetch(staff, p).rows
			expect(ranges() - before <= 2).toBe(true)
			expect(#rows).toBe(if p < 23 then 20 else 10)
			seen += #rows
			last = rows[#rows]
		end
		expect(seen).toBe(450)
		expect(string.find(last.target, "(90001)", 1, true)).never.toBe(nil)
		-- page 1 always starts over (one read for its 20 rows)
		local before = ranges()
		expect(#fa.tabs.reports.fetch(staff, 1).rows).toBe(20)
		expect(ranges() - before).toBe(1)
	end)
end)
