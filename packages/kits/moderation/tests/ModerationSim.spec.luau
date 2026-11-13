--!nocheck
--[[
	The moderation kit in the multi-server simulation (StudWork.test.sim): Admin, Moderation and
	Reports with their REAL server parts on several sim servers sharing one World (ProfileStore
	saves and messages, ctx.data.shared, sorted maps), plus TextFilter and Economy. Engine services
	are the kit's fakes (./Fakes.luau): one Players fake for the universe (bans), TextChatService per
	server. Design §7 "Sims".

	Delivery note: a ctx.data.messages message to a player online elsewhere lands on that server's
	next ProfileStore save. The vendored ProfileStore throttles its "save sooner" MessagingService
	ping with os.clock() (> 6 s since the last one), which the sim does not advance, so here the
	message arrives with the owner's autosave (<= 300 s). Waits below allow 400 s.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local S = require("packages/kits/moderation/tests/SimHelpers.luau")
local F = StudWork.test.sim

local OWNER, MOD = 10, 11
local DAY = 86400
local DELIVERY = 400

local function statuses(list, action, target)
	local out = {}
	for _, e in list do
		if e.action == action and (target == nil or e.target == target) then
			table.insert(out, e.status)
		end
	end
	table.sort(out)
	return out
end

local function gone(env, p, seconds)
	return env.w:advanceUntil(function()
		return p.Parent == nil
	end, seconds or 60, 0.25)
end

describe("a ban during a Roblox outage", function()
	it(
		"is pending, kicks at once, refuses a rejoin elsewhere, is retried and audited; play continues",
		function()
			local env = S.world({ users = { [OWNER] = "owner" } })
			local a, b = env.server(), env.server()
			local owner = env.join(a, OWNER)
			local bystander = env.join(a, 60)
			local target = env.join(a, 50)
			env.players.failNext(3)
			expect(env.run(a, owner, "ban", 50, "Moderation.ban.cheating", DAY)).toEqual({
				ok = true,
				key = "Moderation.result.pending",
			})
			expect(gone(env, target)).toBe(true)
			expect(env.players.bans[50]).toBe(nil)
			-- the pending ban is shared: another server refuses the player while Roblox is down
			local again = b:join(50)
			expect(gone(env, again, 60)).toBe(true)
			-- retried with backoff until Roblox answers
			expect(env.w:advanceUntil(function()
				return env.players.bans[50] ~= nil
			end, 300, 0.5)).toBe(true)
			expect(env.players.bans[50].Duration).toBe(DAY)
			expect(env.players.count("BanAsync")).toBe(4)
			local list = env.audit(a, { target = 50 })
			expect(statuses(list, "ban", 50)).toEqual({ "ok", "pending" })
			-- play continues: the bystander is still here and the staff member can still act
			expect(bystander.Parent ~= nil).toBe(true)
			expect(a:use("Economy").grant(bystander, 5, "test")).toBe(true)
			expect(env.run(a, owner, "warn", 60, "Moderation.warn.rules").ok).toBe(true)
			-- after the ban the pending entry is gone: the player is not held by the kit any more
			-- (Roblox itself refuses them now)
			expect(#env.w:errors()).toBe(0)
		end
	)

	it(
		"another server takes the pending ban over once the owner server stopped and its lease ran out",
		function()
			local env = S.world({ users = { [OWNER] = "owner" } })
			local a, b = env.server(), env.server()
			local owner = env.join(a, OWNER)
			env.join(a, 52)
			env.players.failNext(1000) -- a long outage
			expect(env.run(a, owner, "ban", 52, nil, DAY).key).toBe("Moderation.result.pending")
			env.w:advance(30, 0.5) -- a few retries on server a, all failing
			local attemptsOnA = env.players.count("BanAsync")
			expect(attemptsOnA >= 2).toBe(true)
			local stop = a:shutdown()
			expect(env.w:advanceUntil(function()
				return stop.done
			end, 40, 0.25)).toBe(true)
			env.players.recover() -- the outage ends after the owner stopped
			-- server b scans the pending index (pending.pollSeconds) and takes over after the lease
			-- (retry.max) expired
			expect(env.w:advanceUntil(function()
				return env.players.bans[52] ~= nil
			end, 900, 1)).toBe(true)
			local list = env.audit(b, { target = 52 })
			local ok = S.find(list, function(e)
				return e.action == "ban" and e.status == "ok"
			end)
			expect(#ok).toBe(1)
			expect(ok[1].server).toBe(b.jobId)
			expect(ok[1].by).toBe(OWNER)
			-- the player is refused on b (Roblox ban now)
			expect(env.players.bans[52].Duration).toBe(DAY)
			expect(#env.w:errors()).toBe(0)
		end
	)
end)

describe("cross-server delivery", function()
	it(
		"a mute and a kick reach a target on another server; a mute reaches an offline player on join",
		function()
			local env = S.world({ users = { [OWNER] = "owner" } })
			local a, b = env.server(), env.server()
			local owner = env.join(a, OWNER)
			local target = env.join(b, 51)
			local source = env.tcs(b).addChannel("RBXGeneral"):AddUserAsync(51)
			expect(env.run(a, owner, "mute", 51, "Moderation.mute.spam", 3600)).toEqual({
				ok = true,
				key = "Moderation.result.sent",
			})
			local bMod = b:use("Moderation")
			expect(env.w:advanceUntil(function()
				return bMod.isMuted(target) == true
			end, DELIVERY, 0.5)).toBe(true)
			expect(source.CanSend).toBe(false)
			local notices = env.sentTo(target, "Moderation", "Notice")
			expect(#notices >= 1).toBe(true)
			expect(notices[#notices].args[1]).toBe("Moderation.mute.spam")
			-- a kick
			expect(env.run(a, owner, "kick", 51, "Moderation.kick.rules")).toEqual({
				ok = true,
				key = "Moderation.result.sent",
			})
			expect(gone(env, target, DELIVERY)).toBe(true)
			local kicked = S.find(b.kicks, function(k)
				return k.userId == 51
			end)
			expect(#kicked).toBe(1)
			-- an offline player: the mute waits in the save and applies when they join anywhere
			local p = env.join(b, 53)
			b:leave(p)
			env.w:advance(10)
			expect(env.run(a, owner, "mute", 53, nil, 3600).key).toBe("Moderation.result.sent")
			env.w:advance(10)
			local c = env.server()
			local back = env.join(c, 53)
			local cMod = c:use("Moderation")
			expect(env.w:advanceUntil(function()
				return cMod.isMuted(back) == true
			end, 30, 0.25)).toBe(true)
			local audited = env.audit(a)
			expect(statuses(audited, "mute", 51)).toEqual({ "ok" })
			expect(statuses(audited, "kick", 51)).toEqual({ "ok" })
			expect(statuses(audited, "mute", 53)).toEqual({ "ok" })
			expect(#env.w:errors()).toBe(0)
		end
	)
end)

describe("the escalation ladder", function()
	it("warn -> mute -> kick here, then ban delivered to the server the player rejoined", function()
		local env = S.world({ users = { [OWNER] = "owner" } })
		local a, b = env.server(), env.server()
		local owner = env.join(a, OWNER)
		local target = env.join(a, 54)
		local aMod = a:use("Moderation")
		local function punish()
			return env.run(a, owner, "punish", 54, "Moderation.offense.rules")
		end
		-- step 1: warn (a Notice to the player)
		expect(punish()).toEqual({ ok = true, key = "Moderation.result.done" })
		expect(#env.sentTo(target, "Moderation", "Notice")).toBe(1)
		-- step 2: mute (ladder seconds)
		expect(punish().ok).toBe(true)
		expect(aMod.isMuted(target)).toBe(true)
		-- step 3: kick
		expect(punish().ok).toBe(true)
		expect(gone(env, target)).toBe(true)
		-- the player comes back on another server; step 4 (ban) goes through their save
		local back = env.join(b, 54)
		expect(punish()).toEqual({ ok = true, key = "Moderation.result.sent" })
		expect(env.w:advanceUntil(function()
			return env.players.bans[54] ~= nil
		end, DELIVERY, 0.5)).toBe(true)
		expect(env.players.bans[54].Duration).toBe(DAY)
		expect(gone(env, back, 30)).toBe(true)
		env.w:advance(30)
		local strikes = F.section(env.w, 54, "moderation").strikes
		local steps = {}
		for _, s in strikes do
			table.insert(steps, s.step)
		end
		expect(steps).toEqual({ "warn", "mute", "kick", "ban" })
		local list = env.audit(b, { target = 54 })
		for _, action in { "warn", "mute", "kick", "ban" } do
			expect(#statuses(list, action, 54) >= 1).toBe(true)
		end
		expect(#env.w:errors()).toBe(0)
	end)
end)

describe("report spam", function()
	it("reporter limits hold across servers (durable in the reporter's save)", function()
		local env = S.world({})
		local a, b = env.server(), env.server()
		for _, id in { 101, 102, 103 } do
			env.join(a, id)
		end
		for _, id in { 104, 105, 106 } do
			env.join(b, id)
		end
		local reporter = env.join(a, 70)
		local function submit(server, p, target)
			local ok = server:action(p, "Reports", "submit", target, "cheating", nil)
			expect(ok).toBe(true)
			env.w:advance(11) -- the framework's per-action rate limit (Reports.submit)
		end
		for _, t in { 101, 102, 103 } do
			submit(a, reporter, t)
		end
		submit(a, reporter, 101) -- perPairPerDay = 1
		a:leave(reporter)
		env.w:advance(10)
		reporter = env.join(b, 70)
		submit(b, reporter, 104)
		submit(b, reporter, 105)
		submit(b, reporter, 106) -- the 6th within the hour: perReporterPerHour = 5
		local ok, queue = env.call(b, b:use("Reports").queue, { by = "server", limit = 50 })
		expect(ok).toBe(true)
		local targets = {}
		for _, s in queue do
			table.insert(targets, s.target)
			expect(s.count).toBe(1)
		end
		table.sort(targets)
		expect(targets).toEqual({ 101, 102, 103, 104, 105 })
		expect(#b:section(reporter, "reports").sent).toBe(5)
		-- the reporter saw the same thanks every time (no signal of a limit)
		local thanks = 0
		for _, server in { a, b } do
			for _, fb in server.feedback do
				if fb.player.UserId == 70 then
					thanks += 1
				end
			end
		end
		expect(thanks).toBe(7)
		-- an hour later the hourly window is free again, on a third server
		b:leave(reporter)
		env.w:advance(3600, 5)
		local c = env.server()
		env.join(c, 107)
		reporter = env.join(c, 70)
		submit(c, reporter, 107)
		local ok2, queue2 = env.call(c, c:use("Reports").queue, { by = "server", limit = 50 })
		expect(ok2).toBe(true)
		expect(#queue2).toBe(6)
		expect(#env.w:errors()).toBe(0)
	end)
end)

describe("a client faking staff requests", function()
	it("gets no reply to any Admin action, tab, PanelOpen or Reports row action; nothing changes", function()
		local env = S.world({ users = { [OWNER] = "owner" } })
		local a, b = env.server(), env.server()
		local owner = env.join(a, OWNER)
		local victim = env.join(a, 62)
		local fakers = { { a, env.join(a, 60) }, { b, env.join(b, 61) } }
		local reporter = env.join(a, 70)
		expect(a:action(reporter, "Reports", "submit", 62, "cheating", nil)).toBe(true)
		env.w:advance(2)
		local rows = env.fetch(a, owner, "reports", 1)
		expect(#rows.rows).toBe(1)
		local rowId = rows.rows[1].id
		local staff = a.synced[owner].modules.Admin.extra.staff
		local actionIds, tabIds = {}, { "players", "data", "announce" }
		for _, def in staff.actions do
			table.insert(actionIds, def.id)
		end
		for _, tab in staff.tabs do
			table.insert(tabIds, tab.id)
		end
		expect(#actionIds >= 16).toBe(true)
		local banCalls = env.players.count("BanAsync")
		local auditBefore = #env.audit(a)
		for _, pair in fakers do
			local server, p = pair[1], pair[2]
			for _, id in actionIds do
				expect(env.run(server, p, id, 62, "Moderation.ban.rules", 3600, nil)).toBe(nil)
				expect(env.run(server, p, id, nil, nil, nil, nil)).toBe(nil)
			end
			expect(env.run(server, p, "announce", nil, nil, nil, "hello")).toBe(nil)
			expect(env.run(server, p, "grant", p.UserId, "Coins", 1000)).toBe(nil)
			expect(env.run(server, p, "reports/claim", nil, rowId)).toBe(nil)
			expect(env.run(server, p, "reports/resolve", nil, rowId, nil, "Reports.resolution.dismissed")).toBe(
				nil
			)
			for _, tab in tabIds do
				expect(env.fetch(server, p, tab, 1)).toBe(nil)
			end
			expect(server:action(p, "Admin", "panelOpen", 0)).toBe(true)
			env.w:advance(6)
			-- nothing at all from Admin reached that client (no reply, no announcement, no rows)
			expect(#env.sentTo(p, "Admin")).toBe(0)
		end
		expect(env.players.count("BanAsync")).toBe(banCalls)
		expect(victim.Parent ~= nil).toBe(true)
		expect(a:use("Moderation").isMuted(victim)).toBe(false)
		expect(a:use("Economy").balance(fakers[1][2], "Coins")).toBe(0)
		local after = env.audit(a)
		expect(#after).toBe(auditBefore)
		local okQ, queue = env.call(a, a:use("Reports").queue, { by = "server" })
		expect(okQ).toBe(true)
		expect(queue[1].status).toBe("open")
		expect(#env.w:errors()).toBe(0)
	end)
end)

describe("staff state", function()
	it("never appears in a non-staff client's replicated state, on any server", function()
		local env = S.world({ users = { [OWNER] = "owner", [MOD] = "moderator" } })
		local a, b = env.server(), env.server()
		local owner = env.join(a, OWNER)
		local mod = env.join(b, MOD)
		local players = { { a, env.join(a, 60) }, { b, env.join(b, 61) } }
		env.w:advance(5)
		-- staff themselves get their own state
		expect(a.synced[owner].modules.Admin.extra.staff.role).toBe("owner")
		expect(b.synced[mod].modules.Admin.extra.staff.role).toBe("moderator")
		local function clean()
			for _, pair in players do
				local server, p = pair[1], pair[2]
				local state = server.synced[p]
				expect(state).never.toBe(nil)
				for _, key in { "staff", "role", "permissions", "actions", "tabs" } do
					expect(S.hasKey(state, key)).toBe(false)
				end
				-- no staff id anywhere while they are online (nothing lists them)
				expect(S.contains(state, OWNER)).toBe(false)
				expect(S.contains(state, MOD)).toBe(false)
			end
		end
		clean()
		-- staff act (panel, audit, a report) and another staff member joins: still nothing
		expect(env.run(a, owner, "warn", 60, "Moderation.warn.rules").ok).toBe(true)
		expect(env.fetch(b, mod, "audit", 1)).never.toBe(nil)
		env.join(b, MOD + 1)
		env.w:advance(5)
		clean()
		expect(#env.w:errors()).toBe(0)
	end)
end)
