--!nocheck
--[[
	Reports: submission, every spam limit, duplicate merging, the maxOpen eviction, target and
	argument validation, notes (filtered / dropped), context values, the recently-left list and
	the flag kill switch (design §5, §8-§10).
]]
local H = require("packages/kits/moderation/tests/ReportsHelpers.luau")
local Reports = H.Reports
local TextFilter = H.TextFilter

local HOUR = 3600
local DAY = 86400

local function boot(opts)
	opts = opts or {}
	opts.modules = opts.modules or { TextFilter, Reports }
	return H.boot(opts)
end

local function players(h, ids)
	local out = {}
	for _, id in ids do
		table.insert(out, h:addPlayer({ userId = id }))
	end
	return table.unpack(out)
end

local function queue(h, status)
	local ok, list = h:use(Reports).queue({ by = "server", status = status, limit = 200 })
	assert(ok, list)
	return list
end

local function find(list, target)
	for _, s in list do
		if s.target == target then
			return s
		end
	end
	return nil
end

describe("Reports.submit", function()
	it("files a report: one record, one queue entry, the Submitted signal without the reporter", function()
		local h = boot()
		local r, t = players(h, { H.reporter(1), H.TARGET })
		local heard = {}
		h:use(Reports).signals.Submitted:Connect(function(...)
			table.insert(heard, table.pack(...))
		end)
		expect(h:use(Reports).submit(r, H.TARGET, "cheating", nil)).toBe(true)
		local list = queue(h)
		expect(#list).toBe(1)
		expect(list[1].target).toBe(H.TARGET)
		expect(list[1].targetName).toBe(t.Name)
		expect(list[1].category).toBe("cheating")
		expect(list[1].count).toBe(1)
		expect(list[1].distinct).toBe(1)
		expect(list[1].status).toBe("open")
		expect(H.contains(list, H.reporter(1))).toBe(false) -- the index has no reporter ids
		expect(#heard).toBe(1)
		expect(heard[1].n).toBe(3)
		expect(heard[1][1]).toBe(list[1].id)
		expect(heard[1][2]).toBe(H.TARGET)
		expect(heard[1][3]).toBe("cheating")
		expect(H.contains(heard, H.reporter(1))).toBe(false)
		h:removePlayer(r)
		local saved = h:saved(r)
		expect(#saved.reports.sent).toBe(1)
		expect(saved.reports.sent[1].target).toBe(H.TARGET)
	end)

	it("validates the target, the category and the note before anything is stored", function()
		-- one report an hour: a refused report that reserved a slot would block the last one
		local h = boot({ config = { Reports = { limits = { perReporterPerHour = 1 } } } })
		local r = players(h, { H.reporter(1) })
		local api = h:use(Reports)
		expect(select(2, api.submit(r, 12345, "cheating", nil))).toBe("not_reportable") -- never here
		expect(select(2, api.submit(r, r.UserId, "cheating", nil))).toBe("invalid") -- self
		h:addPlayer({ userId = H.TARGET })
		expect(select(2, api.submit(r, H.TARGET, "griefing", nil))).toBe("invalid") -- not configured
		expect(select(2, api.submit(r, H.TARGET + 0.5, "cheating", nil))).toBe("invalid")
		expect(select(2, api.submit(r, -1, "cheating", nil))).toBe("invalid")
		expect(select(2, api.submit(r, H.TARGET, "cheating", string.rep("a", 121)))).toBe("invalid")
		expect(#queue(h)).toBe(0)
		expect(api.submit(r, H.TARGET, "cheating", string.rep("a", 120))).toBe(true)
	end)

	it("a player who left is reportable for recentSeconds, and is on the replicated recent list", function()
		local h = boot({ config = { Reports = { recentSeconds = 60 } } })
		local r, t, other = players(h, { H.reporter(1), H.TARGET, H.reporter(2) })
		local name = t.Name
		h:removePlayer(t)
		local recent = h:state(other).modules.Reports.extra.recent
		expect(recent).toEqual({ { userId = H.TARGET, name = name } })
		expect(h:use(Reports).submit(r, H.TARGET, "harassment", nil)).toBe(true)
		h:tick(66)
		expect(select(2, h:use(Reports).submit(other, H.TARGET, "harassment", nil))).toBe("not_reportable")
		expect(h:state(other).modules.Reports.extra.recent).toEqual({})
		-- rejoining takes them off the list (they are in the server again)
		local back = h:addPlayer({ userId = H.TARGET })
		expect(back).never.toBe(nil)
		expect(h:use(Reports).submit(other, H.TARGET, "harassment", nil)).toBe(true)
	end)
end)

describe("spam limits", function()
	it("perReporterPerHour", function()
		local h = boot({ config = { Reports = { limits = { perReporterPerHour = 2 } } } })
		local r = players(h, { H.reporter(1) })
		players(h, { 90001, 90002, 90003 })
		local api = h:use(Reports)
		expect(api.submit(r, 90001, "cheating", nil)).toBe(true)
		expect(api.submit(r, 90002, "cheating", nil)).toBe(true)
		expect(select(2, api.submit(r, 90003, "cheating", nil))).toBe("reporter_hour")
		expect(find(queue(h), 90003)).toBe(nil)
		h.clock += HOUR
		expect(api.submit(r, 90003, "cheating", nil)).toBe(true)
	end)

	it("perReporterPerDay, durable in the reporter's save across a rejoin", function()
		local h =
			boot({ config = { Reports = { limits = { perReporterPerHour = 2, perReporterPerDay = 3 } } } })
		local r = players(h, { H.reporter(1) })
		players(h, { 90001, 90002, 90003, 90004 })
		local api = h:use(Reports)
		expect(api.submit(r, 90001, "cheating", nil)).toBe(true)
		expect(api.submit(r, 90002, "cheating", nil)).toBe(true)
		h:rejoin(r, { secondsAway = HOUR })
		r = h.players[H.reporter(1)]
		expect(api.submit(r, 90003, "cheating", nil)).toBe(true)
		expect(select(2, api.submit(r, 90004, "cheating", nil))).toBe("reporter_day")
		h:rejoin(r, { secondsAway = 60 })
		r = h.players[H.reporter(1)]
		expect(select(2, api.submit(r, 90004, "cheating", nil))).toBe("reporter_day")
		h.clock += DAY
		expect(api.submit(r, 90004, "cheating", nil)).toBe(true)
	end)

	it("perPairPerDay: the same target once a day per reporter", function()
		local h = boot()
		local r = players(h, { H.reporter(1), H.TARGET })
		local api = h:use(Reports)
		expect(api.submit(r, H.TARGET, "cheating", nil)).toBe(true)
		h.clock += HOUR * 2
		expect(select(2, api.submit(r, H.TARGET, "scam", nil))).toBe("pair")
		expect(find(queue(h), H.TARGET).count).toBe(1)
		h.clock += DAY
		expect(api.submit(r, H.TARGET, "scam", nil)).toBe(true)
		local s = find(queue(h), H.TARGET)
		expect(s.count).toBe(2) -- merged into the same open report
		expect(s.distinct).toBe(1) -- still one reporter
	end)

	it("perTargetPerDay counts merged entries; the next day counts again", function()
		local h = boot({ config = { Reports = { limits = { perTargetPerDay = 3 } } } })
		players(h, { H.TARGET })
		local api = h:use(Reports)
		local rs = {}
		for i = 1, 5 do
			rs[i] = h:addPlayer({ userId = H.reporter(i) })
		end
		for i = 1, 3 do
			expect(api.submit(rs[i], H.TARGET, "cheating", nil)).toBe(true)
		end
		expect(select(2, api.submit(rs[4], H.TARGET, "cheating", nil))).toBe("target_day")
		expect(find(queue(h), H.TARGET).count).toBe(3)
		h.clock += DAY
		expect(api.submit(rs[5], H.TARGET, "cheating", nil)).toBe(true)
		expect(find(queue(h), H.TARGET).count).toBe(4)
	end)

	it("a refused report gives the reporter exactly the same feedback as an accepted one", function()
		local h = boot({ config = { Reports = { limits = { perReporterPerHour = 1 } } } })
		local r, t, x = players(h, { H.reporter(1), H.TARGET, 90002 })
		-- (the clock moves on between calls: the action's own rate limit is not what is tested)
		expect(H.report(h, r, H.TARGET)).toBe(true) -- accepted
		h.clock += 30
		expect(H.report(h, r, 90002)).toBe(true) -- over the hourly limit
		h.clock += 30
		expect(H.report(h, r, 424242)).toBe(true) -- not reportable
		h.clock += 30
		expect(H.report(h, r, H.TARGET, "nope")).toBe(true) -- invalid category
		local fb = H.feedback(h, r)
		expect(#fb).toBe(4)
		for i = 2, 4 do
			expect(fb[i]).toBe(fb[1])
		end
		expect(fb[1]).toBe("Thanks! Our team will look at your report.")
		expect(#queue(h)).toBe(1)
		-- nobody else heard anything
		expect(#H.feedback(h, t)).toBe(0)
		expect(#H.feedback(h, x)).toBe(0)
	end)
end)

describe("duplicates and the queue cap", function()
	it("reports of one target merge: count, distinct reporters, notes", function()
		local h = boot()
		players(h, { H.TARGET })
		local api = h:use(Reports)
		for i = 1, 3 do
			local r = h:addPlayer({ userId = H.reporter(i) })
			expect(api.submit(r, H.TARGET, if i == 1 then "cheating" else "scam", `note {i}`)).toBe(true)
		end
		local list = queue(h)
		expect(#list).toBe(1)
		expect(list[1].count).toBe(3)
		expect(list[1].distinct).toBe(3)
		expect(list[1].category).toBe("cheating") -- the first report's category
		local ok, d = api.detail(list[1].id, { by = "server" })
		expect(ok).toBe(true)
		expect(d.notes).toEqual({ "note 1", "note 2", "note 3" })
		expect(d.reporters).toEqual({ H.reporter(1), H.reporter(2), H.reporter(3) })
	end)

	it("maxOpen: a new report evicts the lowest-priority one (fewest reporters, then oldest)", function()
		local h = boot({ config = { Reports = { queue = { maxOpen = 3 } } } })
		players(h, { 90001, 90002, 90003, 90004 })
		local a, b = players(h, { H.reporter(1), H.reporter(2) })
		local api = h:use(Reports)
		expect(api.submit(a, 90001, "cheating", nil)).toBe(true)
		expect(api.submit(b, 90001, "cheating", nil)).toBe(true) -- 90001: two reporters
		h.clock += 10
		expect(api.submit(a, 90002, "cheating", nil)).toBe(true) -- oldest single-reporter report
		h.clock += 10
		expect(api.submit(a, 90003, "cheating", nil)).toBe(true)
		local evictedId = find(queue(h), 90002).id
		h.clock += 10
		expect(api.submit(b, 90004, "cheating", nil)).toBe(true)
		local list = queue(h)
		expect(#list).toBe(3)
		expect(find(list, 90002)).toBe(nil)
		expect(find(list, 90001)).never.toBe(nil)
		expect(find(list, 90003)).never.toBe(nil)
		expect(find(list, 90004)).never.toBe(nil)
		-- its per-target key went with it
		expect(select(2, api.detail(evictedId, { by = "server" }))).toBe("not_found")
		-- highest priority first
		expect(list[1].target).toBe(90001)
	end)

	it("the queue stays at maxOpen while many targets are reported", function()
		local h = boot({ config = { Reports = { queue = { maxOpen = 4 } } } })
		local api = h:use(Reports)
		local reporters = {}
		for i = 1, 4 do
			reporters[i] = h:addPlayer({ userId = H.reporter(i) })
		end
		for n = 1, 12 do
			h:addPlayer({ userId = 90000 + n })
			h.clock += 1
			local who = reporters[(n - 1) % 4 + 1]
			expect(api.submit(who, 90000 + n, "other", nil)).toBe(true)
			expect(#queue(h) <= 4).toBe(true)
		end
		expect(#h:sortedMap("Reports", "queue").entries()).toBe(4)
	end)
end)

describe("notes and context", function()
	it("notes are filtered (public) through TextFilter; only the filtered text is kept", function()
		local h = boot()
		local r = players(h, { H.reporter(1), H.TARGET })
		expect(h:use(Reports).submit(r, H.TARGET, "harassment", "said a badword")).toBe(true)
		local ok, d = h:use(Reports).detail(queue(h)[1].id, { by = "server" })
		expect(ok).toBe(true)
		expect(d.notes).toEqual({ "said a #######" })
	end)

	it("without TextFilter the note is dropped and the report still filed", function()
		local h = boot({ modules = { Reports } })
		local r = players(h, { H.reporter(1), H.TARGET })
		expect(h:use(Reports).submit(r, H.TARGET, "harassment", "hello there")).toBe(true)
		local ok, d = h:use(Reports).detail(queue(h)[1].id, { by = "server" })
		expect(ok).toBe(true)
		expect(d.notes).toEqual({})
		expect(d.count).toBe(1)
	end)

	it("a filter refusal drops the note (policy), and note.enabled = false ignores it", function()
		local h = boot({
			config = { TextFilter = { maxLength = 200, respectContentSharing = true } },
			policy = { [H.reporter(1)] = { IsContentSharingAllowed = false } },
		})
		local r = players(h, { H.reporter(1), H.TARGET })
		expect(h:use(Reports).submit(r, H.TARGET, "harassment", "hello there")).toBe(true)
		local _, d = h:use(Reports).detail(queue(h)[1].id, { by = "server" })
		expect(d.notes).toEqual({})

		local h2 = boot({ config = { Reports = { note = { enabled = false } } } })
		local r2 = h2:addPlayer({ userId = H.reporter(1) })
		h2:addPlayer({ userId = H.TARGET })
		expect(h2:use(Reports).submit(r2, H.TARGET, "harassment", "hello there")).toBe(true)
		local ok, list = h2:use(Reports).queue({ by = "server" })
		expect(ok).toBe(true)
		local _, d2 = h2:use(Reports).detail(list[1].id, { by = "server" })
		expect(d2.notes).toEqual({})
	end)

	it("context: numbers, booleans and declared strings keys only, capped at contextMaxBytes", function()
		local function run(maxBytes)
			local h = boot({ config = { Reports = { contextMaxBytes = maxBytes } } })
			local api = h:use(Reports)
			api.registerContext(function(targetUserId, target)
				expect(targetUserId).toBe(H.TARGET)
				expect(target.UserId).toBe(H.TARGET)
				return {
					level = 12,
					vip = true,
					zone = "Reports.category.scam", -- a declared strings key: kept
					raw = "free text", -- not a key: dropped
					big = string.rep("x", 10), -- dropped
					fn = function() end, -- dropped
				}
			end)
			api.registerContext(function()
				error("a broken context function is skipped")
			end)
			local r = players(h, { H.reporter(1), H.TARGET })
			expect(api.submit(r, H.TARGET, "cheating", nil)).toBe(true)
			local _, d = api.detail(queue(h)[1].id, { by = "server" })
			return d.context
		end
		local c = run(600)
		expect(c).toEqual({ level = 12, vip = true, zone = "Reports.category.scam" })
		-- the cap: level (5+2+4) and vip (3+4+4) fit in 30 bytes, zone (4+21+4) doesn't
		expect(run(30)).toEqual({ level = 12, vip = true })
		expect(run(0)).toBe(nil)
	end)
end)

describe("the flag kill switch", function()
	it("off: submit refused as disabled, the reporter told so, nothing stored", function()
		local h = boot({
			flags = { reportsOn = { default = false } },
			config = { Reports = { flag = "reportsOn" } },
		})
		local r = players(h, { H.reporter(1), H.TARGET })
		expect(select(2, h:use(Reports).submit(r, H.TARGET, "cheating", nil))).toBe("disabled")
		expect(H.report(h, r, H.TARGET)).toBe(true)
		expect(H.feedback(h, r)).toEqual({ "Reports are switched off right now" })
		expect(#h:sortedMap("Reports", "queue").entries()).toBe(0)
		h:removePlayer(r)
		expect(h:saved(r).reports.sent).toEqual({})
	end)

	it("on: works as usual", function()
		local h = boot({
			flags = { reportsOn = { default = true } },
			config = { Reports = { flag = "reportsOn" } },
		})
		local r = players(h, { H.reporter(1), H.TARGET })
		expect(h:use(Reports).submit(r, H.TARGET, "cheating", nil)).toBe(true)
	end)
end)
