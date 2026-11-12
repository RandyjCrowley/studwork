--!nocheck
--[[
	Badges (v1.7.0, docs/framework/kits/badges.md): record first, send afterwards, never twice.
	Every BadgeService call goes to StudWork.test.fakes.badgeService through ctx.services; nothing
	here talks to Roblox. The send queue runs on the harness clock (h:tick).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Harness = require("packages/framework/test/harness.luau")
local Loader = require("packages/framework/server/Loader.luau")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Badges = require(Modules:WaitForChild("Badges"):WaitForChild("module"))

local fakes = StudWork.test.fakes

-- the real server part with a recording stand-in for its Blink event (Awarded)
local function badgesPart(log)
	local part = Loader.defaultLoadServer(Badges, nil, { bindNet = false })
	part.net = { Awarded = Harness.fakeEvent("Awarded", log) }
	return part
end

local function boot(opts)
	opts = opts or {}
	local events = {}
	local fake = opts.fake or fakes.badgeService(opts.fakeOpts)
	local modules = { Badges }
	for _, m in opts.modules or {} do
		table.insert(modules, m)
	end
	local servers = { Badges = badgesPart(events) }
	for name, s in opts.servers or {} do
		servers[name] = s
	end
	local config = { Badges = opts.badges or {} }
	for name, c in opts.config or {} do
		config[name] = c
	end
	local h = StudWork.test.harness({
		modules = modules,
		servers = servers,
		config = config,
		services = { BadgeService = fake },
		isStudio = opts.isStudio,
		env = opts.env,
		store = opts.store,
		flags = opts.flags,
		startTime = opts.startTime,
	})
	return h, fake, events
end

local function calls(fake, method)
	local n = 0
	for _, c in fake.calls do
		if c.method == method then
			n += 1
		end
	end
	return n
end

local function toasts(h, p)
	local out = {}
	for _, e in h.fake.serverEvents do
		if e.event == "Feedback" and e.player == p and e.args[1].Kind == "toast" then
			table.insert(out, e.args[1].Text)
		end
	end
	return out
end

local MANUAL = { kind = "manual" }

describe("Badges: record, then send", function()
	it("award records at once, sends in the background, fires BadgeAwarded, Awarded and a toast", function()
		local h, fake, events = boot({ badges = { badges = { first = { id = 101, trigger = MANUAL } } } })
		local p = h:addPlayer({ userId = 1 })
		local seen = {}
		h:use(Badges).signals.BadgeAwarded:Connect(function(player, key, id)
			table.insert(seen, { player = player, key = key, id = id })
		end)
		expect(h:use(Badges).has(p, "first")).toBe(false)
		expect(h:use(Badges).award(p, "first")).toBe(true)
		expect(h:use(Badges).has(p, "first")).toBe(true)
		expect(fake.owns(1, 101)).toBe(true)
		expect(#seen).toBe(1)
		expect(seen[1].key).toBe("first")
		expect(seen[1].id).toBe(101)
		expect(#events).toBe(1)
		expect(events[1].event).toBe("Awarded")
		expect(events[1].args[1]).toBe("first")
		expect(toasts(h, p)).toEqual({ "Badge earned: first" })
		local rec = h:use(Badges)
		expect(rec.award(p, "first")).toBe(false) -- already recorded
		h:removePlayer(p)
		local saved = h:saved(p).badges.awarded.first
		expect(saved.sent).toBe(true)
		expect(saved.found).toBe(nil)
		expect(type(saved.at)).toBe("number")
	end)

	it("an unknown key errors (a typo is a bug)", function()
		local h = boot({ badges = { badges = { first = { id = 101, trigger = MANUAL } } } })
		local p = h:addPlayer({ userId = 1 })
		expect(pcall(h:use(Badges).award, p, "frist")).toBe(false)
		expect(pcall(h:use(Badges).has, p, "frist")).toBe(false)
	end)

	it("BadgeAwarded fires only after the fake confirmed, never on a mere record", function()
		local h, fake = boot({
			badges = { badges = { first = { id = 101, trigger = MANUAL } }, ownershipCheck = false },
			fakeOpts = { failNext = 2 }, -- the first two badge info lookups raise
		})
		local p = h:addPlayer({ userId = 1 })
		local fired = 0
		h:use(Badges).signals.BadgeAwarded:Connect(function()
			fired += 1
		end)
		expect(h:use(Badges).award(p, "first")).toBe(true)
		expect(fired).toBe(0)
		expect(fake.owns(1, 101)).toBe(false)
		h:tick(5) -- base backoff 5 s
		expect(fired).toBe(0)
		h:tick(10) -- then 10 s
		expect(fired).toBe(1)
		expect(fake.owns(1, 101)).toBe(true)
	end)

	it("never twice: two triggers, a rejoin, and a fake that says the badge is already owned", function()
		local h, fake = boot({ badges = { badges = { first = { id = 101, trigger = MANUAL } } } })
		local p = h:addPlayer({ userId = 1 })
		local fired = 0
		h:use(Badges).signals.BadgeAwarded:Connect(function()
			fired += 1
		end)
		expect(h:use(Badges).award(p, "first")).toBe(true)
		expect(h:use(Badges).award(p, "first")).toBe(false)
		h:rejoin(p, { secondsAway = 60 })
		expect(h:use(Badges).award(p, "first")).toBe(false)
		h:tick(30)
		expect(calls(fake, "AwardBadgeAsync")).toBe(1)
		expect(fired).toBe(1)
		expect(#fake.awarded()).toBe(1)
	end)

	it("a player who deleted the badge on Roblox is never sent it again", function()
		local h, fake = boot({ badges = { badges = { first = { id = 101, trigger = MANUAL } } } })
		local p = h:addPlayer({ userId = 1 })
		h:use(Badges).award(p, "first")
		expect(calls(fake, "AwardBadgeAsync")).toBe(1)
		-- the player removes it from their profile (Roblox would allow a re-award); our record stays
		h:rejoin(p, { secondsAway = 3600 })
		h:tick(10)
		expect(calls(fake, "AwardBadgeAsync")).toBe(1)
		expect(calls(fake, "CheckUserBadgesAsync")).toBe(1) -- the first join's; a sent one isn't checked again
	end)

	it(
		"errors back off (5, then 10 s), then stay pending to the next session and survive the rejoin",
		function()
			local h, fake = boot({
				badges = {
					badges = { first = { id = 101, trigger = MANUAL } },
					ownershipCheck = false,
					retry = { base = 5, factor = 2, max = 300, attempts = 3 },
				},
				fakeOpts = { failNext = 3 }, -- each attempt's first call (the badge info lookup) raises
			})
			local p = h:addPlayer({ userId = 1 })
			h:use(Badges).award(p, "first")
			expect(calls(fake, "GetBadgeInfoAsync")).toBe(1)
			h:tick(4)
			expect(calls(fake, "GetBadgeInfoAsync")).toBe(1) -- not before 5 s
			h:tick(1)
			expect(calls(fake, "GetBadgeInfoAsync")).toBe(2)
			h:tick(9)
			expect(calls(fake, "GetBadgeInfoAsync")).toBe(2)
			h:tick(1)
			expect(calls(fake, "GetBadgeInfoAsync")).toBe(3) -- the third failure: attempts = 3, stop
			h:tick(600)
			expect(calls(fake, "GetBadgeInfoAsync")).toBe(3)
			expect(calls(fake, "AwardBadgeAsync")).toBe(0)
			expect(h:use(Badges).has(p, "first")).toBe(true)
			h:removePlayer(p)
			expect(h:saved(p).badges.awarded.first.sent).toBe(false)
			-- the next session (the fake works again) sends it
			h:addPlayer({ userId = 1 })
			expect(calls(fake, "AwardBadgeAsync")).toBe(1)
			expect(fake.owns(1, 101)).toBe(true)
			h:removePlayer(p)
			expect(h:saved(p).badges.awarded.first.sent).toBe(true)
		end
	)

	it("a disabled badge is skipped with one warning per server and stays pending", function()
		local h, fake = boot({
			badges = {
				badges = { first = { id = 101, trigger = MANUAL }, second = { id = 101, trigger = MANUAL } },
			},
			fakeOpts = { disabled = { 101 } },
		})
		local p = h:addPlayer({ userId = 1 })
		local q = h:addPlayer({ userId = 2 })
		h:use(Badges).award(p, "first")
		h:use(Badges).award(q, "first")
		h:use(Badges).award(p, "second")
		h:tick(30)
		expect(calls(fake, "AwardBadgeAsync")).toBe(0)
		local warnings = 0
		for _, w in h:warnings() do
			if string.find(w, "disabled", 1, true) then
				warnings += 1
			end
		end
		expect(warnings).toBe(1)
		h:removePlayer(p)
		expect(h:saved(p).badges.awarded.first.sent).toBe(false)
	end)

	it("over budget.perMinute the sends wait for the next minute", function()
		local badges = {}
		for i = 1, 5 do
			badges["b" .. i] = { id = 200 + i, trigger = MANUAL }
		end
		local h, fake = boot({
			badges = {
				badges = badges,
				ownershipCheck = false,
				budget = {
					perMinute = { base = 1, perPlayer = 1 },
					checksPerMinute = { base = 10, perPlayer = 5 },
				},
			},
			startTime = 60 * 1000, -- the start of a minute
		})
		local p = h:addPlayer({ userId = 1 }) -- 1 + 1 x 1 player = 2 a minute
		for i = 1, 5 do
			h:use(Badges).award(p, "b" .. i)
		end
		expect(calls(fake, "AwardBadgeAsync")).toBe(2)
		h:tick(59)
		expect(calls(fake, "AwardBadgeAsync")).toBe(2)
		h:tick(1)
		expect(calls(fake, "AwardBadgeAsync")).toBe(4)
		h:tick(60)
		expect(calls(fake, "AwardBadgeAsync")).toBe(5)
		expect(#fake.awarded()).toBe(5)
	end)

	it("a placeholder id 0 is recorded, never sent or checked, one warning per server", function()
		local h, fake = boot({ badges = { badges = { soon = { id = 0, trigger = MANUAL } } } })
		local p = h:addPlayer({ userId = 1 })
		local q = h:addPlayer({ userId = 2 })
		expect(h:warnings()).toEqual({}) -- nothing at boot or join
		expect(h:use(Badges).award(p, "soon")).toBe(true)
		expect(h:use(Badges).award(q, "soon")).toBe(true)
		h:rejoin(p, { secondsAway = 10 })
		h:tick(30)
		expect(#fake.calls).toBe(0)
		local placeholder = 0
		for _, w in h:warnings() do
			if string.find(w, "placeholder", 1, true) then
				placeholder += 1
			end
		end
		expect(placeholder).toBe(1)
		expect(h:use(Badges).has(p, "soon")).toBe(true)
	end)

	it("Studio records in the Studio save and logs, but never sends (awardInStudio = false)", function()
		local h, fake =
			boot({ badges = { badges = { first = { id = 101, trigger = MANUAL } } }, isStudio = true })
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Badges).award(p, "first")).toBe(true)
		h:tick(30)
		expect(calls(fake, "AwardBadgeAsync")).toBe(0)
		local logged = false
		for _, l in h.logs do
			if string.find(l.msg, "would award first", 1, true) then
				logged = true
			end
		end
		expect(logged).toBe(true)
		h:removePlayer(p)
		expect(h:saved(p).badges.awarded.first.sent).toBe(false)
	end)

	it("Studio with awardInStudio = true sends like live", function()
		local h, fake = boot({
			badges = { badges = { first = { id = 101, trigger = MANUAL } }, awardInStudio = true },
			isStudio = true,
		})
		local p = h:addPlayer({ userId = 1 })
		h:use(Badges).award(p, "first")
		expect(calls(fake, "AwardBadgeAsync")).toBe(1)
	end)

	it("while config.flag is off, awards are recorded as pending and nothing is sent", function()
		local h, fake = boot({
			badges = { badges = { first = { id = 101, trigger = MANUAL } }, flag = "badgesOn" },
			flags = { badgesOn = { default = false } },
		})
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Badges).award(p, "first")).toBe(true)
		h:tick(30)
		expect(#fake.calls).toBe(0)
		expect(h:use(Badges).has(p, "first")).toBe(true)
	end)

	it("a player who leaves mid-queue keeps the badge pending; it is sent on their next join", function()
		local h, fake = boot({
			badges = {
				badges = { first = { id = 101, trigger = MANUAL } },
				budget = {
					perMinute = { base = 0, perPlayer = 0 },
					checksPerMinute = { base = 10, perPlayer = 5 },
				},
			},
		})
		local p = h:addPlayer({ userId = 1 })
		h:use(Badges).award(p, "first") -- no award budget at all: stays queued
		expect(calls(fake, "AwardBadgeAsync")).toBe(0)
		h:removePlayer(p)
		expect(h:saved(p).badges.awarded.first.sent).toBe(false)
		-- another server with a budget
		local h2, fake2 =
			boot({ badges = { badges = { first = { id = 101, trigger = MANUAL } } }, store = h.store })
		local p2 = h2:addPlayer({ userId = 1 })
		expect(fake2.owns(1, 101)).toBe(true)
		h2:removePlayer(p2)
		expect(h2:saved(p2).badges.awarded.first.sent).toBe(true)
	end)
end)

describe("Badges: ownership", function()
	it(
		"at join checks unrecorded and pending badges in batches of 10 and records owned ones without an award",
		function()
			local badges = {}
			local owned = {}
			for i = 1, 23 do
				badges["b" .. i] = { id = 300 + i, trigger = MANUAL }
				if i % 2 == 0 then
					table.insert(owned, 300 + i)
				end
			end
			local h, fake = boot({ badges = { badges = badges }, fakeOpts = { owned = { [1] = owned } } })
			local fired = 0
			h:use(Badges).signals.BadgeAwarded:Connect(function()
				fired += 1
			end)
			local p = h:addPlayer({ userId = 1 })
			local sizes = {}
			for _, c in fake.calls do
				if c.method == "CheckUserBadgesAsync" then
					table.insert(sizes, #c.badgeIds)
				end
			end
			expect(sizes).toEqual({ 10, 10, 3 })
			expect(calls(fake, "AwardBadgeAsync")).toBe(0)
			expect(fired).toBe(11)
			expect(h:use(Badges).has(p, "b2")).toBe(true)
			expect(h:use(Badges).has(p, "b1")).toBe(false)
			h:removePlayer(p)
			local rec = h:saved(p).badges.awarded.b2
			expect(rec.sent).toBe(true)
			expect(rec.found).toBe(true)
		end
	)

	it("a pending badge the fake reports as owned is recorded as found at join (no award call)", function()
		-- a server whose sends all fail leaves the badge pending (like a crash between the award
		-- and the save)
		local h, fake = boot({
			badges = { badges = { first = { id = 101, trigger = MANUAL } }, ownershipCheck = false },
			fakeOpts = { failNext = 1000 },
		})
		local p = h:addPlayer({ userId = 5 })
		h:use(Badges).award(p, "first")
		h:removePlayer(p)
		expect(h:saved(p).badges.awarded.first.sent).toBe(false)
		expect(fake.owns(5, 101)).toBe(false)
		-- that save on a server whose BadgeService says user 5 owns the badge
		local h2, fake2 = boot({
			badges = { badges = { first = { id = 101, trigger = MANUAL } } },
			fakeOpts = { owned = { [5] = { 101 } } },
			store = h.store,
		})
		local p2 = h2:addPlayer({ userId = 5 })
		expect(calls(fake2, "CheckUserBadgesAsync")).toBe(1)
		h2:tick(60)
		expect(calls(fake2, "AwardBadgeAsync")).toBe(0)
		h2:removePlayer(p2)
		local rec = h2:saved(p2).badges.awarded.first
		expect(rec.sent).toBe(true)
		expect(rec.found).toBe(true)
	end)

	it(
		"on send: AwardBadgeAsync false -> one check -> owned is recorded as found and stops retrying",
		function()
			local h, fake = boot({
				badges = { badges = { first = { id = 101, trigger = MANUAL } }, ownershipCheck = false },
				fakeOpts = { owned = { [1] = { 101 } } },
			})
			local p = h:addPlayer({ userId = 1 })
			local fired = 0
			h:use(Badges).signals.BadgeAwarded:Connect(function()
				fired += 1
			end)
			h:use(Badges).award(p, "first")
			expect(calls(fake, "AwardBadgeAsync")).toBe(1)
			expect(calls(fake, "CheckUserBadgesAsync")).toBe(1)
			expect(fired).toBe(1)
			expect(toasts(h, p)).toEqual({}) -- found, not freshly awarded: no toast
			h:tick(600)
			expect(calls(fake, "AwardBadgeAsync")).toBe(1)
			h:removePlayer(p)
			expect(h:saved(p).badges.awarded.first.found).toBe(true)
		end
	)

	it("on send: false and not owned counts as a failure (retried with backoff)", function()
		local fake = fakes.badgeService()
		fake.AwardBadgeAsync = function(_self, userId, badgeId)
			table.insert(fake.calls, { method = "AwardBadgeAsync", userId = userId, badgeId = badgeId })
			return false
		end
		local h = boot({
			fake = fake,
			badges = {
				badges = { first = { id = 101, trigger = MANUAL } },
				ownershipCheck = false,
				retry = { base = 5, factor = 2, max = 300, attempts = 2 },
			},
		})
		local p = h:addPlayer({ userId = 1 })
		h:use(Badges).award(p, "first")
		h:tick(5)
		h:tick(600)
		expect(calls(fake, "AwardBadgeAsync")).toBe(2)
		expect(calls(fake, "CheckUserBadgesAsync")).toBe(2)
	end)
end)

describe("Badges: transactions and console", function()
	local function probe()
		return StudWork.defineModule({
			name = "Probe",
			version = "1.0.0",
			framework = "^1.7.0",
			dependsOn = { Badges },
			data = { key = "probe", version = 1, default = { n = 0 } },
		})
	end

	it("txApi.award records inside the caller's tx and sends only after the commit", function()
		local captured
		local Probe = probe()
		local h, fake = boot({
			badges = { badges = { first = { id = 101, trigger = MANUAL } } },
			modules = { Probe },
			servers = { Probe = {
				init = function(ctx)
					captured = ctx
				end,
			} },
		})
		local p = h:addPlayer({ userId = 1 })
		local sentInside
		local ok = captured.tx(p, function(tx)
			expect(captured.depsTx[Badges].award(tx, "first")).toBe(true)
			expect(captured.depsTx[Badges].award(tx, "first")).toBe(false)
			sentInside = calls(fake, "AwardBadgeAsync")
			captured.section(tx).n = 1
		end)
		expect(ok).toBe(true)
		expect(sentInside).toBe(0)
		expect(calls(fake, "AwardBadgeAsync")).toBe(1)
		expect(h:use(Badges).has(p, "first")).toBe(true)
	end)

	it("txApi.award in a discarded transaction records nothing and sends nothing", function()
		local captured
		local Probe = probe()
		local h, fake = boot({
			badges = { badges = { first = { id = 101, trigger = MANUAL } } },
			modules = { Probe },
			servers = { Probe = {
				init = function(ctx)
					captured = ctx
				end,
			} },
		})
		local p = h:addPlayer({ userId = 1 })
		local ok = pcall(captured.tx, p, function(tx)
			captured.depsTx[Badges].award(tx, "first")
			error("discard")
		end)
		local _ = ok
		h:tick(30)
		expect(h:use(Badges).has(p, "first")).toBe(false)
		expect(calls(fake, "AwardBadgeAsync")).toBe(0)
		h:removePlayer(p)
		expect(h:saved(p).badges.awarded.first).toBe(nil)
	end)

	it("console: list, pending, and reset (Studio only, clears our record only)", function()
		local h = boot({
			badges = {
				badges = { first = { id = 101, trigger = MANUAL }, soon = { id = 0, trigger = MANUAL } },
			},
		})
		local p = h:addPlayer({ userId = 1 })
		h:use(Badges).award(p, "first")
		h:use(Badges).award(p, "soon")
		local list = h:console("badges list")
		expect(list).toContain("first (101): sent")
		expect(list).toContain("soon (0): pending")
		expect(h:console("badges pending 1")).toBe("soon (0): pending")
		expect(h:console("badges reset first")).toBe("badges reset is Studio-only")
		expect(h:use(Badges).has(p, "first")).toBe(true)

		local hs = boot({ badges = { badges = { first = { id = 101, trigger = MANUAL } } }, isStudio = true })
		local ps = hs:addPlayer({ userId = 1 })
		hs:use(Badges).award(ps, "first")
		expect(hs:console("badges reset first 1")).toContain("cleared our record of first")
		expect(hs:use(Badges).has(ps, "first")).toBe(false)
	end)

	it("the replicated state carries the awarded keys; the client part reads earned() from it", function()
		local h = boot({ badges = { badges = { first = { id = 101, trigger = MANUAL } } } })
		local p = h:addPlayer({ userId = 1 })
		h:use(Badges).award(p, "first")
		local state = h:state(p)
		local client = require("packages/kits/engagement/Badges/client/init.luau")
		expect(client.earnedFrom(state)).toEqual({ first = true })
		expect(client.earnedFrom(nil)).toEqual({})
	end)
end)
