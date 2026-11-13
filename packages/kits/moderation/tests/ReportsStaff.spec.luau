--!nocheck
--[[
	Reports: reporter privacy, the staff queue (permissions through an injected fake Admin part,
	the Admin-off fallback), viewer rules (a reported staff member never sees their own report, nor
	one about equal or higher staff), claim / resolve with the audit entry (fake Moderation, and the
	log fallback), autoAction, the Admin tab and the console. Design §5, B6, M15, L20.
]]
local H = require("packages/kits/moderation/tests/ReportsHelpers.luau")
local Reports = H.Reports
local TextFilter = H.TextFilter
local Admin = H.Admin
local Moderation = H.Moderation

local ALL = { "reports.read", "reports.resolve", "reports.reporters" }

local function staffBoot(roles, opts)
	opts = opts or {}
	local fa = H.fakeAdmin(roles)
	local fm = H.fakeModeration()
	local h = H.boot({
		modules = opts.modules or { Admin, Moderation, TextFilter, Reports },
		servers = { Admin = fa, Moderation = fm },
		config = opts.config,
		serverConfig = opts.serverConfig,
	})
	return h, fa, fm
end

local function fileReports(h, target, n, note)
	local api = h:use(Reports)
	for i = 1, n do
		local r = h.players[H.reporter(i)] or h:addPlayer({ userId = H.reporter(i) })
		assert(api.submit(r, target, "harassment", note or `note from {i}`))
	end
end

local function idOf(h, target)
	local ok, list = h:use(Reports).queue({ by = "server" })
	assert(ok, list)
	for _, s in list do
		if s.target == target then
			return s.id
		end
	end
	return nil
end

describe("reporter privacy", function()
	it(
		"a reporter's id is never in a non-staff player's state, nor in anything that reached the target",
		function()
			local h = staffBoot({ [H.STAFF] = { rank = 300, permissions = ALL } })
			local t = h:addPlayer({ userId = H.TARGET })
			local bystander = h:addPlayer({ userId = 90500 })
			local staff = h:addPlayer({ userId = H.STAFF })
			local heard = {}
			h:use(Reports).signals.Submitted:Connect(function(...)
				table.insert(heard, table.pack(...))
			end)
			h:use(Reports).signals.Resolved:Connect(function(...)
				table.insert(heard, table.pack(...))
			end)
			for i = 1, 3 do
				local r = h:addPlayer({ userId = H.reporter(i) })
				expect(H.report(h, r, H.TARGET, "harassment", "stop it")).toBe(true)
			end
			-- the target leaves and comes back (the recent list is replicated to everyone meanwhile)
			h:removePlayer(t)
			t = h:addPlayer({ userId = H.TARGET })
			local id = idOf(h, H.TARGET)
			expect(h:use(Reports).claim(id, { by = staff })).toBe(true)
			expect(h:use(Reports).resolve(id, "actioned", { by = staff })).toBe(true)
			for i = 1, 3 do
				local rid = H.reporter(i)
				for _, p in { t, bystander } do
					expect(H.contains(h:state(p), rid)).toBe(false)
				end
				expect(H.contains(H.reached(h, t), rid)).toBe(false)
				expect(H.contains(heard, rid)).toBe(false)
				expect(H.contains(h:sent("Reports"), rid)).toBe(false)
			end
			expect(#H.feedback(h, t)).toBe(0)
		end
	)

	it("the audit entry of a resolution carries no reporter ids", function()
		local h, _, fm = staffBoot({ [H.STAFF] = { rank = 300, permissions = ALL } })
		h:addPlayer({ userId = H.TARGET })
		local staff = h:addPlayer({ userId = H.STAFF })
		fileReports(h, H.TARGET, 3)
		local id = idOf(h, H.TARGET)
		expect(h:use(Reports).claim(id, { by = staff })).toBe(true)
		expect(
			h:use(Reports).resolve(id, "no_action", { by = staff, note = "Reports.resolveNote.insufficient" })
		).toBe(true)
		expect(#fm.records).toBe(2)
		expect(fm.records[1].entry.action).toBe("report_claimed")
		local e = fm.records[2].entry
		expect(e.action).toBe("report_resolved")
		expect(e.target).toBe(H.TARGET)
		expect(e.reasonKey).toBe("Reports.resolution.no_action")
		expect(e.note).toBe("Reports.resolveNote.insufficient")
		expect(fm.records[2].by).toBe(staff)
		for i = 1, 3 do
			expect(H.contains(e, H.reporter(i))).toBe(false)
		end
	end)
end)

describe("staff queue permissions", function()
	it("notes only for a staff viewer with reports.read; reporter ids only with reports.reporters", function()
		local h = staffBoot({
			[80001] = { rank = 300, permissions = ALL },
			[80002] = { rank = 200, permissions = { "reports.read" } },
			[80003] = { rank = 100, permissions = { "kick" } },
		})
		h:addPlayer({ userId = H.TARGET })
		local owner = h:addPlayer({ userId = 80001 })
		local reader = h:addPlayer({ userId = 80002 })
		local helper = h:addPlayer({ userId = 80003 })
		local player = h:addPlayer({ userId = 90600 })
		fileReports(h, H.TARGET, 2)
		local api = h:use(Reports)
		local id = idOf(h, H.TARGET)

		local ok, d = api.detail(id, { by = owner })
		expect(ok).toBe(true)
		expect(d.notes).toEqual({ "note from 1", "note from 2" })
		expect(d.reporters).toEqual({ H.reporter(1), H.reporter(2) })

		ok, d = api.detail(id, { by = reader })
		expect(ok).toBe(true)
		expect(d.notes).toEqual({ "note from 1", "note from 2" }) -- unattributed
		expect(d.reporters).toEqual({})
		expect(d.count).toBe(2)
		expect(H.contains(d, H.reporter(1))).toBe(false)

		for _, p in { helper, player } do
			expect(select(2, api.detail(id, { by = p }))).toBe("no_permission")
			expect(select(2, api.queue({ by = p }))).toBe("no_permission")
		end
		local okQ, list = api.queue({ by = reader })
		expect(okQ).toBe(true)
		expect(#list).toBe(1)
		expect(list[1].notes).toBe(nil) -- summaries only
		expect(H.contains(list, H.reporter(1))).toBe(false)
		-- "system" is never a reports reader
		expect(select(2, api.queue({ by = "system" }))).toBe("no_permission")
	end)

	it("a reported staff member doesn't see their own report, nor one about equal or higher staff", function()
		local h = staffBoot({
			[80001] = { rank = 300, permissions = ALL },
			[80002] = { rank = 200, permissions = ALL },
			[80003] = { rank = 200, permissions = ALL },
		})
		local admin = h:addPlayer({ userId = 80001 })
		local modA = h:addPlayer({ userId = 80002 })
		local modB = h:addPlayer({ userId = 80003 })
		h:addPlayer({ userId = H.TARGET })
		fileReports(h, 80002, 1) -- modA is reported
		local api = h:use(Reports)
		local id = idOf(h, 80002)
		local function targets(by)
			local ok, list = api.queue({ by = by })
			assert(ok, list)
			local out = {}
			for _, s in list do
				table.insert(out, s.target)
			end
			return out
		end
		expect(targets(modA)).toEqual({})
		expect(targets(modB)).toEqual({}) -- equal rank
		expect(targets(admin)).toEqual({ 80002 })
		for _, by in { modA, modB } do
			expect(select(2, api.detail(id, { by = by }))).toBe("not_found")
			expect(select(2, api.claim(id, { by = by }))).toBe("not_found")
			expect(select(2, api.resolve(id, "dismissed", { by = by }))).toBe("not_found")
		end
		expect(api.claim(id, { by = admin })).toBe(true)
		-- a staff member who left is still protected (rank by user id)
		h:removePlayer(modA)
		expect(targets(modB)).toEqual({})
	end)

	it("a client faking claim or resolve without permission is refused, and nothing changes", function()
		local h, fa, fm = staffBoot({ [80002] = { rank = 100, permissions = { "reports.read" } } })
		h:addPlayer({ userId = H.TARGET })
		local cheat = h:addPlayer({ userId = 90700 })
		local reader = h:addPlayer({ userId = 80002 })
		fileReports(h, H.TARGET, 1)
		local id = idOf(h, H.TARGET)
		-- there is no client action for staff calls at all: the only one is submit
		local Part =
			require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("Reports"))
		local names = {}
		for name in Part.new().actions do
			table.insert(names, name)
		end
		expect(names).toEqual({ "submit" })
		expect(pcall(function()
			h:action(cheat, Reports, "claim", id)
		end)).toBe(false)
		expect(pcall(function()
			h:action(cheat, Reports, "resolve", id, "dismissed")
		end)).toBe(false)
		-- through the Admin tab's row actions (as if Admin forwarded a faked request)
		local tab = fa.tabs.reports
		expect(tab).never.toBe(nil)
		for _, p in { cheat, reader } do
			for _, ra in tab.rowActions do
				local ok, why = ra.run(p, id, { preset = "Reports.resolution.dismissed" })
				expect(ok).toBe(false)
				expect(why).toBe("no_permission")
			end
			expect(select(2, h:use(Reports).claim(id, { by = p }))).toBe("no_permission")
			expect(select(2, h:use(Reports).resolve(id, "dismissed", { by = p }))).toBe("no_permission")
		end
		local ok, list = h:use(Reports).queue({ by = "server" })
		expect(ok).toBe(true)
		expect(list[1].status).toBe("open")
		expect(list[1].claimedBy).toBe(nil)
		expect(#fm.records).toBe(0)
		-- every staff check went through Admin.allow (the per-staff limits)
		expect(#fa.allowCalls > 0).toBe(true)
	end)

	it("Admin off: ServerConfig.Reports.admins (and Studio) are the staff", function()
		local h = H.boot({
			modules = { TextFilter, Reports },
			serverConfig = { Reports = { admins = { H.STAFF } } },
		})
		local staff = h:addPlayer({ userId = H.STAFF })
		local other = h:addPlayer({ userId = 90800 })
		h:addPlayer({ userId = H.TARGET })
		fileReports(h, H.TARGET, 1)
		local api = h:use(Reports)
		expect((api.queue({ by = staff }))).toBe(true)
		expect(select(2, api.queue({ by = other }))).toBe("no_permission")
		local id = idOf(h, H.TARGET)
		local ok, d = api.detail(id, { by = staff })
		expect(ok).toBe(true)
		expect(d.reporters).toEqual({ H.reporter(1) })
		-- a listed admin who is reported never sees that report
		fileReports(h, H.STAFF, 1)
		local _, list = api.queue({ by = staff })
		expect(#list).toBe(1)
		expect(list[1].target).toBe(H.TARGET)
		-- resolving without Moderation logs the audit line instead
		expect(api.resolve(id, "dismissed", { by = staff })).toBe(true)
		local logged = false
		for _, line in h.logs do
			if
				string.find(line.msg, "report_resolved", 1, true)
				and string.find(line.msg, tostring(H.TARGET), 1, true)
			then
				logged = true
				expect(string.find(line.msg, tostring(H.reporter(1)), 1, true)).toBe(nil)
			end
		end
		expect(logged).toBe(true)

		local studio = H.boot({ modules = { Reports }, isStudio = true })
		local anyone = studio:addPlayer({ userId = 90900 })
		expect((studio:use(Reports).queue({ by = anyone }))).toBe(true)
	end)
end)

describe("claim and resolve", function()
	it("claim marks the report; resolve clears the key and the index and fires Resolved", function()
		local h = staffBoot({
			[80001] = { rank = 300, permissions = ALL },
			[80002] = { rank = 300, permissions = ALL },
		})
		local a = h:addPlayer({ userId = 80001 })
		local b = h:addPlayer({ userId = 80002 })
		h:addPlayer({ userId = H.TARGET })
		fileReports(h, H.TARGET, 2)
		local api = h:use(Reports)
		local id = idOf(h, H.TARGET)
		local resolved = {}
		api.signals.Resolved:Connect(function(...)
			table.insert(resolved, table.pack(...))
		end)
		expect(api.claim(id, { by = a })).toBe(true)
		local _, list = api.queue({ by = "server", status = "claimed" })
		expect(#list).toBe(1)
		expect(list[1].claimedBy).toBe(80001)
		expect(select(2, api.claim(id, { by = b }))).toBe("claimed")
		expect(select(2, api.resolve(id, "maybe", { by = a }))).toBe("invalid")
		expect(select(2, api.resolve(id, "dismissed", { by = a, note = "free text" }))).toBe("invalid")
		expect(select(2, api.claim("nonsense", { by = a }))).toBe("invalid")
		expect(api.resolve(id, "actioned", { by = a, note = "Reports.resolveNote.actioned" })).toBe(true)
		expect(resolved[1][1]).toBe(id)
		expect(resolved[1][2]).toBe("actioned")
		expect(select(2, api.resolve(id, "actioned", { by = a }))).toBe("not_found")
		expect(#h:sortedMap("Reports", "queue").entries()).toBe(0)
		expect(select(2, api.detail(id, { by = "server" }))).toBe("not_found")
		-- a new report about the same target starts a fresh one (a new id)
		h.clock += 86400
		fileReports(h, H.TARGET, 1)
		local fresh = idOf(h, H.TARGET)
		expect(fresh).never.toBe(id)
	end)

	it("the Admin tab: rows for reports.read; notes only on the viewer's own claimed rows", function()
		local h, fa = staffBoot({ [80001] = { rank = 300, permissions = ALL } })
		local staff = h:addPlayer({ userId = 80001 })
		local player = h:addPlayer({ userId = 90950 })
		h:addPlayer({ userId = H.TARGET })
		h:addPlayer({ userId = 90002 })
		fileReports(h, H.TARGET, 2)
		h.clock += 86400
		fileReports(h, 90002, 1)
		local tab = fa.tabs.reports
		expect(tab.permission).toBe("reports.read")
		local page = tab.fetch(staff, 1)
		expect(#page.rows).toBe(2)
		expect(table.find(page.columns, "reporters")).never.toBe(nil)
		for _, row in page.rows do
			expect(row.notes).toBe("")
		end
		local id = idOf(h, H.TARGET)
		local claim = tab.rowActions[1]
		expect(claim.id).toBe("claim")
		expect(claim.run(staff, id, {})).toBe(true)
		page = tab.fetch(staff, 1)
		local row = nil
		for _, r in page.rows do
			if r.id == id then
				row = r
			end
		end
		expect(row.notes).toBe("note from 1 | note from 2")
		expect(row.reporters).toBe(`{H.reporter(1)},{H.reporter(2)}`)
		-- a non-staff fetch gets nothing
		expect(#tab.fetch(player, 1).rows).toBe(0)
		local resolve = tab.rowActions[2]
		expect(resolve.id).toBe("resolve")
		expect(select(2, resolve.run(staff, id, {}))).toBe("invalid")
		expect(resolve.run(staff, id, { preset = "Reports.resolution.dismissed" })).toBe(true)
		expect(#tab.fetch(staff, 1).rows).toBe(1)
	end)
end)

describe("autoAction", function()
	it("is off by default: no Moderation.report however many reporters", function()
		local h, _, fm = staffBoot({})
		h:addPlayer({ userId = H.TARGET })
		fileReports(h, H.TARGET, 8)
		expect(#fm.reports).toBe(0)
	end)

	it("on: distinct reporters within the window feed Moderation.report once per window", function()
		local h, _, fm = staffBoot({}, {
			config = {
				Reports = {
					autoAction = {
						enabled = true,
						distinctReporters = 3,
						windowSeconds = 600,
						source = "reports",
						severity = 2,
					},
				},
			},
		})
		local t = h:addPlayer({ userId = H.TARGET })
		fileReports(h, H.TARGET, 2)
		expect(#fm.reports).toBe(0)
		local r3 = h:addPlayer({ userId = H.reporter(3) })
		expect(h:use(Reports).submit(r3, H.TARGET, "cheating", nil)).toBe(true)
		expect(#fm.reports).toBe(1)
		expect(fm.reports[1].target).toBe(t)
		expect(fm.reports[1].source).toBe("reports")
		expect(fm.reports[1].severity).toBe(2)
		expect(fm.reports[1].details).toBe(nil) -- no reporter ids handed on
		local r4 = h:addPlayer({ userId = H.reporter(4) })
		expect(h:use(Reports).submit(r4, H.TARGET, "cheating", nil)).toBe(true)
		expect(#fm.reports).toBe(1) -- once per window
	end)

	it("reporters spread wider than the window don't trigger it", function()
		local h, _, fm = staffBoot({}, {
			config = {
				Reports = { autoAction = { enabled = true, distinctReporters = 3, windowSeconds = 600 } },
			},
		})
		h:addPlayer({ userId = H.TARGET })
		local api = h:use(Reports)
		for i = 1, 4 do
			local r = h:addPlayer({ userId = H.reporter(i) })
			expect(api.submit(r, H.TARGET, "cheating", nil)).toBe(true)
			h.clock += 400
		end
		expect(#fm.reports).toBe(0)
	end)
end)

describe("console (server-only)", function()
	it("queue, detail, claim, resolve and stats", function()
		local h = staffBoot({})
		h:addPlayer({ userId = H.TARGET })
		fileReports(h, H.TARGET, 2)
		local id = idOf(h, H.TARGET)
		expect(h:console("reports", "queue")).toContain(id)
		expect(h:console("reports", "detail", id)).toContain("count=2")
		expect(h:console("reports", "claim", id)).toBe("claimed")
		expect(h:console("reports", "resolve", id, "dismissed")).toBe("resolved")
		expect(h:console("reports", "stats")).toContain("created=1")
		expect(h:console("reports", "queue")).toContain("0 report(s)")
	end)
end)
