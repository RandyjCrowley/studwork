--!nocheck
--[[
	Notifications: the whole flow on the plain harness, mocked (the Open Cloud fake, the in-memory sorted
	maps, the harness clock). Nothing calls Roblox. The multi-server flow is NotificationsSim.spec.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Harness = require("packages/framework/test/harness.luau")
local Loader = require("packages/framework/server/Loader.luau") -- the live part lookup (§19.9)

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Notifications = require(Modules:WaitForChild("Notifications"):WaitForChild("module"))
local Streak = require(Modules:WaitForChild("Streak"):WaitForChild("module"))

local HOUR, DAY = 3600, 86400
local NOON = 19000 * DAY + 12 * HOUR -- a UTC noon, years before the real clock
local SECRET = "OpenCloudNotifications"
local ALLOW = {
	[SECRET] = { modules = { "Notifications" }, methods = { "POST" }, paths = { "users/*/notifications" } },
}

local TEMPLATES = {
	eggReady = { messageId = "1001", params = { pet = "string" }, category = "egg" },
	plain = { messageId = "1002", cooldownHours = 0, cancelOnJoin = false },
	sticky = { messageId = "1003", cooldownHours = 0 },
	blank = { messageId = "" },
	streakEnding = { messageId = "1004", hoursBefore = 4, minStreak = 2 },
	prompting = { messageId = "1005", promptOnSchedule = true, cooldownHours = 0 },
}

-- opts: config (merged over the test defaults), key (false = no secret), allow (false = no allow-list),
-- streak (add Streak), census, storeBudgets, isStudio, flags, flagName
local function boot(opts)
	opts = opts or {}
	local oc = StudWork.test.fakes.openCloud()
	local part = Loader.defaultLoadServer(
		{ name = "Notifications", server = "Notifications" },
		nil,
		{ bindNet = false }
	)
	local log = {}
	part.net = {
		PromptOptIn = Harness.fakeEvent("PromptOptIn", log),
		OptInShown = Harness.fakeEvent("OptInShown", log),
		SetUtcOffset = Harness.fakeEvent("SetUtcOffset", log),
	}
	local config = {
		templates = TEMPLATES,
		schedule = { shards = 1, pollSeconds = 30 },
		limits = { perPlayerPerDay = 5, minGapHours = 0, perServerPerMinute = 60 },
		optIn = { minSessionSeconds = 180, minSessions = 1 },
	}
	for section, values in opts.config or {} do
		if type(values) == "table" and type(config[section]) == "table" and section ~= "templates" then
			for k, v in values do
				config[section][k] = v
			end
		else
			config[section] = values
		end
	end
	local modules = { Notifications }
	local servers = { Notifications = part }
	local moduleConfig = { Notifications = config }
	if opts.streak then
		table.insert(modules, 1, Streak)
		servers.Streak = Loader.defaultLoadServer({ name = "Streak", server = "Streak" })
		moduleConfig.Streak = { streak = { graceHours = 6 } }
	end
	local h = Harness.new({
		modules = modules,
		servers = servers,
		config = moduleConfig,
		startTime = opts.startTime or NOON,
		openCloud = oc,
		secrets = if opts.key == false then nil else { [SECRET] = true },
		serverConfig = { openCloud = { secrets = if opts.allow == false then {} else ALLOW } },
		census = opts.census,
		-- these specs are about the module's rules, not the per-minute request cap of a server with no
		-- players (20 units; covered in NotificationsStores.spec.luau): leave room unless a spec sets it
		storeBudgets = opts.storeBudgets or { memoryUnits = { base = 100000, perPlayer = 0 } },
		isStudio = opts.isStudio,
		flags = opts.flags,
		env = if opts.flags then "live" else nil,
	})
	local api = h:use(Notifications)
	local heard = { sent = {}, prompted = {}, launched = {} }
	api.signals.Sent:Connect(function(userId, key)
		table.insert(heard.sent, { userId, key })
	end)
	api.signals.OptInPrompted:Connect(function(player)
		table.insert(heard.prompted, player.UserId)
	end)
	api.signals.LaunchedFrom:Connect(function(player, key)
		table.insert(heard.launched, { player.UserId, key })
	end)
	return h, api, oc, log, heard
end

-- Jumps the clock and lets every server poll once (the first poll is at most pollSeconds away).
local function poll(h, seconds)
	h.clock += seconds or 61
	h:tick(1)
end

local function ledger(h, userId)
	for _, e in h:sortedMap("Notifications", "ledger/0").entries() do
		if e.key == tostring(userId) then
			return e.value
		end
	end
	return nil
end

-- The player's notifications section as the framework holds it (what ctx.data.get returns).
local function saved(h, p)
	return h.runtime.data.view(p, "notifications")
end

local function dueKeys(h)
	local out = {}
	for _, e in h:sortedMap("Notifications", "due/0").entries() do
		table.insert(out, e.key)
	end
	return out
end

local function warnings(h, needle)
	local n = 0
	for _, l in h.logs do
		if string.find(l.msg, needle, 1, true) then
			n += 1
		end
	end
	return n
end

describe("Notifications: send", function()
	it("makes one Open Cloud request with the documented body and counts it after the 2xx", function()
		local h, api, oc, _, heard = boot()
		local ok, reason = api.send(7, "eggReady", { pet = "Rex" })
		expect(ok).toBe(true)
		expect(reason).toBe(nil)
		expect(#oc.requests).toBe(1)
		local req = oc.requests[1]
		expect(req.secret).toBe(SECRET) -- the NAME, never a value
		expect(req.method).toBe("POST")
		expect(req.path).toBe("users/7/notifications")
		expect(req.body.payload.messageId).toBe("1001")
		expect(req.body.payload.type).toBe("MOMENT")
		expect(req.body.payload.parameters.pet.stringValue).toBe("Rex")
		expect(req.body.payload.analyticsData.category).toBe("egg")
		expect(req.body.payload.joinExperience.launchData).toBe("sw1:eggReady")
		expect(req.body.source.universe).toBe("universes/0")
		local entry = ledger(h, 7)
		expect(entry.c).toBe(1)
		expect(entry.l).toBe(NOON)
		expect(entry.t.eggReady).toBe(NOON)
		expect(entry.r).toBe(nil)
		expect(heard.sent).toEqual({ { 7, "eggReady" } })
	end)

	it("never logs the params and sends analytics only for a player on this server", function()
		local h, api = boot()
		local p = h:addPlayer({ userId = 7 })
		api.send(7, "eggReady", { pet = "SecretPetName" })
		expect(warnings(h, "SecretPetName")).toBe(0)
		local seen = nil
		for _, a in h.fake.analytics do
			if a.kind == "custom" and a.name == "NotificationSent" then
				seen = a
			end
		end
		expect(seen.player).toBe(p)
		expect(seen.fields.category).toBe("egg")
		for _, a in h.fake.analytics do
			expect(a.fields == nil or a.fields.pet == nil).toBe(true)
		end
	end)

	it("refuses a recipient over the day limit, the gap and the template cooldown", function()
		local h, api, oc = boot({ config = { limits = { perPlayerPerDay = 2, minGapHours = 1 } } })
		expect(api.send(7, "plain")).toBe(true)
		local ok, reason = api.send(7, "plain")
		expect(ok).toBe(false)
		expect(reason).toBe("rate_limited") -- the 1 h gap
		poll(h, 3601)
		expect(api.send(7, "plain")).toBe(true)
		expect(select(2, api.send(7, "plain"))).toBe("rate_limited")
		poll(h, 3601)
		expect(select(2, api.send(7, "plain"))).toBe("rate_limited") -- 2 a day
		expect(#oc.requests).toBe(2)
		expect(ledger(h, 7).c).toBe(2)

		local h2, api2, oc2 = boot({ config = { limits = { minGapHours = 0 } } })
		expect(api2.send(8, "eggReady", { pet = "a" })).toBe(true)
		local _, why = api2.send(8, "eggReady", { pet = "b" })
		expect(why).toBe("cooldown") -- eggReady's 24 h
		expect(api2.send(8, "plain")).toBe(true)
		expect(#oc2.requests).toBe(2)
		poll(h2, 25 * HOUR)
		expect(api2.send(8, "eggReady", { pet = "b" })).toBe(true)
	end)

	it("validates the user, the template and the params without touching anything", function()
		local _, api, oc = boot()
		expect(select(2, api.send(0, "plain"))).toBe("bad_params")
		expect(select(2, api.send(1.5, "plain"))).toBe("bad_params")
		expect(select(2, api.send(7, "nope"))).toBe("unknown_template")
		expect(select(2, api.send(7, "eggReady"))).toBe("bad_params")
		expect(select(2, api.send(7, "eggReady", { pet = "a", extra = "b" }))).toBe("bad_params")
		expect(select(2, api.send(7, "plain", { stray = "x" }))).toBe("bad_params")
		expect(#oc.requests).toBe(0)
	end)

	it("a placeholder messageId sends nothing, counts nothing and warns once", function()
		local h, api, oc = boot()
		local ok, reason = api.send(7, "blank")
		expect(ok).toBe(false)
		expect(reason).toBe("placeholder")
		api.send(8, "blank")
		expect(#oc.requests).toBe(0)
		expect(ledger(h, 7)).toBe(nil)
		expect(warnings(h, "template 'blank' has messageId = \"\"")).toBe(1)
		-- scheduling it is limited as usual (and sends nothing when due)
		expect(api.schedule(9, "blank", NOON + 600)).toBe(true)
		poll(h, 700)
		expect(#oc.requests).toBe(0)
		expect(#dueKeys(h)).toBe(0)
		expect(ledger(h, 9).q).toEqual({})
		expect(ledger(h, 9).c).toBe(0)
	end)

	it("a placeholder still honours the recipient's limits", function()
		local h, api = boot({ config = { limits = { perPlayerPerDay = 1, minGapHours = 0 } } })
		api.send(7, "plain")
		expect(select(2, api.send(7, "blank"))).toBe("rate_limited")
		expect(h).never.toBe(nil)
	end)

	it("without a key logs once, answers no_secret and never errors", function()
		local h, api, oc = boot({ key = false })
		expect(warnings(h, "unavailable")).toBe(0) -- nothing at boot: the log comes with the first send
		for i = 1, 3 do
			local ok, reason = api.send(i, "plain")
			expect(ok).toBe(false)
			expect(reason).toBe("no_secret")
		end
		expect(warnings(h, "unavailable (no_secret)")).toBe(1)
		expect(#oc.requests).toBe(0)
		expect(ledger(h, 1)).toBe(nil)
		-- scheduling still works: the entry waits for the key
		expect(api.schedule(1, "plain", NOON + 60)).toBe(true)
		poll(h, 100)
		expect(#oc.requests).toBe(0)
		expect(#dueKeys(h)).toBe(1)
	end)

	it("without the ServerConfig allow-list answers not_allowed and makes no request", function()
		local h, api, oc = boot({ allow = false })
		local ok, reason = api.send(7, "plain")
		expect(ok).toBe(false)
		expect(reason).toBe("not_allowed")
		expect(#oc.requests).toBe(0)
		expect(warnings(h, "unavailable (not_allowed)")).toBe(1)
	end)

	it("in Studio it logs would-send and sends nothing unless sendInStudio", function()
		local h, api, oc = boot({ isStudio = true })
		local ok, reason = api.send(7, "plain")
		expect(ok).toBe(false)
		expect(reason).toBe("studio")
		expect(warnings(h, "would send plain to 7")).toBe(1)
		expect(#oc.requests).toBe(0)
		local _, api2, oc2 = boot({ isStudio = true, config = { sendInStudio = true } })
		expect(api2.send(7, "plain")).toBe(true)
		expect(#oc2.requests).toBe(1)
	end)

	it("a flag that is off is a kill switch: nothing sent, scheduled or prompted", function()
		local flags = { notify = { default = false, live = false } }
		local h, api, oc, log = boot({ flags = flags, config = { flag = "notify" } })
		expect(select(2, api.send(7, "plain"))).toBe("disabled")
		expect(select(2, api.schedule(7, "plain", NOON + 60))).toBe("disabled")
		local p = h:addPlayer({ userId = 1 })
		h:rejoin(p, { secondsAway = 300 })
		poll(h, 400)
		expect(api.suggestOptIn(p, "x")).toBe(false)
		expect(#oc.requests).toBe(0)
		expect(#log).toBe(0)
		local _, on = boot({
			flags = { notify = { default = true, live = true } },
			config = { flag = "notify" },
		})
		expect(on.send(7, "plain")).toBe(true)
	end)

	it("an undeclared flag name keeps the module off and says so once", function()
		local h, api = boot({ flags = { other = { default = true } }, config = { flag = "missing" } })
		expect(select(2, api.send(7, "plain"))).toBe("disabled")
		expect(select(2, api.send(7, "plain"))).toBe("disabled")
		expect(warnings(h, "'missing' is not declared")).toBe(1)
	end)

	it("a bad template in config is ignored with one log line, the others work", function()
		local h, api = boot({
			config = {
				templates = { good = { messageId = "9" }, ["bad key"] = { messageId = "1" }, noid = {} },
			},
		})
		expect(api.send(7, "good")).toBe(true)
		expect(select(2, api.send(7, "noid"))).toBe("unknown_template")
		expect(warnings(h, "the template is ignored")).toBe(2)
	end)

	it("sends once per server minute at most perServerPerMinute", function()
		local h, api, oc = boot({ config = { limits = { perServerPerMinute = 2 } } })
		expect(api.send(1, "plain")).toBe(true)
		expect(api.send(2, "plain")).toBe(true)
		expect(select(2, api.send(3, "plain"))).toBe("server_budget")
		expect(#oc.requests).toBe(2)
		poll(h, 61)
		expect(api.send(3, "plain")).toBe(true)
	end)
end)

describe("Notifications: failures and retries", function()
	it(
		"a 5xx or a network error queues the send with its attempt count; the ledger doesn't count it",
		function()
			local h, api, oc = boot()
			oc.failNext(1, 503)
			local ok, reason = api.send(7, "plain")
			expect(ok).toBe(true)
			expect(reason).toBe("queued")
			expect(ledger(h, 7).c).toBe(0)
			expect(ledger(h, 7).r).toBe(nil)
			expect(dueKeys(h)).toEqual({ "7/plain" })
			local entry = h:sortedMap("Notifications", "due/0").entries()[1]
			expect(entry.value.n).toBe(1)
			expect(entry.sortKey).toBe(NOON + 30) -- base 30 s
			poll(h, 31)
			expect(#oc.requests).toBe(2)
			expect(ledger(h, 7).c).toBe(1)
			expect(#dueKeys(h)).toBe(0)
			oc.raiseNext(1)
			expect(select(2, api.send(8, "plain"))).toBe("queued")
		end
	)

	it("backs off 30, 60, 120 s and gives up after retry.attempts with NotificationFailed", function()
		local h, api, oc = boot({ config = { retry = { base = 30, factor = 2, max = 900, attempts = 4 } } })
		local p = h:addPlayer({ userId = 7 })
		oc.respond(503)
		expect(select(2, api.send(7, "plain"))).toBe("queued")
		local map = h:sortedMap("Notifications", "due/0")
		expect(map.entries()[1].sortKey).toBe(NOON + 30)
		poll(h, 31)
		expect(map.entries()[1].value.n).toBe(2)
		expect(map.entries()[1].sortKey).toBe(NOON + 32 + 60) -- the poll ran at the first tick after the jump
		local t = map.entries()[1].sortKey
		h.clock = t
		h:tick(1)
		expect(map.entries()[1].value.n).toBe(3)
		h.clock = map.entries()[1].sortKey
		h:tick(1)
		expect(#dueKeys(h)).toBe(0) -- the 4th attempt failed: dropped
		expect(#oc.requests).toBe(4)
		expect(ledger(h, 7).c).toBe(0)
		expect(ledger(h, 7).q).toEqual({})
		local failed = nil
		for _, a in h.fake.analytics do
			if a.name == "NotificationFailed" then
				failed = a
			end
		end
		expect(failed.player).toBe(p)
		expect(failed.fields.reason).toBe("failed")
	end)

	it("a 4xx other than 429 is refused and not retried; a 429 is retried", function()
		local h, api, oc = boot()
		oc.respondNext(400)
		local ok, reason = api.send(7, "plain")
		expect(ok).toBe(false)
		expect(reason).toBe("refused")
		expect(#dueKeys(h)).toBe(0)
		expect(ledger(h, 7).c).toBe(0)
		oc.respondNext(429)
		expect(select(2, api.send(8, "plain"))).toBe("queued")
	end)

	it("a due entry that is refused is removed, not retried", function()
		local h, api, oc = boot()
		api.schedule(7, "plain", NOON + 60)
		oc.respondNext(403)
		poll(h, 100)
		expect(#oc.requests).toBe(1)
		expect(#dueKeys(h)).toBe(0)
		expect(ledger(h, 7).q).toEqual({})
		poll(h, 100)
		expect(#oc.requests).toBe(1)
	end)

	it("a store failure on the ledger is a reason, not an error", function()
		local h, api, oc = boot()
		h:sortedMap("Notifications", "ledger/0").failNext(9)
		expect(select(2, api.send(7, "plain"))).toBe("store_busy")
		expect(select(2, api.schedule(7, "plain", NOON + 60))).toBe("store_busy")
		expect(#oc.requests).toBe(0)
		local h2, api2 = boot()
		h2:sortedMap("Notifications", "ledger/0").failNext(1, "TotalMemoryOverLimit")
		expect(select(2, api2.schedule(7, "plain", NOON + 60))).toBe("memory_budget")
		local h3, api3 = boot()
		h3:sortedMap("Notifications", "due/0").failNext(9)
		expect(select(2, api3.schedule(7, "plain", NOON + 60))).toBe("store_busy")
		expect(ledger(h3, 7).q).toEqual({}) -- the ledger write was rolled back
	end)
end)

describe("Notifications: quiet hours", function()
	it("moves a send inside quiet hours to the recipient's endHour", function()
		local h, api, oc = boot({ startTime = 19000 * DAY + 23 * HOUR })
		local ok, reason = api.send(7, "plain")
		expect(ok).toBe(true)
		expect(reason).toBe("scheduled")
		expect(#oc.requests).toBe(0)
		expect(h:sortedMap("Notifications", "due/0").entries()[1].sortKey).toBe(19001 * DAY + 8 * HOUR)
		poll(h, 5 * HOUR)
		expect(#oc.requests).toBe(0) -- 04:00 is still quiet
		h.clock = 19001 * DAY + 8 * HOUR
		poll(h, 31)
		expect(#oc.requests).toBe(1)
	end)

	it("uses the offset the client reported", function()
		-- 14:00 UTC is 23:00 at UTC+9: quiet there, not at UTC
		local h, api, oc = boot({ startTime = 19000 * DAY + 14 * HOUR })
		local p = h:addPlayer({ userId = 7 })
		expect(api.send(7, "plain")).toBe(true)
		expect(#oc.requests).toBe(1)
		h:action(p, Notifications, "setUtcOffset", 9)
		expect(select(2, api.send(7, "sticky"))).toBe("scheduled")
		expect(#oc.requests).toBe(1)
		expect(saved(h, p).utcOffset).toBe(9)
	end)

	it("a due entry inside quiet hours is re-keyed, not sent", function()
		local h, api, oc = boot({ startTime = 19000 * DAY + 20 * HOUR })
		api.schedule(7, "plain", 19000 * DAY + 22 * HOUR + 600)
		poll(h, 2 * HOUR + 700) -- 22:10+, quiet
		expect(#oc.requests).toBe(0)
		expect(h:sortedMap("Notifications", "due/0").entries()[1].sortKey).toBe(19001 * DAY + 8 * HOUR)
	end)

	it("setUtcOffset validates and rounds", function()
		local h = boot()
		local p = h:addPlayer({ userId = 7 })
		h:action(p, Notifications, "setUtcOffset", "9")
		h:action(p, Notifications, "setUtcOffset", 99)
		expect(saved(h, p).utcOffset).toBe(nil)
		h.clock += 20
		h:action(p, Notifications, "setUtcOffset", 5.4)
		expect(saved(h, p).utcOffset).toBe(5.5)
	end)
end)

describe("Notifications: scheduled sends", function()
	it("one request when due, none before, the entry gone after, counted once", function()
		local h, api, oc = boot()
		expect(api.schedule(7, "eggReady", NOON + 1800, { pet = "Rex" })).toBe(true)
		expect(dueKeys(h)).toEqual({ "7/eggReady" })
		local entry = h:sortedMap("Notifications", "due/0").entries()[1]
		expect(entry.sortKey).toBe(NOON + 1800)
		expect(entry.value.k).toBe("eggReady")
		expect(entry.value.p.pet).toBe("Rex")
		expect(ledger(h, 7).q.eggReady).toBe(NOON + 1800)
		poll(h, 600)
		expect(#oc.requests).toBe(0)
		poll(h, 1300)
		expect(#oc.requests).toBe(1)
		expect(oc.requests[1].body.payload.parameters.pet.stringValue).toBe("Rex")
		expect(#dueKeys(h)).toBe(0)
		expect(ledger(h, 7).c).toBe(1)
		expect(ledger(h, 7).q).toEqual({})
		poll(h, 100)
		poll(h, 100)
		expect(#oc.requests).toBe(1)
	end)

	it("rescheduling the same key moves the entry", function()
		local h, api, oc = boot()
		api.schedule(7, "plain", NOON + 600)
		api.schedule(7, "plain", NOON + 7200)
		expect(#dueKeys(h)).toBe(1)
		poll(h, 700)
		expect(#oc.requests).toBe(0)
		poll(h, 7200)
		expect(#oc.requests).toBe(1)
	end)

	it("an explicit key keeps two entries of one template apart", function()
		local h, api = boot()
		api.schedule(7, "plain", NOON + 600, nil, "a")
		api.schedule(7, "plain", NOON + 600, nil, "b")
		expect(#dueKeys(h)).toBe(2)
		expect(select(2, api.schedule(7, "plain", NOON + 600, nil, "bad key"))).toBe("bad_params")
	end)

	it("maxPerPlayer holds for a recipient on no server; a replaced key doesn't count twice", function()
		local h, api = boot({ config = { schedule = { maxPerPlayer = 3 } } })
		for i = 1, 3 do
			expect(api.schedule(7, "plain", NOON + 600 * i, nil, "k" .. i)).toBe(true)
		end
		local ok, reason = api.schedule(7, "plain", NOON + 9000, nil, "k4")
		expect(ok).toBe(false)
		expect(reason).toBe("too_many")
		expect(api.schedule(7, "plain", NOON + 9000, nil, "k2")).toBe(true)
		expect(#dueKeys(h)).toBe(3)
		expect(api.schedule(8, "plain", NOON + 600)).toBe(true) -- another recipient
		expect(h.players[7]).toBe(nil)
	end)

	it("maxAheadHours refuses too_far", function()
		local _, api = boot({ config = { schedule = { maxAheadHours = 24 } } })
		expect(api.schedule(7, "plain", NOON + 24 * HOUR)).toBe(true)
		expect(select(2, api.schedule(7, "plain", NOON + 24 * HOUR + 60, nil, "z"))).toBe("too_far")
	end)

	it("every entry stays inside the 8-day quota window", function()
		local h, api = boot()
		expect(api.schedule(7, "plain", NOON + 168 * HOUR)).toBe(true)
		local e = h:sortedMap("Notifications", "due/0").entries()[1]
		expect(e.expiresAt - NOON <= 8 * DAY).toBe(true)
		local led = h:sortedMap("Notifications", "ledger/0").entries()[1]
		expect(led.expiresAt - NOON <= 8 * DAY).toBe(true)
		expect(led.expiresAt >= e.expiresAt).toBe(true)
	end)

	it(
		"an entry nobody polled for staleAfterHours is dropped, not sent, and stops counting against maxPerPlayer",
		function()
			local h, api, oc = boot({ config = { schedule = { staleAfterHours = 1, maxPerPlayer = 1 } } })
			api.schedule(7, "plain", NOON + 600)
			expect(select(2, api.schedule(7, "plain", NOON + 700, nil, "other"))).toBe("too_many")
			poll(h, 3 * HOUR) -- no server polled for hours: the entry expired in the map
			expect(#oc.requests).toBe(0)
			expect(#dueKeys(h)).toBe(0)
			expect(api.schedule(7, "plain", h.clock + 600, nil, "other")).toBe(true)
		end
	)

	it("a row another server claimed after this one read it is not sent (the claim is atomic)", function()
		local h, api, oc = boot()
		api.schedule(7, "plain", NOON + 600)
		local backend = h:sortedMap("Notifications", "due/0")
		local range = backend.range
		backend.range = function(...)
			local rows = range(...)
			-- between our read and our claim, another server claims the entry (its lease)
			backend.update("7/plain", function(old)
				old.c = "other-server"
				return old, h.clock + 90
			end, 600)
			return rows
		end
		poll(h, 700)
		backend.range = range
		expect(#oc.requests).toBe(0)
		expect(dueKeys(h)).toEqual({ "7/plain" })
		-- once that lease has run out any server (here: this one) takes it
		poll(h, 100)
		expect(#oc.requests).toBe(1)
	end)

	it("cancel removes both the entry and the ledger key", function()
		local h, api, oc = boot()
		api.schedule(7, "plain", NOON + 600)
		expect(api.cancel(7, "plain")).toBe(true)
		expect(api.cancel(7, "plain")).toBe(false)
		expect(api.cancel(7, "bad key")).toBe(false)
		expect(#dueKeys(h)).toBe(0)
		expect(ledger(h, 7).q).toEqual({})
		poll(h, 1000)
		expect(#oc.requests).toBe(0)
	end)

	it("cancelOnJoin cancels waiting entries of templates that ask for it, only", function()
		local h, api, oc = boot()
		api.schedule(7, "sticky", NOON + 600) -- cancelOnJoin defaults to true
		api.schedule(7, "plain", NOON + 600) -- cancelOnJoin = false
		h:addPlayer({ userId = 7 })
		expect(dueKeys(h)).toEqual({ "7/plain" })
		poll(h, 700)
		expect(#oc.requests).toBe(1)
		expect(oc.requests[1].body.payload.messageId).toBe("1002")
	end)

	it("two scheduled entries for one recipient go out one per limit window", function()
		local h, api, oc = boot({
			config = {
				limits = { perPlayerPerDay = 1, minGapHours = 0 },
				schedule = { staleAfterHours = 48 },
			},
		})
		api.schedule(7, "plain", NOON + 600, nil, "a")
		api.schedule(7, "plain", NOON + 600, nil, "b")
		poll(h, 700)
		expect(#oc.requests).toBe(1)
		-- the second was re-keyed to the next UTC day
		local keys = h:sortedMap("Notifications", "due/0").entries()
		expect(#keys).toBe(1)
		expect(keys[1].sortKey).toBe(19001 * DAY)
		h.clock = 19001 * DAY
		poll(h, 100)
		expect(#oc.requests).toBe(1) -- 00:01 is quiet
		h.clock = 19001 * DAY + 8 * HOUR
		poll(h, 61)
		expect(#oc.requests).toBe(2)
	end)

	it("the poll rate follows the census, not the clock", function()
		local function rangeCalls(census, seconds)
			local h = boot({ census = census, config = { schedule = { pollsPerShardPerMinute = 20 } } })
			local map = h:sortedMap("Notifications", "due/0")
			local before = 0
			for _, c in map.calls do
				if c.op == "range" then
					before += 1
				end
			end
			h:tick(seconds)
			local n = 0
			for _, c in map.calls do
				if c.op == "range" then
					n += 1
				end
			end
			return n - before
		end
		local few = rangeCalls({ servers = 1, players = 1 }, 300)
		local many = rangeCalls({ servers = 600, players = 600 }, 300)
		expect(few >= 9).toBe(true) -- every pollSeconds (30)
		expect(many <= 1).toBe(true) -- every 60 x 600 / (1 x 20) = 1800 s
	end)
end)

describe("Notifications: opt-in", function()
	local function second(h)
		local p = h:addPlayer({ userId = 1 })
		h:rejoin(p, { secondsAway = 600 }) -- the second session
		return p
	end

	local function prompts(log)
		local out = {}
		for _, e in log do
			if e.event == "PromptOptIn" then
				table.insert(out, e)
			end
		end
		return out
	end

	it("never on join: refused before minSessionSeconds, then the client is asked once", function()
		local h, api, _, log = boot()
		local p = second(h)
		expect(api.suggestOptIn(p, "egg")).toBe(false)
		h:tick(179)
		expect(api.suggestOptIn(p, "egg")).toBe(false)
		h:tick(2)
		expect(api.suggestOptIn(p, "egg")).toBe(true)
		local asked = prompts(log)
		expect(#asked).toBe(1)
		expect(asked[1].player).toBe(p)
		local id = asked[1].args[1]
		expect(type(id)).toBe("string")
		expect(#id >= 1 and #id <= 64).toBe(true)
		expect(api.suggestOptIn(p, "egg")).toBe(false) -- once a session
		expect(#prompts(log)).toBe(1)
	end)

	it("the first session may not prompt while minSessions = 1", function()
		local h, api = boot()
		local p = h:addPlayer({ userId = 1 })
		h:tick(500)
		expect(api.suggestOptIn(p, "egg")).toBe(false)
		local h2, api2 = boot({ config = { optIn = { minSessions = 0 } } })
		local p2 = h2:addPlayer({ userId = 1 })
		h2:tick(181)
		expect(api2.suggestOptIn(p2, "egg")).toBe(true)
	end)

	it("accepts optInShown only for the outstanding requestId, once", function()
		local h, api, _, log, heard = boot()
		local p = second(h)
		h:tick(200)
		api.suggestOptIn(p, "egg")
		local id = prompts(log)[1].args[1]
		h.clock += 1
		h:action(p, Notifications, "optInShown", "forged", true)
		h:action(p, Notifications, "optInShown", id, "yes")
		h:action(p, Notifications, "optInShown", 5, true)
		expect(saved(h, p).prompts).toBe(0)
		expect(#heard.prompted).toBe(0)
		h.clock += 1
		h:action(p, Notifications, "optInShown", id, true)
		local save = saved(h, p)
		expect(save.prompts).toBe(1)
		expect(save.lastPromptAt).toBe(h.clock)
		expect(save.promptRequest).toBe(nil)
		expect(heard.prompted).toEqual({ 1 })
		h.clock += 5
		h:action(p, Notifications, "optInShown", id, true) -- replay: nothing outstanding
		expect(saved(h, p).prompts).toBe(1)
		expect(#heard.prompted).toBe(1)
	end)

	it("not shown by Roblox counts no prompt but waits cooldownDays for the next ask", function()
		local h, api, _, log = boot()
		local p = second(h)
		h:tick(200)
		api.suggestOptIn(p, "egg")
		h.clock += 1
		h:action(p, Notifications, "optInShown", prompts(log)[1].args[1], false)
		expect(saved(h, p).prompts).toBe(0)
		expect(saved(h, p).lastPromptAt > 0).toBe(true)
		h:rejoin(p, { secondsAway = 3600 })
		h:tick(200)
		expect(api.suggestOptIn(p, "egg")).toBe(false) -- cooldown
		h:rejoin(p, { secondsAway = 31 * DAY })
		h:tick(200)
		expect(api.suggestOptIn(p, "egg")).toBe(true)
	end)

	it("stops at maxPrompts", function()
		local h, api, _, log = boot({ config = { optIn = { maxPrompts = 1, cooldownDays = 0 } } })
		local p = second(h)
		h:tick(200)
		api.suggestOptIn(p, "egg")
		h.clock += 1
		h:action(p, Notifications, "optInShown", prompts(log)[1].args[1], true)
		h:rejoin(p, { secondsAway = 3600 })
		h:tick(200)
		expect(api.suggestOptIn(p, "egg")).toBe(false)
	end)

	it("onSuggest = false refuses suggestions; promptOnSchedule still prompts", function()
		local h, api, _, log = boot({ config = { optIn = { onSuggest = false } } })
		local p = second(h)
		h:tick(200)
		expect(api.suggestOptIn(p, "egg")).toBe(false)
		expect(api.schedule(1, "prompting", NOON + 100000)).toBe(true)
		expect(#prompts(log)).toBe(1)
	end)

	it("does nothing for a player whose data isn't loaded or without the Blink event", function()
		local h, api = boot()
		expect(api.suggestOptIn({ UserId = 99 }, "egg")).toBe(false)
		expect(api.suggestOptIn(nil, "egg")).toBe(false)
		expect(h).never.toBe(nil)
	end)
end)

describe("Notifications: join data", function()
	local function joinWith(h, userId, launchData)
		local p = Harness.player(userId)
		function p.GetJoinData()
			return { LaunchData = launchData }
		end
		h.players[userId] = p
		return h:addPlayer({ userId = userId })
	end

	it("a valid sw1:<template> fires LaunchedFrom and one NotificationJoin a UTC day", function()
		local h, _, _, _, heard = boot()
		local p = joinWith(h, 7, "sw1:eggReady")
		expect(heard.launched).toEqual({ { 7, "eggReady" } })
		h:rejoin(p, { secondsAway = 600 })
		expect(#heard.launched).toBe(2)
		local joins = 0
		for _, a in h.fake.analytics do
			if a.name == "NotificationJoin" then
				joins += 1
				expect(a.fields.category).toBe("egg")
			end
		end
		expect(joins).toBe(1)
		h:rejoin(p, { secondsAway = DAY })
		joins = 0
		for _, a in h.fake.analytics do
			if a.name == "NotificationJoin" then
				joins += 1
			end
		end
		expect(joins).toBe(2)
	end)

	it("a forged or malformed LaunchData fires nothing", function()
		local h, _, _, _, heard = boot()
		local n = 0
		for _, bad in
			{
				"sw1:unknown",
				"sw2:eggReady",
				"eggReady",
				"sw1:",
				"sw1:eggReady; grant",
				"sw1:" .. string.rep("a", 300),
				"",
			}
		do
			n += 1
			joinWith(h, 100 + n, bad)
		end
		expect(#heard.launched).toBe(0)
		local analytics = 0
		for _, a in h.fake.analytics do
			if a.name == "NotificationJoin" then
				analytics += 1
			end
		end
		expect(analytics).toBe(0)
	end)

	it("a join without GetJoinData, or with a non-table, is fine", function()
		local h, _, _, _, heard = boot()
		h:addPlayer({ userId = 7 })
		local p = Harness.player(8)
		function p.GetJoinData()
			return 5
		end
		h.players[8] = p
		h:addPlayer({ userId = 8 })
		expect(#heard.launched).toBe(0)
	end)
end)

describe("Notifications: Streak integration", function()
	it("schedules the reminder hoursBefore the end of the grace window when a long streak leaves", function()
		local h, _, oc = boot({ streak = true })
		local p = h:addPlayer({ userId = 7 })
		h:rejoin(p, { secondsAway = DAY }) -- day 2: streak 2
		local streak = h:use(Streak)
		expect(streak.get(p).day).toBe(2)
		local expires = streak.expiresAt(p)
		expect(expires).toBe((19001 + 2) * DAY + 6 * HOUR)
		h:removePlayer(p)
		local entry = h:sortedMap("Notifications", "due/0").entries()[1]
		expect(entry.key).toBe("7/streakEnding")
		expect(entry.sortKey).toBe(expires - 4 * HOUR)
		expect(entry.value.k).toBe("streakEnding")
		-- due at 02:00 local, inside quiet hours: it waits for 08:00 (the stale window is 12 h)
		h.clock = expires - 4 * HOUR
		poll(h, 31)
		expect(#oc.requests).toBe(0)
		expect(h:sortedMap("Notifications", "due/0").entries()[1].sortKey).toBe((19003 * DAY) + 8 * HOUR)
		h.clock = (19003 * DAY) + 8 * HOUR
		poll(h, 31)
		expect(#oc.requests).toBe(1)
		expect(oc.requests[1].body.payload.messageId).toBe("1004")
	end)

	it("is cancelled when the player returns first", function()
		local h, _, oc = boot({ streak = true })
		local p = h:addPlayer({ userId = 7 })
		h:rejoin(p, { secondsAway = DAY })
		h:removePlayer(p)
		expect(#dueKeys(h)).toBe(1)
		h.clock += 3 * HOUR
		h:addPlayer({ userId = 7 })
		expect(#dueKeys(h)).toBe(0)
		poll(h, 3 * DAY)
		expect(#oc.requests).toBe(0)
	end)

	it("skips a streak shorter than minStreak, and a reminder time already past", function()
		local h = boot({ streak = true })
		local p = h:addPlayer({ userId = 7 }) -- day 1
		h:removePlayer(p)
		expect(#dueKeys(h)).toBe(0)
		local h2 = boot({
			streak = true,
			config = { templates = { streakEnding = { messageId = "1", minStreak = 1, hoursBefore = 400 } } },
		})
		local p2 = h2:addPlayer({ userId = 7 })
		h2:removePlayer(p2)
		expect(#dueKeys(h2)).toBe(0)
	end)

	it("does nothing without a streakEnding template or without Streak", function()
		local h = boot({ streak = true, config = { templates = { plain = { messageId = "1" } } } })
		local p = h:addPlayer({ userId = 7 })
		h:rejoin(p, { secondsAway = DAY })
		h:removePlayer(p)
		expect(#dueKeys(h)).toBe(0)
		local h2 = boot()
		local p2 = h2:addPlayer({ userId = 7 })
		h2:rejoin(p2, { secondsAway = DAY })
		h2:removePlayer(p2)
		expect(#dueKeys(h2)).toBe(0)
	end)

	it("Streak.expiresAt is nil for a player whose save isn't loaded", function()
		local h = boot({ streak = true })
		local streak = h:use(Streak)
		expect(streak.expiresAt({ UserId = 5 })).toBe(nil)
	end)
end)

describe("Notifications: switched off", function()
	it(
		"a game that leaves the module out boots and runs; a module that listed it optional sees it off",
		function()
			local seen = {}
			local probe = StudWork.defineModule({
				name = "Probe",
				version = "1.0.0",
				framework = "^1.7.0",
				optional = { Notifications },
			})
			local h = Harness.new({
				modules = { probe },
				servers = {
					Probe = {
						init = function(ctx)
							seen.enabled = ctx.isEnabled(Notifications)
						end,
					},
				},
			})
			local p = h:addPlayer({ userId = 1 })
			h:tick(100)
			expect(seen.enabled).toBe(false)
			expect(p).never.toBe(nil)
		end
	)

	it("the module lists fine with no templates at all", function()
		local _, api, oc = boot({ config = { templates = {} } })
		expect(select(2, api.send(7, "anything"))).toBe("disabled")
		expect(select(2, api.schedule(7, "anything", NOON + 60))).toBe("disabled")
		expect(#oc.requests).toBe(0)
	end)
end)

describe("Notifications: the module's store budget (storeBudgets, module-api.md section 23.5)", function()
	it("schedule stops with memory_budget at the module's own memory share and recovers on cancel", function()
		-- a 1% share of the 64 KB quota (no players, no census): room for a few waiting entries
		local h, api = boot({
			storeBudgets = {
				memoryUnits = { base = 100000, perPlayer = 0 },
				memory = { shares = { Notifications = 0.01 } },
			},
		})
		local landed, firstFull = {}, nil
		for userId = 1, 40 do
			local ok, reason = api.schedule(userId, "plain", NOON + 3600)
			if ok then
				table.insert(landed, userId)
			else
				expect(reason).toBe("memory_budget")
				firstFull = firstFull or userId
			end
		end
		expect(#landed >= 1).toBe(true)
		expect(firstFull ~= nil).toBe(true)
		expect(#landed < 40).toBe(true)
		-- the refused one left nothing behind (its ledger write was rolled back), and the share
		-- holds: the same user is refused again
		expect(ledger(h, firstFull) == nil or next(ledger(h, firstFull).q) == nil).toBe(true)
		expect(select(2, api.schedule(firstFull, "plain", NOON + 3600))).toBe("memory_budget")
		-- a cancel gives its bytes back
		expect(api.cancel(landed[1], "plain")).toBe(true)
		expect(api.schedule(firstFull, "plain", NOON + 3600)).toBe(true)
	end)

	it("a roomy share (the default 25%) takes the same schedules", function()
		local _, api = boot({ storeBudgets = { memoryUnits = { base = 100000, perPlayer = 0 } } })
		for userId = 1, 40 do
			expect(api.schedule(userId, "plain", NOON + 3600)).toBe(true)
		end
	end)

	it(
		"a server with no players is held to its request units: store_busy, nothing sent, then it recovers",
		function()
			local h, api, oc = boot({ storeBudgets = {} }) -- the defaults: 20 units a minute with no players
			local sent, busy = 0, 0
			for userId = 1, 12 do
				local ok, reason = api.send(userId, "plain")
				if ok then
					sent += 1
				else
					expect(reason).toBe("store_busy")
					busy += 1
				end
			end
			expect(sent >= 1).toBe(true)
			expect(busy >= 1).toBe(true)
			expect(#oc.requests).toBe(sent) -- a refused ledger reservation never reaches Open Cloud
			h.clock += 61
			h:tick(1)
			expect(api.send(100, "plain")).toBe(true)
		end
	)
end)
