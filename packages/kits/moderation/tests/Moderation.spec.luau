--!nocheck
--[[
	Moderation behaviour (design §4 as amended by §8-§10; docs/framework/kits/moderation.md):
	actors, bans through outages (pending, leases, seq), unbans, history, kicks and mutes here and
	across servers, the ladder, the automatic report hook, the audit log, permissions with and
	without Admin, the flag, text chat mutes. Engine fakes: ./Fakes.luau; helpers: ./ModerationHelpers.luau.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local H = require("packages/kits/moderation/tests/ModerationHelpers.luau")

local DAY = 86400

local function sorted(env)
	return env.h:sortedMap("Moderation", "pending").entries()
end

local function pendingKeys(env)
	local out = {}
	for _, e in sorted(env) do
		if e.key ~= "sweep" then
			table.insert(out, e.key)
		end
	end
	return out
end

local function statuses(list, action, target)
	local out = {}
	for i = #list, 1, -1 do -- oldest first
		local e = list[i]
		if e.action == action and (target == nil or e.target == target) then
			table.insert(out, e.status)
		end
	end
	return out
end

describe("the actor (B5)", function()
	it("every mutating call without by (or with a bad by) raises an error naming the fix", function()
		local env = H.boot()
		local m = env.m
		local calls = {
			function()
				m.ban(2, {})
			end,
			function()
				m.unban(2, { by = nil })
			end,
			function()
				m.kick(2, { by = "admin" })
			end,
			function()
				m.serverBan(2, {})
			end,
			function()
				m.mute(2, {})
			end,
			function()
				m.unmute(2, {})
			end,
			function()
				m.warn(2, { key = "Moderation.warn.rules" })
			end,
			function()
				m.punish(2, "rules", {})
			end,
			function()
				m.history(2, {})
			end,
			function()
				m.audit({})
			end,
			function()
				m.record({ action = "custom" }, {})
			end,
		}
		for _, call in calls do
			expect(H.raises(call, 'opts.by is required: pass the acting staff Player, "server"')).toBe(true)
		end
		expect(#env.players.calls).toBe(0)
	end)
end)

describe("bans", function()
	it(
		"a ban during a BanAsync outage is pending, audited, retried with backoff, then ok; play continues",
		function()
			local env = H.boot()
			local h, m, players = env.h, env.m, env.players
			local target = env.add(2)
			local other = env.add(3)
			players.failNext(2) -- Roblox's transient form: "HTTP failure for UserId 2: Timedout"
			local ok, status =
				m.ban(target, { by = "server", seconds = 3600, displayKey = "Moderation.ban.cheating" })
			expect(ok).toBe(true)
			expect(status).toBe("pending")
			expect(target.kicked).toContain("Cheating or exploiting.")
			expect(players.count("BanAsync")).toBe(1)
			expect(pendingKeys(env)).toEqual({ "2" })
			expect(env.shared()["Moderation/bans/p/2"].kind).toBe("ban")
			expect(env.shared()["Moderation/bans/p/2"].owner).toBe("server-a")
			-- play continues for everyone else
			expect(other.kicked).toBe(nil)
			expect(m.warn(other, { by = "server", key = "Moderation.warn.rules" })).toBe(true)
			-- retry 1 after retry.base (5 s): fails again; retry 2 after 10 s more: succeeds
			h:tick(5)
			expect(players.count("BanAsync")).toBe(2)
			expect(players.bans[2]).toBe(nil)
			h:tick(10)
			expect(players.count("BanAsync")).toBe(3)
			expect(players.bans[2].Duration).toBe(3600)
			expect(players.bans[2].DisplayReason).toContain("Cheating or exploiting.")
			expect(pendingKeys(env)).toEqual({})
			expect(env.shared()["Moderation/bans/p/2"]).toBe(nil)
			h:tick(16)
			expect(statuses(env.audit(), "ban", 2)).toEqual({ "pending", "ok" })
		end
	)

	it("a joining player listed as pending is kicked; an unreadable index follows onUnknownStatus", function()
		local env = H.boot()
		env.players.failNext(1)
		expect(select(2, env.m.ban(7, { by = "server", seconds = 60 }))).toBe("pending")
		local p = env.add(7)
		expect(p.kicked).toContain("You broke the game rules.")
		-- admit (default): a failed index read lets the player in and re-reads after unknownRecheckSeconds
		local map = env.h:sortedMap("Moderation", "pending")
		map.failNext(3)
		local q = env.add(8)
		expect(q.kicked).toBe(nil)
		env.h:tick(30)
		expect(q.kicked).toBe(nil)
		-- hold: kicked with the "try again" key
		local held = H.boot({ config = { onUnknownStatus = "hold" } })
		held.h:sortedMap("Moderation", "pending").failNext(3)
		local r = held.add(9)
		expect(r.kicked).toContain("try again")
	end)

	it("a permanent error is failed, audited, never pending", function()
		local env = H.boot()
		env.players.failNext(1, "Players:BanAsync: banning is not enabled for this experience")
		local ok, status = env.m.ban(2, { by = "server", seconds = 60 })
		expect(ok).toBe(false)
		expect(status).toBe("failed")
		expect(pendingKeys(env)).toEqual({})
		expect(env.shared()["Moderation/bans/p/2"]).toBe(nil)
		env.h:tick(60)
		expect(env.players.count("BanAsync")).toBe(1)
		expect(statuses(env.audit(), "ban", 2)).toEqual({ "failed" })
	end)

	it("validates before calling Roblox: duration, keys, free text", function()
		local env = H.boot()
		local m = env.m
		expect(select(2, m.ban(2, { by = "server", seconds = 1.5 }))).toBe("invalid")
		expect(select(2, m.ban(2, { by = "server", seconds = 0 }))).toBe("invalid")
		expect(select(2, m.ban(2, { by = "server", displayKey = "game.unknown" }))).toBe("invalid")
		expect(select(2, m.ban(2, { by = "server", displayText = "free" }))).toBe("invalid") -- allowFreeDisplay off
		expect(select(2, m.ban(0, { by = "server" }))).toBe("invalid")
		expect(env.players.count("BanAsync")).toBe(0)
		-- permanent (nil seconds) = Duration -1, universe-wide, the appeal line appended
		expect(select(2, m.ban(2, { by = "server", privateReason = "aimbot logs #42" }))).toBe("banned")
		local call = env.players.calls[1].args
		expect(call.Duration).toBe(-1)
		expect(call.ApplyToUniverse).toBe(true)
		expect(call.PrivateReason).toBe("aimbot logs #42")
		expect(call.DisplayReason).toBe("You broke the game rules. To appeal, contact the game's support.")
		expect(call.ExcludeAltAccounts).toBe(false)
	end)

	it("the display reason is cut to 400 characters on a UTF-8 boundary", function()
		local Util = H.Server.Util
		local s = string.rep("é", 450)
		expect(utf8.len(Util.cutChars(s, 400))).toBe(400)
		expect(#Util.cutBytes("aé", 2)).toBe(1)
		expect(Util.cutBytes("aé", 3)).toBe("aé")
		expect(Util.isTransient("HTTP failure for UserId 5: Timedout")).toBe(true)
		expect(Util.isTransient("Request timed out")).toBe(true)
		expect(Util.isTransient("Players:BanAsync: Duration must be an integer > 0 or -1")).toBe(false)
	end)

	it("unban: UnbanAsync universe-wide, audited", function()
		local env = H.boot({
			players = require("packages/kits/moderation/tests/Fakes.luau").players({
				bans = { [5] = { Duration = -1, DisplayReason = "x", PrivateReason = "", StartTime = "t" } },
			}),
		})
		local ok, status = env.m.unban(5, { by = "server" })
		expect(ok).toBe(true)
		expect(status).toBe("unbanned")
		expect(env.players.bans[5]).toBe(nil)
		expect(env.players.calls[1].args.ApplyToUniverse).toBe(true)
		env.h:tick(16)
		expect(statuses(env.audit(), "unban", 5)).toEqual({ "ok" })
	end)

	it("ban fails -> unban (fails too) -> outage ends: the player stays unbanned (B3)", function()
		local env = H.boot()
		local players = env.players
		players.failNext(2)
		expect(select(2, env.m.ban(4, { by = "server", seconds = 600 }))).toBe("pending")
		expect(select(2, env.m.unban(4, { by = "server" }))).toBe("pending")
		local stored = env.shared()["Moderation/bans/p/4"]
		expect(stored.kind).toBe("unban")
		expect(stored.seq).toBe(2)
		env.h:tick(60)
		expect(players.count("BanAsync")).toBe(1) -- never retried
		expect(players.count("UnbanAsync")).toBe(2)
		expect(players.bans[4]).toBe(nil)
		expect(pendingKeys(env)).toEqual({})
	end)

	it("a direct unban drops a pending ban (and its retries)", function()
		local env = H.boot()
		env.players.failNext(1)
		expect(select(2, env.m.ban(4, { by = "server", seconds = 600 }))).toBe("pending")
		expect(select(2, env.m.unban(4, { by = "server" }))).toBe("unbanned")
		env.h:tick(60)
		expect(env.players.count("BanAsync")).toBe(1)
		expect(env.players.bans[4]).toBe(nil)
		expect(pendingKeys(env)).toEqual({})
	end)

	it("retry.maxAttempts: a ban that keeps failing becomes failed", function()
		local env = H.boot({ config = { retry = { base = 1, factor = 1, max = 5, maxAttempts = 3 } } })
		env.players.failNext(10)
		expect(select(2, env.m.ban(6, { by = "server", seconds = 60 }))).toBe("pending")
		env.h:tick(10)
		expect(env.players.count("BanAsync")).toBe(3)
		expect(pendingKeys(env)).toEqual({})
		env.h:tick(16)
		local list = H.find(env.audit(), function(e)
			return e.action == "ban" and e.status == "failed"
		end)
		expect(#list).toBe(1)
		expect(list[1].note).toBe("Moderation.note.retriesExhausted")
	end)

	it(
		"BanAsync and the store both down: still pending (memory only), noted, saved and retried later",
		function()
			local env = H.boot()
			env.players.failNext(1)
			env.breakShared(true)
			env.h:sortedMap("Moderation", "pending").failNext(3)
			expect(select(2, env.m.ban(8, { by = "server", seconds = 60 }))).toBe("pending")
			-- this server still refuses the player
			local p = env.add(8)
			expect(p.kicked).never.toBe(nil)
			env.breakShared(false)
			env.h:tick(6)
			expect(env.players.bans[8]).never.toBe(nil)
			env.h:tick(16)
			local pend = H.find(env.audit(), function(e)
				return e.action == "ban" and e.status == "pending"
			end)
			expect(pend[1].note).toBe("Moderation.note.pendingUnsaved")
		end
	)

	it("history: preset reasons only, custom text hidden; Studio is unavailable", function()
		local Fakes = require("packages/kits/moderation/tests/Fakes.luau")
		local players = Fakes.players({
			history = {
				[3] = {
					{
						Ban = true,
						Duration = 60,
						DisplayReason = "Harassing other players. To appeal, contact the game's support.",
						StartTime = "a",
						PlaceId = -1,
					},
					{
						Ban = true,
						Duration = 60,
						DisplayReason = "you are a cheater lol",
						StartTime = "b",
						PlaceId = -1,
					},
				},
			},
		})
		local env = H.boot({ players = players })
		local ok, entries = env.m.history(3, { by = "server" })
		expect(ok).toBe(true)
		expect(entries[1].reasonKey).toBe("Moderation.ban.harassment")
		expect(entries[2].reasonKey).toBe("Moderation.history.custom")
		-- cached for history.cacheSeconds
		env.m.history(3, { by = "server" })
		expect(players.count("GetBanHistoryAsync")).toBe(1)
		local studio = H.boot({ isStudio = true })
		expect(select(2, studio.m.history(3, { by = "server" }))).toBe("unavailable")
		expect(select(2, env.m.history(3, { by = "system" }))).toBe("no_permission")
	end)
end)

describe("kick, server ban, warn", function()
	it("kick here: the preset localized for the target; free text needs allowFreeText", function()
		local env = H.boot()
		local p = env.add(2)
		expect(select(2, env.m.kick(p, { by = "server", text = "bye" }))).toBe("invalid")
		expect(select(2, env.m.kick(p, { by = "server", key = "game.nope" }))).toBe("invalid")
		local ok, status = env.m.kick(p, { by = "server", key = "Moderation.kick.rules" })
		expect(ok).toBe(true)
		expect(status).toBe("done")
		expect(p.kicked).toBe("You were removed for breaking the game rules.")
	end)

	it("a kick message is cut to 500 bytes on a UTF-8 boundary", function()
		local env = H.boot({ config = { kick = { allowFreeText = true } } })
		local p = env.add(2)
		expect(select(2, env.m.kick(p, { by = "console", text = string.rep("ü", 400) }))).toBe("done")
		expect(#p.kicked <= 500).toBe(true)
		expect(utf8.len(p.kicked)).toBe(250)
	end)

	it(
		"kick across servers (ctx.data.messages): sent at once, applied on the target's server; stale kicks dropped",
		function()
			local store = StudWork.test.memoryStore()
			local a = H.boot({ store = store, jobId = "server-a" })
			local b = H.boot({ store = store, jobId = "server-b" })
			local target = b.add(2)
			local ok, status = a.m.kick(2, { by = "server", key = "Moderation.kick.generic" })
			expect(ok).toBe(true)
			expect(status).toBe("sent")
			expect(target.kicked).toBe("You were removed from this server.")
			-- a kick that arrives older than crossServer.kickMaxAgeSeconds is dropped and audited failed
			local late = H.boot({ store = store, jobId = "server-c", startTime = 1_700_000_000 - 700 })
			local t2 = b.add(3)
			expect(select(2, late.m.kick(3, { by = "server" }))).toBe("sent")
			expect(t2.kicked).toBe(nil)
			b.h:tick(16)
			local failed = H.find(b.audit(), function(e)
				return e.action == "kick" and e.status == "failed"
			end)
			expect(failed[1].note).toBe("Moderation.note.staleKick")
		end
	)

	it("at most crossServer.perTargetPerHour messages to one target from one server", function()
		local env = H.boot()
		for _ = 1, 5 do
			expect(select(2, env.m.warn(99, { by = "server", key = "Moderation.warn.rules" }))).toBe("sent")
		end
		expect(select(2, env.m.warn(99, { by = "server", key = "Moderation.warn.rules" }))).toBe(
			"rate_limited"
		)
		env.h:tick(3601)
		expect(select(2, env.m.warn(99, { by = "server", key = "Moderation.warn.rules" }))).toBe("sent")
	end)

	it("server ban: kicks, refuses a rejoin to this server until it expires", function()
		local env = H.boot()
		local p = env.add(2)
		expect(select(2, env.m.serverBan(p, { by = "server", seconds = 100000 }))).toBe("invalid")
		expect(select(2, env.m.serverBan(p, { by = "server", seconds = 60 }))).toBe("done")
		expect(p.kicked).toContain("can't join this server")
		env.h:removePlayer(p)
		p.kicked = nil
		env.add(2)
		expect(p.kicked).toContain("can't join this server")
		env.h:removePlayer(p)
		p.kicked = nil
		env.h:tick(61)
		env.add(2)
		expect(p.kicked).toBe(nil)
	end)

	it("warn: a Notice to that player only, counted in the save", function()
		local env = H.boot()
		local p = env.add(2)
		env.add(3)
		expect(select(2, env.m.warn(p, { by = "server", key = "Moderation.warn.language" }))).toBe("done")
		expect(#env.notices).toBe(1)
		expect(env.notices[1].player).toBe(p)
		expect(env.notices[1].key).toBe("Moderation.warn.language")
		env.h:removePlayer(p)
		expect(env.h:saved(p).moderation.warnings).toBe(1)
	end)
end)

describe("mutes", function()
	it(
		"text chat: CanSend false on every TextSource (also new ones), restored on expiry; extra.muted; Muted signal",
		function()
			local env = H.boot()
			local general = env.tcs.addChannel("RBXGeneral")
			local p = env.add(2)
			general:AddUserAsync(2)
			local team = env.tcs.addChannel("Team")
			local kept = team:AddUserAsync(2)
			kept.CanSend = false -- the game's own rule: not ours to restore
			local heard = {}
			env.m.signals.Muted:Connect(function(player, untilTs)
				table.insert(heard, { player, untilTs })
			end)
			local ok, status = env.m.mute(p, { by = "server", seconds = 60, key = "Moderation.mute.spam" })
			expect(ok).toBe(true)
			expect(status).toBe("done")
			expect(env.tcs.source(2, "RBXGeneral").CanSend).toBe(false)
			local later = env.tcs.addChannel("Trade")
			later:AddUserAsync(2)
			expect(env.tcs.source(2, "Trade").CanSend).toBe(false) -- DescendantAdded
			expect(env.m.isMuted(p)).toBe(true)
			expect(env.notices[1].key).toBe("Moderation.mute.spam")
			expect(env.notices[1].args).toBe('{"minutes":1}')
			env.h:fire(p, "StateInit")
			expect(env.h:state(p).modules.Moderation.extra.muted).toBe(env.h.clock + 60)
			expect(heard[1][2]).toBe(env.h.clock + 60)
			env.h:tick(61)
			expect(env.m.isMuted(p)).toBe(false)
			expect(env.tcs.source(2, "RBXGeneral").CanSend).toBe(true)
			expect(env.tcs.source(2, "Trade").CanSend).toBe(true)
			expect(env.tcs.source(2, "Team").CanSend).toBe(false)
			expect(heard[2][2]).toBe(nil)
			expect(env.notices[2].key).toBe("Moderation.mute.ended")
		end
	)

	it("unmute restores at once; mute.textChat = false leaves chat alone", function()
		local env = H.boot()
		local ch = env.tcs.addChannel("RBXGeneral")
		local p = env.add(2)
		ch:AddUserAsync(2)
		env.m.mute(p, { by = "server" })
		expect(select(2, env.m.unmute(p, { by = "server" }))).toBe("done")
		expect(env.tcs.source(2).CanSend).toBe(true)
		expect(env.m.isMuted(p)).toBe(false)
		local off = H.boot({ config = { mute = { textChat = false } } })
		local ch2 = off.tcs.addChannel("RBXGeneral")
		local q = off.add(2)
		ch2:AddUserAsync(2)
		off.m.mute(q, { by = "server" })
		expect(off.tcs.source(2).CanSend).toBe(true)
		expect(off.m.isMuted(q)).toBe(true)
	end)

	it("a mute crosses servers (two harnesses, one store) and survives a rejoin elsewhere", function()
		local store = StudWork.test.memoryStore()
		local a = H.boot({ store = store, jobId = "server-a" })
		local b = H.boot({ store = store, jobId = "server-b" })
		local ch = b.tcs.addChannel("RBXGeneral")
		local p = b.add(2)
		ch:AddUserAsync(2)
		local ok, status = a.m.mute(2, { by = "server", seconds = 600 })
		expect(ok).toBe(true)
		expect(status).toBe("sent")
		expect(b.m.isMuted(p)).toBe(true)
		expect(b.tcs.source(2).CanSend).toBe(false)
		expect(b.notices[1].key).toBe("Moderation.mute.generic")
		-- the same message delivered twice is applied once (seen)
		b.h:removePlayer(p)
		local q = a.add(2)
		expect(a.m.isMuted(q)).toBe(true)
		expect(#a.h:saved(q).moderation.seen).toBe(1)
		-- unmute from the other server
		a.h:removePlayer(q)
		local r = b.add(2)
		expect(select(2, a.m.unmute(2, { by = "server" }))).toBe("sent")
		expect(b.m.isMuted(r)).toBe(false)
	end)
end)

describe("the ladder", function()
	it("punish climbs warn -> mute -> kick -> ban and stays on the last step; strikes decay", function()
		local env = H.boot()
		local p = env.add(2)
		local seen = {}
		for _ = 1, 5 do
			local ok, step, status = env.m.punish(p, "rules", { by = "server" })
			expect(ok).toBe(true)
			table.insert(seen, step .. ":" .. status)
		end
		expect(seen).toEqual({ "warn:done", "mute:done", "kick:done", "ban:banned", "ban:banned" })
		expect(env.players.bans[2].Duration).toBe(DAY)
		expect(env.players.bans[2].DisplayReason).toContain("You broke the game rules.")
		local strikes = env.h:use(H.Moderation) and nil
		env.h:removePlayer(p)
		strikes = env.h:saved(p).moderation.strikes
		expect(#strikes).toBe(5)
		expect(strikes[1].offense).toBe("rules")
		expect(strikes[3].step).toBe("kick")
		-- 31 days later every strike has decayed: back to the first step
		env.h.clock += 31 * DAY
		local q = env.add(2)
		expect(select(2, env.m.punish(q, "rules", { by = "server" }))).toBe("warn")
	end)

	it("a refused step records no strike; offences climb separately", function()
		local env = H.boot({
			config = {
				ladders = { strict = { { action = "ban", seconds = 3600 } } },
				offenses = { cheating = { ladder = "strict", displayKey = "Moderation.ban.cheating" } },
			},
		})
		local p = env.add(2)
		local ok, reason = env.m.punish(p, "cheating", { by = "system" })
		expect(ok).toBe(false)
		expect(reason).toBe("no_permission")
		expect(select(2, env.m.punish(p, "rules", { by = "server" }))).toBe("warn")
		env.h:removePlayer(p)
		local strikes = env.h:saved(p).moderation.strikes
		expect(#strikes).toBe(1)
		expect(strikes[1].offense).toBe("rules")
	end)

	it("punish an absent target: sent, the step chosen and the strike recorded where the save is", function()
		local store = StudWork.test.memoryStore()
		local a = H.boot({ store = store, jobId = "server-a" })
		local b = H.boot({ store = store, jobId = "server-b" })
		local p = b.add(2)
		expect(select(2, a.m.punish(2, "rules", { by = "server" }))).toBe("sent")
		expect(select(2, a.m.punish(2, "rules", { by = "server" }))).toBe("sent")
		expect(b.notices[1].key).toBe("Moderation.warn.rules")
		expect(b.m.isMuted(p)).toBe(true)
		b.h:removePlayer(p)
		expect(#b.h:saved(p).moderation.strikes).toBe(2)
	end)
end)

describe("the automatic report hook", function()
	local function autoEnv(where)
		local source = { threshold = 3, windowSeconds = 60, offense = "cheating" }
		local config = {
			ladders = { strict = { { action = "ban", seconds = 3600 } } },
			offenses = { cheating = { ladder = "strict", displayKey = "Moderation.ban.cheating" } },
		}
		if where == "server" then
			return H.boot({ config = config, serverConfig = { autoSources = { speed = source } } })
		end
		config.auto = { sources = { speed = source } }
		return H.boot({ config = config })
	end

	it(
		"a crossing that needs a ban (not in auto.permissions) is refused and audited once per hour",
		function()
			local env = autoEnv("config")
			local p = env.add(2)
			expect(env.m.report(p, "speed", 1, { speed = 120 })).toBe(true)
			expect(env.m.report(p, "nope", 5)).toBe(false)
			expect(env.m.report(p, "speed", 2, { speed = 140, note = "x" })).toBe(true) -- crosses 3
			expect(env.players.count("BanAsync")).toBe(0)
			expect(p.kicked).toBe(nil)
			for _ = 1, 6 do
				env.m.report(p, "speed", 3)
			end
			env.h:tick(16)
			local refused = H.find(env.audit(), function(e)
				return e.status == "refused"
			end)
			expect(#refused).toBe(1)
			expect(refused[1].action).toBe("ban")
			expect(refused[1].byKind).toBe("system")
			expect(refused[1].source).toBe("speed")
			expect(refused[1].details).toBe('{"note":"x","speed":140}')
			env.h:removePlayer(p)
			expect(#env.h:saved(p).moderation.strikes).toBe(0)
			-- after audit.refusedEverySeconds the next refusal is audited again
			env.h.clock += 3600
			local q = env.add(2)
			env.m.report(q, "speed", 3)
			env.h:tick(16)
			expect(#H.find(env.audit(), function(e)
				return e.status == "refused"
			end)).toBe(2)
		end
	)

	it("sources from ServerConfig.Moderation.autoSources work; allowed steps run as system", function()
		local env = H.boot({
			serverConfig = {
				autoSources = { chat = { threshold = 2, windowSeconds = 30, offense = "rules" } },
			},
		})
		local p = env.add(2)
		env.m.report(p, "chat", 1)
		env.h:tick(31) -- the window passed: the first report no longer counts
		env.m.report(p, "chat", 1)
		expect(#env.notices).toBe(0)
		env.m.report(p, "chat", 1)
		expect(env.notices[1].key).toBe("Moderation.warn.rules")
		env.h:tick(16)
		local warns = H.find(env.audit(), function(e)
			return e.action == "warn"
		end)
		expect(warns[1].byKind).toBe("system")
		expect(warns[1].source).toBe("chat")
		local off = H.boot({
			config = { auto = { enabled = false } },
			serverConfig = {
				autoSources = { chat = { threshold = 1, windowSeconds = 30, offense = "rules" } },
			},
		})
		expect(off.m.report(off.add(2), "chat", 5)).toBe(false)
	end)
end)

describe("the audit log", function()
	it("chunks per server, a day directory, a per-target index; the buffer cap", function()
		local env = H.boot({ config = { audit = { chunkSize = 2, perTargetMax = 3 } } })
		for i = 1, 5 do
			expect(
				env.m.record({ action = "custom", target = 9, note = "game.note" .. i }, { by = "server" })
			).toBe(true)
		end
		expect(env.m.record({ action = "explode" }, { by = "server" })).toBe(false)
		env.h:tick(16)
		local day = env.h.clock // DAY
		local s = env.shared()
		expect(#s[`Moderation/a/{day}/server-a/1`]).toBe(2)
		expect(#s[`Moderation/a/{day}/server-a/2`]).toBe(2)
		expect(#s[`Moderation/a/{day}/server-a/3`]).toBe(1)
		expect(s[`Moderation/a/{day}/d`]).toEqual({ "server-a/1", "server-a/2", "server-a/3" })
		expect(#s["Moderation/a/u/9"]).toBe(3)
		expect(#env.audit()).toBe(5)
		expect(#env.audit({ target = 9 })).toBe(3)
		expect(env.audit({ target = 9 })[1].note).toBe("game.note5")
		-- the in-memory buffer keeps at most bufferMax (oldest dropped and counted)
		local capped = H.boot({ config = { audit = { bufferMax = 3 } } })
		for _ = 1, 5 do
			capped.m.record({ action = "custom" }, { by = "server" })
		end
		expect(capped.part.debug().audit.buffered()).toBe(3)
		expect(capped.part.debug().audit.dropped()).toBe(2)
	end)

	it("a failed flush keeps the buffer and retries with backoff", function()
		local env = H.boot()
		env.m.record({ action = "custom", target = 4 }, { by = "server" })
		env.breakShared(true)
		env.h:tick(16)
		expect(env.part.debug().audit.buffered()).toBe(1)
		env.breakShared(false)
		env.h:tick(40) -- failures at 1, 6, 16 s: the next try waits retry.base * factor^2
		expect(env.part.debug().audit.buffered()).toBe(0)
		expect(#env.shared()["Moderation/a/u/4"]).toBe(1)
	end)

	it("shutdown flushes the buffer once (bounded by audit.shutdownSeconds)", function()
		local env = H.boot()
		env.m.record({ action = "shutdown", target = 4 }, { by = "server" })
		env.h:tick(1) -- the first flush
		env.m.record({ action = "custom", target = 4 }, { by = "server" })
		expect(env.part.debug().audit.buffered()).toBe(1)
		env.h:shutdown()
		expect(env.part.debug().audit.buffered()).toBe(0)
		expect(#env.shared()["Moderation/a/u/4"]).toBe(2)
	end)

	it("retention: expired days' chunks and directory are deleted; old index entries dropped", function()
		local env = H.boot({ config = { audit = { retentionDays = 2 } } })
		local day = env.h.clock // DAY
		env.m.record({ action = "custom", target = 4 }, { by = "server" })
		env.h:tick(16)
		expect(env.shared()[`Moderation/a/{day}/d`]).never.toBe(nil)
		env.h.clock += 3 * DAY
		env.m.record({ action = "custom", target = 4 }, { by = "server" })
		env.h:tick(16)
		local s = env.shared()
		expect(s[`Moderation/a/{day}/d`]).toBe(nil)
		expect(s[`Moderation/a/{day}/server-a/1`]).toBe(nil)
		expect(#s["Moderation/a/u/4"]).toBe(1)
	end)

	it("reads need audit.read, one per readSecondsPerStaff per staff member, cached", function()
		local admin = H.fakeAdmin({ ranks = { [10] = 200 }, perms = { [10] = { ["audit.read"] = true } } })
		local env = H.boot({ admin = admin })
		local staff = env.add(10)
		local other = env.add(11)
		expect(select(2, env.m.audit({ by = other }))).toBe("no_permission")
		expect(env.m.audit({ by = staff, limit = 10 })).toBe(true)
		expect(env.m.audit({ by = staff, limit = 10 })).toBe(true) -- cached: no store read
		expect(select(2, env.m.audit({ by = staff, limit = 11 }))).toBe("rate_limited")
		env.h:tick(5)
		expect(env.m.audit({ by = staff, limit = 11 })).toBe(true)
		expect(select(2, env.m.audit({ by = "system" }))).toBe("no_permission")
	end)

	it("console commands act as console and are audited as such", function()
		local env = H.boot()
		expect(env.h:console("moderation", "ban", "5", "60")).toBe("ok: banned")
		expect(env.h:console("moderation", "warn", "6", "Moderation.warn.rules")).toBe("ok: sent")
		expect(env.h:console("moderation", "ban")).toContain("usage")
		env.h:tick(16)
		local bans = H.find(env.audit(), function(e)
			return e.action == "ban"
		end)
		expect(bans[1].byKind).toBe("console")
		expect(bans[1].by).toBe(0)
		expect(env.h:console("moderation", "audit", "5")).toContain("ban")
	end)
end)

describe("permissions", function()
	it(
		"Admin off, live: only ServerConfig.Moderation.admins; their peers are outranked; no self-action",
		function()
			local env = H.boot()
			local staff = env.add(10)
			local target = env.add(2)
			expect(select(2, env.m.kick(target, { by = staff }))).toBe("no_permission")
			expect(target.kicked).toBe(nil)
			local listed = H.boot({ serverConfig = { admins = { 10, 11 } } })
			local s2 = listed.add(10)
			local t2 = listed.add(2)
			local peer = listed.add(11)
			expect(select(2, listed.m.kick(t2, { by = s2 }))).toBe("done")
			expect(select(2, listed.m.kick(peer, { by = s2 }))).toBe("outranked")
			expect(select(2, listed.m.mute(s2, { by = s2 }))).toBe("outranked")
			expect(select(2, listed.m.ban(11, { by = s2, seconds = 60 }))).toBe("outranked")
		end
	)

	it(
		"refused staff requests are audited, at most once per (staff, action) per refusedEverySeconds",
		function()
			local env = H.boot()
			local staff = env.add(10)
			local p = env.add(2)
			for _ = 1, 3 do
				expect(select(2, env.m.kick(p, { by = staff }))).toBe("no_permission")
			end
			expect(select(2, env.m.warn(p, { by = staff, key = "Moderation.warn.rules" }))).toBe(
				"no_permission"
			)
			env.h:tick(16)
			local refused = H.find(env.audit(), function(e)
				return e.status == "refused"
			end)
			expect(#refused).toBe(2)
			expect(refused[1].byKind).toBe("staff")
			expect(refused[1].by).toBe(10)
			env.h.clock += 3600
			env.m.kick(p, { by = staff })
			env.h:tick(16)
			expect(#H.find(env.audit(), function(e)
				return e.status == "refused"
			end)).toBe(3)
		end
	)

	it("Studio: the rank rule is skipped (everyone is staff there)", function()
		local admin = H.fakeAdmin({ ranks = { [10] = 400, [11] = 400 }, perms = { [10] = { ["*"] = true } } })
		local env = H.boot({ admin = admin, isStudio = true })
		local staff = env.add(10)
		local peer = env.add(11)
		expect(select(2, env.m.kick(peer, { by = staff }))).toBe("done")
	end)

	it("Admin off, Studio: every player may act", function()
		local env = H.boot({ isStudio = true })
		local staff = env.add(10)
		local target = env.add(2)
		expect(select(2, env.m.kick(target, { by = staff }))).toBe("done")
	end)

	it("system may take only auto.permissions actions", function()
		local env = H.boot()
		local p = env.add(2)
		expect(select(2, env.m.ban(p, { by = "system", seconds = 60 }))).toBe("no_permission")
		expect(select(2, env.m.warn(p, { by = "system", key = "Moderation.warn.rules" }))).toBe("done")
		expect(select(2, env.m.serverBan(p, { by = "system" }))).toBe("no_permission")
	end)

	it("with Admin (injected fake): allow, outranked, unknown_rank, role limits, staff free text", function()
		local admin = H.fakeAdmin({
			ranks = { [10] = 200, [11] = 300, [12] = 0, [20] = 200 },
			perms = { [10] = { ["*"] = true } },
			failRank = { [13] = true },
			limits = { [10] = { maxBanSeconds = 3600, maxMuteSeconds = 600 } },
		})
		local env = H.boot({ admin = admin, extraConfig = { Moderation = nil } })
		local staff = env.add(10)
		local higher = env.add(11)
		local player = env.add(12)
		local nobody = env.add(30)
		expect(select(2, env.m.kick(higher, { by = staff }))).toBe("outranked")
		expect(select(2, env.m.kick(player, { by = nobody }))).toBe("no_permission")
		expect(select(2, env.m.ban(13, { by = staff, seconds = 60 }))).toBe("unknown_rank")
		expect(select(2, env.m.ban(20, { by = staff, seconds = 60 }))).toBe("outranked") -- equal rank, elsewhere
		expect(select(2, env.m.ban(player, { by = staff, seconds = 7200 }))).toBe("too_long_for_role")
		expect(select(2, env.m.mute(player, { by = staff, seconds = 3600 }))).toBe("too_long_for_role")
		expect(select(2, env.m.mute(player, { by = staff, seconds = 600 }))).toBe("done")
		-- staff private reasons need TextFilter (not enabled here)
		expect(select(2, env.m.ban(player, { by = staff, seconds = 60, privateReason = "x" }))).toBe(
			"no_filter"
		)
		expect(select(2, env.m.ban(player, { by = staff, seconds = 60 }))).toBe("banned")
		expect(admin.registered.allowCalls > 0).toBe(true)
	end)

	it(
		"with TextFilter: a staff private reason is filtered for the audit; the raw one goes only to BanAsync",
		function()
			local admin = H.fakeAdmin({ ranks = { [10] = 200 }, perms = { [10] = { ["*"] = true } } })
			local env = H.boot({
				admin = admin,
				modules = { H.TextFilter, H.Moderation },
				textService = { replace = { secret = true } },
				policy = { [10] = { IsContentSharingAllowed = true } },
			})
			local staff = env.add(10)
			local p = env.add(12)
			expect(select(2, env.m.ban(p, { by = staff, seconds = 60, privateReason = "secret evidence" }))).toBe(
				"banned"
			)
			expect(env.players.bans[12].PrivateReason).toBe("secret evidence")
			env.h:tick(16)
			local entry = H.find(env.audit(), function(e)
				return e.action == "ban"
			end)[1]
			expect(entry.privateReason).toBe("###### evidence")
			expect(entry.by).toBe(10)
		end
	)

	it("registers its panel actions, the Audit tab and the audit sink into Admin", function()
		local admin = H.fakeAdmin({ ranks = { [10] = 200 }, perms = { [10] = { ["*"] = true } } })
		local env = H.boot({ admin = admin })
		local reg = admin.registered
		local ids = {}
		for id in reg.actions do
			table.insert(ids, id)
		end
		table.sort(ids)
		expect(ids).toEqual({ "ban", "kick", "mute", "punish", "serverban", "unban", "unmute", "warn" })
		expect(reg.tabs.audit.permission).toBe("audit.read")
		expect(reg.actions.ban.durations).toEqual({ 3600, DAY, 7 * DAY, -1 })
		local staff = env.add(10)
		local p = env.add(12)
		expect(select(2, reg.actions.ban.run(staff, 12, { duration = 999 }))).toBe(
			"Moderation.result.invalid"
		)
		expect(select(2, reg.actions.warn.run(staff, 12, { preset = "Moderation.warn.rules" }))).toBe(
			"Moderation.result.done"
		)
		expect(select(2, reg.actions.punish.run(staff, 12, { preset = "Moderation.offense.rules" }))).toBe(
			"Moderation.result.done"
		)
		expect(select(2, reg.actions.ban.run(staff, 12, { duration = 3600 }))).toBe(
			"Moderation.result.banned"
		)
		expect(p.kicked).never.toBe(nil)
		reg.sink({
			action = "announce",
			by = 10,
			byKind = "staff",
			status = "ok",
			reasonKey = "Admin.announce.event",
		})
		env.h:tick(16)
		local page = reg.tabs.audit.fetch(staff, 1)
		expect(page.columns[1]).toBe("Moderation.column.at")
		local actions = {}
		for _, row in page.rows do
			table.insert(actions, row["Moderation.column.action"])
		end
		expect(table.find(actions, "announce")).never.toBe(nil)
		expect(table.find(actions, "ban")).never.toBe(nil)
	end)
end)

describe("the flag", function()
	it("off: every action is disabled, the report hook does nothing, joins are unaffected", function()
		local env = H.boot({
			config = {
				flag = "moderationOn",
				auto = { sources = { s = { threshold = 1, windowSeconds = 10, offense = "rules" } } },
			},
			flags = { moderationOn = { default = false } },
		})
		local p = env.add(2)
		expect(p.kicked).toBe(nil)
		expect(select(2, env.m.ban(p, { by = "server" }))).toBe("disabled")
		expect(select(2, env.m.kick(p, { by = "console" }))).toBe("disabled")
		expect(select(2, env.m.mute(p, { by = "server" }))).toBe("disabled")
		expect(select(2, env.m.punish(p, "rules", { by = "server" }))).toBe("disabled")
		expect(env.m.report(p, "s", 5)).toBe(false)
		expect(env.players.count("BanAsync")).toBe(0)
		expect(#env.notices).toBe(0)
	end)
end)

describe("start-up", function()
	it("warns once when Players.BanningEnabled is off", function()
		local Fakes = require("packages/kits/moderation/tests/Fakes.luau")
		local env = H.boot({ players = Fakes.players({ banningEnabled = false }) })
		local found = 0
		for _, w in env.h:warnings() do
			if string.find(w, "BanningEnabled", 1, true) then
				found += 1
			end
		end
		expect(found).toBe(1)
	end)
end)

describe("the client part", function()
	it("decodes the notice arguments and builds localized lines", function()
		local Client = require("packages/kits/moderation/Moderation/client/init.luau")
		expect(Client.decodeArgs('{"minutes":3}')).toEqual({ minutes = 3 })
		expect(Client.decodeArgs("not json")).toEqual({})
		expect(Client.decodeArgs('{"x":{"y":1}}')).toEqual({})
		local function text(key, args)
			return if args then key .. ":" .. tostring(args.minutes) else key
		end
		local warn = Client.lines(text, "Moderation.warn.rules", {})
		expect(warn.title).toBe("Moderation.warn.title")
		expect(warn.body).toBe("Moderation.warn.rules:nil")
		expect(warn.extra).toBe(nil)
		local mute = Client.lines(text, "Moderation.mute.spam", { minutes = 3 })
		expect(mute.title).toBe("Moderation.notice.title")
		expect(mute.extra).toBe("Moderation.mute.until:3")
	end)
end)
