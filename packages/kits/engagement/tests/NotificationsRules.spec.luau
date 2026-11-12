--!nocheck
--[[
	Notifications: the pure rules (server/Quiet, Ledger, Templates, Sender, OptInRules, client/OptIn).
	No harness: numbers in, numbers out.
]]
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local server = ServerScriptService:WaitForChild("Modules"):WaitForChild("Notifications")
local Quiet = require(server:WaitForChild("Quiet"))
local Ledger = require(server:WaitForChild("Ledger"))
local Templates = require(server:WaitForChild("Templates"))
local Sender = require(server:WaitForChild("Sender"))
local OptInRules = require(server:WaitForChild("OptInRules"))
local OptIn = require(
	ReplicatedStorage:WaitForChild("Modules")
		:WaitForChild("Notifications")
		:WaitForChild("client")
		:WaitForChild("OptIn")
)

local DAY, HOUR = 86400, 3600
local D = 20000 * DAY -- a UTC midnight

describe("Quiet hours", function()
	it("22 -> 8 wraps midnight in the recipient's local time", function()
		expect(Quiet.inQuiet(D + 23 * HOUR, 0, 22, 8)).toBe(true)
		expect(Quiet.inQuiet(D + 3 * HOUR, 0, 22, 8)).toBe(true)
		expect(Quiet.inQuiet(D + 8 * HOUR, 0, 22, 8)).toBe(false)
		expect(Quiet.inQuiet(D + 21 * HOUR + 3599, 0, 22, 8)).toBe(false)
		-- 23:00 UTC is 04:00 at UTC+5, quiet; 15:00 UTC is 20:00 there, not
		expect(Quiet.inQuiet(D + 23 * HOUR, 5, 22, 8)).toBe(true)
		expect(Quiet.inQuiet(D + 15 * HOUR, 5, 22, 8)).toBe(false)
		expect(Quiet.inQuiet(D + 15 * HOUR, -8, 22, 8)).toBe(true) -- 07:00 local
		expect(Quiet.inQuiet(D + 17 * HOUR, -8, 22, 8)).toBe(false) -- 09:00 local
	end)

	it("a window inside one day, and no window at all", function()
		expect(Quiet.inQuiet(D + 13 * HOUR, 0, 12, 14)).toBe(true)
		expect(Quiet.inQuiet(D + 14 * HOUR, 0, 12, 14)).toBe(false)
		expect(Quiet.inQuiet(D + 13 * HOUR, 0, 9, 9)).toBe(false)
	end)

	it("nextOpen is the local endHour, and t itself outside quiet hours", function()
		expect(Quiet.nextOpen(D + 23 * HOUR, 0, 22, 8)).toBe(D + DAY + 8 * HOUR)
		expect(Quiet.nextOpen(D + 3 * HOUR, 0, 22, 8)).toBe(D + 8 * HOUR)
		expect(Quiet.nextOpen(D + 12 * HOUR, 0, 22, 8)).toBe(D + 12 * HOUR)
		expect(Quiet.nextOpen(D + 23 * HOUR, 5, 22, 8)).toBe(D + 3 * HOUR + DAY) -- 08:00 at UTC+5 = 03:00 UTC
		expect(Quiet.inQuiet(Quiet.nextOpen(D + 23 * HOUR, 5, 22, 8), 5, 22, 8)).toBe(false)
	end)

	it("a bad offset falls back to the default", function()
		expect(Quiet.offset(nil, 2)).toBe(2)
		expect(Quiet.offset(99, 2)).toBe(2)
		expect(Quiet.offset(0 / 0, 2)).toBe(2)
		expect(Quiet.offset(-5.5, 2)).toBe(-5.5)
	end)
end)

describe("Ledger", function()
	local rules = { perDay = 1, minGapSeconds = 20 * HOUR, cooldownSeconds = 24 * HOUR }
	local now = D + 12 * HOUR

	it("normalizes garbage into an empty entry", function()
		local e = Ledger.normalize("junk")
		expect(e.c).toBe(0)
		expect(next(e.q)).toBe(nil)
		local f = Ledger.normalize({ d = 3, q = { a = 5, b = "x" }, r = { by = 1 } })
		expect(f.q.a).toBe(5)
		expect(f.q.b).toBe(nil)
		expect(f.r).toBe(nil)
	end)

	it("a fresh recipient is allowed; one send fills the day and the gap", function()
		local e = Ledger.normalize(nil)
		expect((Ledger.check(e, "egg", rules, now, "me"))).toBe(true)
		local sent = Ledger.commit(Ledger.reserve(e, "me", now, 90), nil, "egg", now)
		expect(sent.c).toBe(1)
		expect(sent.r).toBe(nil)
		local ok, nextAt, reason = Ledger.check(sent, "other", rules, now + HOUR, "me")
		expect(ok).toBe(false)
		expect(reason).toBe("rate_limited")
		expect(nextAt).toBe(D + 32 * HOUR) -- the day count ends at midnight UTC, the 20 h gap at 08:00 next day: the later one
	end)

	it("the gap alone blocks across midnight; the cooldown names itself", function()
		local sent = Ledger.commit(Ledger.normalize(nil), nil, "egg", D + 23 * HOUR)
		local ok, nextAt, reason = Ledger.check(sent, "other", rules, D + DAY + HOUR, "me")
		expect(ok).toBe(false)
		expect(reason).toBe("rate_limited")
		expect(nextAt).toBe(D + 23 * HOUR + 20 * HOUR)
		local loose = { perDay = 5, minGapSeconds = 0, cooldownSeconds = 24 * HOUR }
		local ok2, at2, why2 = Ledger.check(sent, "egg", loose, D + 23 * HOUR + 60, "me")
		expect(ok2).toBe(false)
		expect(why2).toBe("cooldown")
		expect(at2).toBe(D + 47 * HOUR)
		expect((Ledger.check(sent, "other", loose, D + 23 * HOUR + 60, "me"))).toBe(true)
	end)

	it("a live reservation by another server blocks; an expired or own one doesn't", function()
		local e = Ledger.reserve(Ledger.normalize(nil), "a", now, 90)
		local ok, nextAt, reason = Ledger.check(e, "egg", rules, now + 10, "b")
		expect(ok).toBe(false)
		expect(reason).toBe("rate_limited")
		expect(nextAt).toBe(now + 90)
		expect((Ledger.check(e, "egg", rules, now + 10, "a"))).toBe(true)
		expect((Ledger.check(e, "egg", rules, now + 91, "b"))).toBe(true)
	end)

	it("the day count restarts the next UTC day", function()
		local loose = { perDay = 1, minGapSeconds = 0, cooldownSeconds = 0 }
		local sent = Ledger.commit(Ledger.normalize(nil), nil, "egg", D + HOUR)
		expect((Ledger.check(sent, "egg", loose, D + 2 * HOUR, "me"))).toBe(false)
		expect((Ledger.check(sent, "egg", loose, D + DAY + 1, "me"))).toBe(true)
		local again = Ledger.commit(sent, nil, "egg", D + DAY + 1)
		expect(again.c).toBe(1)
	end)

	it(
		"schedule enforces maxPerPlayer on other keys, replaces the same key and forgets stale ones",
		function()
			local e = Ledger.normalize(nil)
			for i = 1, 3 do
				e = Ledger.schedule(e, "k" .. i, now + i, now, 3, 12 * HOUR)
			end
			local refused, why = Ledger.schedule(e, "k4", now + 9, now, 3, 12 * HOUR)
			expect(refused).toBe(nil)
			expect(why).toBe("too_many")
			local moved = Ledger.schedule(e, "k2", now + 500, now, 3, 12 * HOUR)
			expect(moved.q.k2).toBe(now + 500)
			-- k1..k3 are all older than the stale window 13 h later: the new key fits
			local later = Ledger.schedule(e, "k4", now + 14 * HOUR, now + 13 * HOUR, 3, 12 * HOUR)
			expect(later.q.k4).toBe(now + 14 * HOUR)
			expect(later.q.k1).toBe(nil)
		end
	)

	it("cancel reports whether the key was waiting", function()
		local e = Ledger.schedule(Ledger.normalize(nil), "k", now, now, 3, 100)
		local back, had = Ledger.cancel(e, "k")
		expect(had).toBe(true)
		expect(back.q.k).toBe(nil)
		local _, hadNot = Ledger.cancel(back, "k")
		expect(hadNot).toBe(false)
	end)

	it("release gives back only the caller's reservation", function()
		local e = Ledger.reserve(Ledger.normalize(nil), "a", now, 90)
		expect(Ledger.release(e, "b", nil, false).r).never.toBe(nil)
		expect(Ledger.release(e, "a", nil, false).r).toBe(nil)
		local q = Ledger.schedule(e, "k", now, now, 3, 100)
		expect(Ledger.release(q, "a", "k", true).q.k).toBe(nil)
		expect(Ledger.release(q, "a", "k", false).q.k).toBe(now)
	end)

	it("expiry covers two days, the longest cooldown and every waiting entry", function()
		local e = Ledger.normalize(nil)
		expect(Ledger.expiry(e, nil, now, 12 * HOUR, 0)).toBe(2 * DAY)
		expect(Ledger.expiry(e, nil, now, 12 * HOUR, 3 * DAY)).toBe(3 * DAY)
		local waiting = Ledger.schedule(e, "k", now + 100 * HOUR, now, 3, 12 * HOUR)
		expect(Ledger.expiry(waiting, nil, now, 12 * HOUR, 0)).toBe(112 * HOUR)
		expect(Ledger.expiry(e, now + 200 * HOUR, now, 12 * HOUR, 0)).toBe(212 * HOUR)
		expect(Ledger.expiry(e, now + 99 * DAY, now, 12 * HOUR, 0)).toBe(Ledger.MAX_EXPIRY)
	end)
end)

describe("Templates", function()
	it("applies the defaults and marks a placeholder", function()
		local tpl = Templates.normalize("eggReady", { messageId = "" })
		expect(tpl.placeholder).toBe(true)
		expect(tpl.category).toBe("eggReady")
		expect(tpl.launch).toBe(true)
		expect(tpl.cooldownHours).toBe(24)
		expect(tpl.cancelOnJoin).toBe(true)
		expect(tpl.promptOnSchedule).toBe(false)
		expect(tpl.minStreak).toBe(3)
		expect(tpl.hoursBefore).toBe(4)
		local real = Templates.normalize("x", { messageId = 123456, category = "c", launch = false })
		expect(real.messageId).toBe("123456")
		expect(real.placeholder).toBe(false)
		expect(real.launch).toBe(false)
	end)

	it("rejects bad keys, missing messageId and bad parameter kinds", function()
		expect((Templates.normalize("bad key", { messageId = "1" }))).toBe(nil)
		expect((Templates.normalize(string.rep("a", 33), { messageId = "1" }))).toBe(nil)
		expect((Templates.normalize("k", {}))).toBe(nil)
		expect((Templates.normalize("k", { messageId = "1", params = { who = "number" } }))).toBe(nil)
		local ok, errors =
			Templates.all({ good = { messageId = "1" }, ["no way"] = { messageId = "1" }, bad = 5 })
		expect(ok.good).never.toBe(nil)
		expect(ok.bad).toBe(nil)
		expect(#errors).toBe(2)
	end)

	it("checks parameters: exactly the declared names, string length, userId numbers", function()
		local tpl =
			Templates.normalize("t", { messageId = "1", params = { pet = "string", friend = "userId" } })
		local clean = Templates.checkParams(tpl, { pet = "Rex", friend = 7 })
		expect(clean.pet).toBe("Rex")
		expect(select(2, Templates.checkParams(tpl, { pet = "Rex" }))).toBe("bad_params")
		expect(select(2, Templates.checkParams(tpl, { pet = "Rex", friend = 7, extra = "x" }))).toBe(
			"bad_params"
		)
		expect(select(2, Templates.checkParams(tpl, { pet = string.rep("a", 101), friend = 7 }))).toBe(
			"bad_params"
		)
		expect(select(2, Templates.checkParams(tpl, { pet = "Rex", friend = "7" }))).toBe("bad_params")
		expect(select(2, Templates.checkParams(tpl, { pet = "Rex", friend = 7.5 }))).toBe("bad_params")
		expect((Templates.checkParams(tpl, { pet = string.rep("a", 100), friend = 1 }))).never.toBe(nil)
		local none = Templates.normalize("n", { messageId = "1" })
		expect((Templates.checkParams(none, nil))).never.toBe(nil)
		expect(select(2, Templates.checkParams(none, { a = "b" }))).toBe("bad_params")
	end)

	it("builds the Open Cloud body from the template alone", function()
		local tpl = Templates.normalize(
			"eggReady",
			{ messageId = "42", category = "egg", params = { pet = "string", friend = "userId" } }
		)
		local body = Templates.body(tpl, { pet = "Rex", friend = 7 }, 99)
		expect(body.source.universe).toBe("universes/99")
		expect(body.payload.type).toBe("MOMENT")
		expect(body.payload.messageId).toBe("42")
		expect(body.payload.analyticsData.category).toBe("egg")
		expect(body.payload.joinExperience.launchData).toBe("sw1:eggReady")
		expect(body.payload.parameters.pet.stringValue).toBe("Rex")
		expect(body.payload.parameters.friend.int64Value).toBe("7")
		local quiet = Templates.normalize("q", { messageId = "1", launch = false })
		local plain = Templates.body(quiet, {}, 1)
		expect(plain.payload.joinExperience).toBe(nil)
		expect(plain.payload.parameters).toBe(nil)
	end)

	it("parses LaunchData strictly", function()
		local known = function(k)
			return k == "eggReady"
		end
		expect(Templates.parseLaunchData("sw1:eggReady", known)).toBe("eggReady")
		for _, bad in
			{
				"sw1:other",
				"sw2:eggReady",
				"sw1:",
				"sw1:egg Ready",
				"eggReady",
				"SW1:eggReady",
				"sw1:eggReady\n",
				5,
				true,
				string.rep("x", 201),
			}
		do
			expect(Templates.parseLaunchData(bad, known)).toBe(nil)
		end
	end)
end)

describe("Sender", function()
	it("classifies Open Cloud results", function()
		expect(Sender.classify(true, 200, nil)).toBe("sent")
		expect(Sender.classify(false, 429, nil)).toBe("retry")
		expect(Sender.classify(false, 500, nil)).toBe("retry")
		expect(Sender.classify(false, 503, nil)).toBe("retry")
		expect(Sender.classify(false, nil, "failed")).toBe("retry")
		expect(Sender.classify(false, 400, nil)).toBe("refused")
		expect(Sender.classify(false, 403, nil)).toBe("refused")
		expect(Sender.classify(false, 404, nil)).toBe("refused")
		expect(Sender.classify(false, nil, "budget")).toBe("budget")
		expect(Sender.classify(false, nil, "no_secret")).toBe("unavailable")
		expect(Sender.classify(false, nil, "not_allowed")).toBe("unavailable")
		expect(Sender.classify(false, nil, "forbidden")).toBe("unavailable")
	end)

	it("backs off exponentially up to the cap", function()
		local retry = { base = 30, factor = 2, max = 900, attempts = 4 }
		expect(Sender.backoff(retry, 1)).toBe(30)
		expect(Sender.backoff(retry, 2)).toBe(60)
		expect(Sender.backoff(retry, 3)).toBe(120)
		expect(Sender.backoff(retry, 9)).toBe(900)
	end)
end)

describe("OptInRules", function()
	local optIn =
		{ minSessionSeconds = 180, minSessions = 1, cooldownDays = 30, maxPrompts = 3, onSuggest = true }
	local function state(over)
		local s = {
			now = 1000,
			joinedAt = 0,
			sessions = 2,
			prompts = 0,
			lastPromptAt = 0,
			promptedThisSession = false,
		}
		for k, v in over or {} do
			s[k] = v
		end
		return s
	end

	it("allows a returning player after minSessionSeconds", function()
		expect((OptInRules.check(optIn, state(), true))).toBe(true)
	end)

	it("never on join: the session must be old enough", function()
		local ok, why = OptInRules.check(optIn, state({ now = 179 }), true)
		expect(ok).toBe(false)
		expect(why).toBe("too_early")
		expect((OptInRules.check(optIn, state({ now = 180 }), true))).toBe(true)
	end)

	it("counts finished sessions, prompts, cooldown, pending and one ask a session", function()
		expect(select(2, OptInRules.check(optIn, state({ sessions = 1 }), true))).toBe("sessions")
		expect(
			(
				OptInRules.check(
					{ minSessionSeconds = 0, minSessions = 0, cooldownDays = 30, maxPrompts = 3 },
					state({ sessions = 1 }),
					true
				)
			)
		).toBe(true)
		expect(select(2, OptInRules.check(optIn, state({ prompts = 3 }), true))).toBe("max_prompts")
		local late = 100 * DAY
		expect(
			select(
				2,
				OptInRules.check(
					optIn,
					state({ now = late, joinedAt = late - 500, lastPromptAt = late - 29 * DAY }),
					true
				)
			)
		).toBe("cooldown")
		expect(
			(
				OptInRules.check(
					optIn,
					state({ now = late, joinedAt = late - 500, lastPromptAt = late - 31 * DAY }),
					true
				)
			)
		).toBe(true)
		expect(select(2, OptInRules.check(optIn, state({ pendingAt = 900 }), true))).toBe("pending")
		expect((OptInRules.check(optIn, state({ pendingAt = 1000 - 301 }), true))).toBe(true)
		expect(select(2, OptInRules.check(optIn, state({ promptedThisSession = true }), true))).toBe("asked")
	end)

	it("onSuggest = false refuses suggestions but not a template's own prompt", function()
		local off =
			{ minSessionSeconds = 180, minSessions = 1, cooldownDays = 30, maxPrompts = 3, onSuggest = false }
		expect(select(2, OptInRules.check(off, state(), true))).toBe("not_suggested")
		expect((OptInRules.check(off, state(), false))).toBe(true)
	end)
end)

describe("client OptIn seam", function()
	local function fakeService(can, raises)
		local calls = {}
		return {
			calls = calls,
			CanPromptOptInAsync = function()
				table.insert(calls, "can")
				if raises then
					error("boom")
				end
				return can
			end,
			PromptOptIn = function()
				table.insert(calls, "prompt")
			end,
		}
	end

	it("prompts and reports shown when Roblox says it can", function()
		local svc, reports = fakeService(true), {}
		local optIn = OptIn.new(svc, function(id, shown)
			table.insert(reports, { id, shown })
		end)
		expect(optIn.canPrompt()).toBe(nil)
		optIn.prompt("r1")
		expect(svc.calls).toEqual({ "can", "prompt" })
		expect(reports[1]).toEqual({ "r1", true })
		expect(optIn.canPrompt()).toBe(true)
	end)

	it("doesn't prompt and reports not shown when it can't or the check errors", function()
		local svc, reports = fakeService(false), {}
		local optIn = OptIn.new(svc, function(id, shown)
			table.insert(reports, { id, shown })
		end)
		optIn.prompt("r2")
		expect(svc.calls).toEqual({ "can" })
		expect(reports[1]).toEqual({ "r2", false })
		expect(optIn.canPrompt()).toBe(false)
		local broken, more = fakeService(true, true), {}
		local o2 = OptIn.new(broken, function(id, shown)
			table.insert(more, { id, shown })
		end)
		o2.prompt("r3")
		expect(more[1]).toEqual({ "r3", false })
		expect(o2.canPrompt()).toBe(false)
	end)

	it("rounds the device offset to a quarter hour and clamps it", function()
		expect(OptIn.utcOffsetHours(10 * HOUR, 5 * HOUR)).toBe(5)
		expect(OptIn.utcOffsetHours(5 * HOUR + 1800 + 100, 0)).toBe(5.5)
		expect(OptIn.utcOffsetHours(0, 5 * HOUR)).toBe(-5)
		expect(OptIn.utcOffsetHours(20 * HOUR, 0)).toBe(14)
	end)
end)
