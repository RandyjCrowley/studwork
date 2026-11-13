--!nocheck
--[[
	The moderation kit end to end: Admin, Moderation and Reports enabled together with their REAL
	server parts (no injected fakes), TextFilter (fake TextService) and Economy. Every staff request
	goes through Admin's wire (Run / Fetch, the encodings Admin chose: "<tab>/<rowAction>" with the
	row id in `preset` and "<preset>|<note>" in `text`). Design §3-§5, Addenda B, D, E, F.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local I = require("packages/kits/moderation/tests/IntegrationHelpers.luau")

local OWNER, ADMIN, MOD, HELPER = 10, 11, 12, 13
local PLAYER, OTHER = 50, 51
local DAY = 86400

local USERS = { [OWNER] = "owner", [ADMIN] = "admin", [MOD] = "moderator", [HELPER] = "helper" }

local function boot(opts)
	opts = opts or {}
	opts.users = opts.users or USERS
	return I.boot(opts)
end

local function ids(list, field)
	local out = {}
	for _, e in list or {} do
		table.insert(out, if field then e[field] else e)
	end
	table.sort(out)
	return out
end

local function staffState(env, p)
	local st = env.h:state(p)
	local admin = st and st.modules and st.modules.Admin
	return admin and admin.extra and admin.extra.staff
end

local function entries(env, pred)
	return I.find(env.audit(), pred)
end

describe("registration across the three modules", function()
	it("Moderation's actions and Audit tab, Reports' tab, the audit sink: in Admin, per role", function()
		local env = boot()
		local owner = env.add(OWNER)
		local helper = env.add(HELPER)
		local o = staffState(env, owner)
		local actionIds = ids(o.actions, "id")
		for _, id in { "ban", "unban", "kick", "serverban", "mute", "unmute", "warn", "punish" } do
			expect(table.find(actionIds, id)).never.toBe(nil)
		end
		expect(ids(o.tabs, "id")).toEqual({ "audit", "reports" })
		-- a helper sees only what the role may use: no ban actions, no Audit tab
		local hs = staffState(env, helper)
		local helperActions = ids(hs.actions, "id")
		expect(table.find(helperActions, "ban")).toBe(nil)
		expect(table.find(helperActions, "unban")).toBe(nil)
		expect(table.find(helperActions, "kick")).never.toBe(nil)
		expect(ids(hs.tabs, "id")).toEqual({ "reports" })
		-- the Reports tab offers claim/resolve only to reports.resolve (helpers have reports.read)
		expect(#(hs.tabs[1].rowActions or {})).toBe(0)
		-- a non-staff player has no staff key at all
		local p = env.add(PLAYER)
		expect(staffState(env, p)).toBe(nil)
	end)
end)

describe("free text (Addendum F)", function()
	it("Admin filters announcements and freeText args with TextFilter when it is enabled", function()
		local env = boot()
		local owner = env.add(OWNER)
		local mod = env.add(MOD)
		local p = env.add(PLAYER)
		local r = env.run(owner, "announce", nil, nil, nil, "hello badword")
		expect(r.ok).toBe(true)
		local sent = env.h:sent("Admin", "Announce")
		expect(sent[#sent].args[1]).toBe("t|hello #######")
		-- a registered action with freeText (Moderation kick, allowFreeText on) gets the filtered text
		r = env.run(mod, "kick", PLAYER, "Moderation.kick.generic", nil, "stop the badword")
		expect(r).toEqual({ ok = true, key = "Moderation.result.done" })
		expect(p.kicked).toBe("stop the #######")
	end)

	it("without TextFilter free text is refused (no_filter); presets still work", function()
		local env = boot({ modules = { I.Economy, I.Admin, I.Moderation, I.Reports } })
		local owner = env.add(OWNER)
		expect(env.run(owner, "announce", nil, nil, nil, "hello")).toEqual({
			ok = false,
			key = "Admin.result.no_filter",
		})
		expect(env.run(owner, "announce", nil, "Admin.announce.event").ok).toBe(true)
	end)

	it("a registered text filter overrides TextFilter", function()
		local Probe = StudWork.defineModule({
			name = "FilterProbe",
			version = "1.0.0",
			framework = "^1.7.0",
			dependsOn = { I.Admin },
		})
		local env = I.boot({
			users = USERS,
			modules = { I.Economy, I.TextFilter, I.Admin, I.Moderation, I.Reports, Probe },
			servers = {
				FilterProbe = {
					init = function(ctx)
						ctx.depsExt[I.Admin].registerTextFilter(function(_author, text)
							return true, string.upper(text)
						end)
					end,
				},
			},
		})
		local owner = env.add(OWNER)
		expect(env.run(owner, "announce", nil, nil, nil, "hello badword").ok).toBe(true)
		local sent = env.h:sent("Admin", "Announce")
		expect(sent[#sent].args[1]).toBe("t|HELLO BADWORD")
	end)
end)

describe("Moderation through Admin's Run", function()
	it(
		"a panel ban of an absent player: BanAsync once, audited once, the staff member's index too",
		function()
			local env = boot()
			local mod = env.add(MOD)
			local r = env.run(mod, "ban", 555, "Moderation.ban.cheating", DAY)
			expect(r).toEqual({ ok = true, key = "Moderation.result.banned" })
			expect(env.players.count("BanAsync")).toBe(1)
			expect(env.players.bans[555].Duration).toBe(DAY)
			local bans = entries(env, function(e)
				return e.action == "ban" and e.target == 555
			end)
			expect(#bans).toBe(1)
			expect(bans[1].by).toBe(MOD)
			expect(bans[1].byKind).toBe("staff")
			expect(bans[1].status).toBe("ok")
			expect(bans[1].reasonKey).toBe("Moderation.ban.cheating")
			local ok, mine = env.mod.audit({ by = "server", target = MOD, limit = 10 })
			expect(ok).toBe(true)
			expect(#I.find(mine, function(e)
				return e.action == "ban"
			end)).toBe(1)
		end
	)

	it("each staff click counts once against Admin.limits (Addendum D)", function()
		local env = boot({ config = { Admin = { limits = { actionsPerMinute = 6, bansPerHour = 20 } } } })
		local owner = env.add(OWNER)
		local p = env.add(PLAYER)
		env.add(OTHER)
		-- registered actions (Admin: can only; Moderation's API: allow once)
		expect(env.run(owner, "ban", 601, "Moderation.ban.rules", 3600).ok).toBe(true)
		expect(env.run(owner, "warn", PLAYER, "Moderation.warn.rules").ok).toBe(true)
		-- a tab fetch (Admin: allow once; Moderation's audit read: permission only)
		expect(env.fetch(owner, "audit", 1)).never.toBe(nil)
		-- Reports' tab (Admin: allow once) and its row action (Admin: can; Reports.claim: allow once)
		local r = env.h:addPlayer({ userId = 70001 })
		expect(env.h:action(r, I.Reports, "submit", OTHER, "cheating", nil)).toBe(true)
		local rows = env.fetch(owner, "reports", 1)
		expect(#rows.rows).toBe(1)
		expect(env.run(owner, "reports/claim", nil, rows.rows[1].id).ok).toBe(true)
		-- a built-in (Admin: allow once)
		expect(env.run(owner, "announce", nil, "Admin.announce.event").ok).toBe(true)
		-- six counted: the seventh click is refused, whichever kind it is
		expect(env.run(owner, "mute", PLAYER, "Moderation.mute.spam", 600)).toEqual({
			ok = false,
			key = "Moderation.result.rate_limited",
		})
		expect(env.mod.isMuted(p)).toBe(false)
		expect(env.run(owner, "announce", nil, "Admin.announce.event")).toEqual({
			ok = false,
			key = "Admin.result.rate_limited",
		})
		-- a minute later the window is free again
		env.h:tick(61)
		expect(env.run(owner, "mute", PLAYER, "Moderation.mute.spam", 600).ok).toBe(true)
		expect(env.mod.isMuted(p)).toBe(true)
	end)

	it("role caps come from Admin.limitsOf: maxBanSeconds, maxMuteSeconds, ban.permanent", function()
		local env = boot({ config = { Admin = { roles = { moderator = { maxBanSeconds = DAY } } } } })
		local mod = env.add(MOD)
		local helper = env.add(HELPER)
		local p = env.add(PLAYER)
		expect(env.run(mod, "ban", 700, nil, 7 * DAY)).toEqual({
			ok = false,
			key = "Moderation.result.too_long_for_role",
		})
		expect(env.run(mod, "ban", 700, nil, -1)).toEqual({
			ok = false,
			key = "Moderation.result.no_permission",
		})
		expect(env.run(mod, "ban", 700, nil, DAY).ok).toBe(true)
		expect(env.run(helper, "mute", PLAYER, nil, DAY)).toEqual({
			ok = false,
			key = "Moderation.result.too_long_for_role",
		})
		expect(env.run(helper, "mute", PLAYER, nil, 3600).ok).toBe(true)
		expect(env.mod.isMuted(p)).toBe(true)
		-- the API checks the same caps for server code calling with by = staff
		expect(select(2, env.mod.mute(p, { by = helper, seconds = DAY }))).toBe("too_long_for_role")
	end)

	it("ranks: self, online and absent staff (users map, group rule), unknown rank", function()
		local env = boot({
			groups = { { groupId = 7, roles = { { minRank = 200, role = "admin" } } } },
		})
		env.groups.setRoles(7, 777, { { Id = 1, Name = "Lead", Rank = 250 } })
		env.groups.setRoles(7, 779, { { Id = 2, Name = "Member", Rank = 1 } })
		local owner = env.add(OWNER)
		local mod = env.add(MOD)
		-- self
		expect(env.run(mod, "kick", MOD, "Moderation.kick.generic")).toEqual({
			ok = false,
			key = "Admin.result.outranked",
		})
		-- online, higher
		expect(env.run(mod, "kick", OWNER, "Moderation.kick.generic")).toEqual({
			ok = false,
			key = "Admin.result.outranked",
		})
		expect(owner.kicked).toBe(nil)
		-- absent: users map, then a group rule (rankOfUserId)
		expect(env.run(mod, "ban", ADMIN, nil, 3600).key).toBe("Admin.result.outranked")
		expect(env.run(mod, "ban", 777, nil, 3600).key).toBe("Admin.result.outranked")
		-- Moderation's own check (server code acting for the staff member) agrees
		expect(select(2, env.mod.ban(777, { by = mod, seconds = 3600 }))).toBe("outranked")
		-- a group member below every rule is no staff: allowed
		expect(env.run(mod, "ban", 779, nil, 3600).key).toBe("Moderation.result.banned")
		-- the group lookup fails: unknown rank, refused (fails closed)
		env.groups.failNext(1)
		expect(env.run(mod, "ban", 778, nil, 3600).key).toBe("Admin.result.unknown_rank")
		expect(env.players.bans[777]).toBe(nil)
		expect(env.players.bans[778]).toBe(nil)
		-- the owner may act on lower staff
		expect(env.run(owner, "warn", MOD, "Moderation.warn.rules").ok).toBe(true)
	end)

	it("Admin's refused-audit throttle is config.Admin.refusedAuditSeconds", function()
		local env = boot({ config = { Admin = { refusedAuditSeconds = 60 } } })
		local helper = env.add(HELPER)
		local function count()
			return #entries(env, function(e)
				return e.status == "refused" and e.by == HELPER and e.action == "announce"
			end)
		end
		expect(env.run(helper, "announce", nil, "Admin.announce.event").key).toBe(
			"Admin.result.no_permission"
		)
		expect(env.run(helper, "announce", nil, "Admin.announce.event").key).toBe(
			"Admin.result.no_permission"
		)
		expect(count()).toBe(1)
		env.h:tick(61)
		expect(env.run(helper, "announce", nil, "Admin.announce.event").key).toBe(
			"Admin.result.no_permission"
		)
		expect(count()).toBe(2)
		expect(I.Admin.config.defaults.refusedAuditSeconds).toBe(3600)
	end)

	it("refused staff requests are audited, once per staff member and action", function()
		local env = boot()
		local helper = env.add(HELPER)
		local mod = env.add(MOD)
		env.add(PLAYER)
		-- refused by Admin's pre-check (the module never sees it)
		expect(env.run(helper, "ban", 555, nil, 3600).key).toBe("Admin.result.no_permission")
		expect(env.run(helper, "ban", 556, nil, 3600).key).toBe("Admin.result.no_permission")
		-- refused by Moderation (permanent needs ban.permanent)
		expect(env.run(mod, "ban", 557, nil, -1).key).toBe("Moderation.result.no_permission")
		expect(env.run(mod, "ban", 558, nil, -1).key).toBe("Moderation.result.no_permission")
		local refused = entries(env, function(e)
			return e.status == "refused"
		end)
		local byHelper = I.find(refused, function(e)
			return e.by == HELPER and e.action == "ban"
		end)
		local byMod = I.find(refused, function(e)
			return e.by == MOD and e.action == "ban"
		end)
		expect(#byHelper).toBe(1)
		expect(#byMod).toBe(1)
		expect(env.players.count("BanAsync")).toBe(0)
	end)

	it("a mute from the panel reaches text chat and the save; unmute restores it", function()
		local env = boot()
		local mod = env.add(MOD)
		local p = env.add(PLAYER)
		local source = env.tcs.addChannel("RBXGeneral"):AddUserAsync(PLAYER)
		expect(env.run(mod, "mute", PLAYER, "Moderation.mute.spam", 600).ok).toBe(true)
		expect(source.CanSend).toBe(false)
		local muted, untilTs = env.mod.isMuted(p)
		expect(muted).toBe(true)
		expect(untilTs > 0).toBe(true)
		expect(env.run(mod, "unmute", PLAYER).ok).toBe(true)
		expect(source.CanSend).toBe(true)
		expect(env.mod.isMuted(p)).toBe(false)
	end)

	it("Admin's own built-ins are audited through Moderation's sink (grant with Economy)", function()
		local env = boot()
		local owner = env.add(OWNER)
		local p = env.add(PLAYER)
		expect(env.run(owner, "grant", PLAYER, "Coins", 100).ok).toBe(true)
		expect(env.economy.balance(p, "Coins")).toBe(100)
		local grants = entries(env, function(e)
			return e.action == "grant"
		end)
		expect(#grants).toBe(1)
		expect(grants[1].by).toBe(OWNER)
		expect(grants[1].target).toBe(PLAYER)
		-- the sink keeps the amount and currency
		expect(grants[1].amount).toBe(100)
		expect(grants[1].currency).toBe("Coins")
	end)

	it("successful dataView and stopSpectate are audited too", function()
		local env = boot()
		local owner = env.add(OWNER)
		env.add(PLAYER)
		expect(env.run(owner, "dataView", PLAYER).ok).toBe(true)
		expect(env.run(owner, "spectate", PLAYER).ok).toBe(true)
		expect(env.run(owner, "stopSpectate").ok).toBe(true)
		local list = env.audit()
		local views = I.find(list, function(e)
			return e.note == "Admin.action.dataView"
		end)
		expect(#views).toBe(1)
		expect(views[1].status).toBe("ok")
		expect(views[1].target).toBe(PLAYER)
		expect(views[1].by).toBe(OWNER)
		local stops = I.find(list, function(e)
			return e.action == "spectate" and e.note == "Admin.action.stopSpectate"
		end)
		expect(#stops).toBe(1)
		expect(stops[1].by).toBe(OWNER)
	end)
end)

describe("Reports through Admin's tab", function()
	it("rows, claim, resolve with a preset and a note; audited by Moderation without reporter ids", function()
		local env = boot()
		local owner = env.add(OWNER)
		local helper = env.add(HELPER)
		env.add(90001)
		for i = 1, 3 do
			local r = env.h:addPlayer({ userId = 70000 + i })
			expect(env.h:action(r, I.Reports, "submit", 90001, "harassment", "stop badword")).toBe(true)
		end
		local rows = env.fetch(owner, "reports", 1)
		expect(#rows.rows).toBe(1)
		local row = rows.rows[1]
		expect(row.count).toBe(3)
		local id = row.id
		-- a helper reads the queue but may not claim
		expect(#env.fetch(helper, "reports", 1).rows).toBe(1)
		expect(env.run(helper, "reports/claim", nil, id).key).toBe("Admin.result.no_permission")
		-- a forged row id is refused
		expect(env.run(owner, "reports/claim", nil, "90001-1").key).toBe("Admin.result.invalid")
		expect(env.run(owner, "reports/claim", nil, id).ok).toBe(true)
		-- another staff member's claim of the same report: "claimed", with an English string
		local admin = env.add(ADMIN)
		expect(#env.fetch(admin, "reports", 1).rows).toBe(1)
		local claimed = env.run(admin, "reports/claim", nil, id)
		expect(claimed).toEqual({ ok = false, key = "Admin.result.claimed" })
		expect(I.Admin.strings({})[claimed.key]).toBe("Someone else already claimed that")
		-- resolve: the resolution and the note ride in text ("<preset>|<note>")
		expect(env.run(owner, "reports/resolve", nil, id, nil, "Reports.resolution.bogus").key).toBe(
			"Admin.result.invalid"
		)
		local r = env.run(
			owner,
			"reports/resolve",
			nil,
			id,
			nil,
			"Reports.resolution.actioned|Reports.resolveNote.duplicate"
		)
		expect(r.ok).toBe(true)
		local okQ, queue = env.reports.queue({ by = "server" })
		expect(okQ).toBe(true)
		expect(#queue).toBe(0)
		local audited = entries(env, function(e)
			return e.action == "report_claimed" or e.action == "report_resolved"
		end)
		expect(ids(audited, "action")).toEqual({ "report_claimed", "report_resolved" })
		local resolved = I.find(audited, function(e)
			return e.action == "report_resolved"
		end)[1]
		expect(resolved.by).toBe(OWNER)
		expect(resolved.target).toBe(90001)
		expect(resolved.reasonKey).toBe("Reports.resolution.actioned")
		expect(resolved.note).toBe("Reports.resolveNote.duplicate")
		for i = 1, 3 do
			expect(I.contains(env.audit(), 70000 + i)).toBe(false)
		end
	end)

	it(
		"the reported staff member never sees their own report; Reports' autoAction feeds Moderation",
		function()
			local env = boot({
				config = {
					Reports = { autoAction = { enabled = true, distinctReporters = 3 } },
					Moderation = {
						auto = {
							sources = { reports = { threshold = 1, windowSeconds = 3600, offense = "rules" } },
						},
					},
				},
			})
			local mod = env.add(MOD)
			local admin = env.add(ADMIN)
			local p = env.add(PLAYER)
			for i = 1, 3 do
				local r = env.h:addPlayer({ userId = 70000 + i })
				expect(env.h:action(r, I.Reports, "submit", MOD, "harassment", nil)).toBe(true)
				expect(env.h:action(r, I.Reports, "submit", PLAYER, "harassment", nil)).toBe(true)
			end
			-- the moderator can't see the report about themselves; the admin (higher) can
			local mine = env.fetch(mod, "reports", 1)
			for _, row in mine.rows do
				expect(string.find(row.target, tostring(MOD), 1, true)).toBe(nil)
			end
			expect(#env.fetch(admin, "reports", 1).rows).toBe(2)
			-- three distinct reporters: Reports -> Moderation.report -> the ladder's first step (warn),
			-- by "system"
			local warns = entries(env, function(e)
				return e.action == "warn" and e.target == PLAYER
			end)
			expect(#warns).toBe(1)
			expect(warns[1].byKind).toBe("system")
			local _ = p
		end
	)
end)

describe("Studio", function()
	it("everyone is staff (studioRole) and the rank rule is skipped; a users entry still wins", function()
		local env = I.boot({ isStudio = true, users = { [22] = "helper" } })
		local a = env.add(20)
		local b = env.add(21)
		local helper = env.add(22)
		expect(staffState(env, a).role).toBe("owner")
		expect(env.run(a, "ban", 21, nil, 3600).key).toBe("Moderation.result.banned")
		expect(b.kicked).never.toBe(nil)
		expect(env.run(helper, "ban", 20, nil, 3600).key).toBe("Admin.result.no_permission")
		expect(env.run(helper, "kick", 20, "Moderation.kick.generic").ok).toBe(true)
	end)

	it("a self-action is still refused; a target with a users entry keeps the rank rule", function()
		local env = I.boot({ isStudio = true, users = { [22] = "helper", [23] = "admin" } })
		local a = env.add(20)
		local helper = env.add(22)
		local admin = env.add(23)
		-- self: Admin's pre-check and Moderation's own check
		expect(env.run(a, "kick", 20, "Moderation.kick.generic").key).toBe("Admin.result.outranked")
		expect(select(2, env.mod.kick(a, { by = a }))).toBe("outranked")
		-- a listed admin (rank 300) outranks a listed helper (100), in Admin and in Moderation
		expect(env.run(helper, "kick", 23, "Moderation.kick.generic").key).toBe("Admin.result.outranked")
		expect(select(2, env.mod.kick(admin, { by = helper }))).toBe("outranked")
		expect(admin.kicked).toBe(nil)
		-- the Studio owner (studioRole, rank 400) may act on the listed admin
		expect(env.run(a, "warn", 23, "Moderation.warn.rules").ok).toBe(true)
		expect(env.admin.studioRoleOnly(20)).toBe(true)
		expect(env.admin.studioRoleOnly(23)).toBe(false)
	end)
end)

describe("a non-staff client", function()
	it("faking every request of all three modules gets no reply and changes nothing", function()
		local env = boot()
		local owner = env.add(OWNER)
		local p = env.add(PLAYER)
		env.add(OTHER)
		local r = env.h:addPlayer({ userId = 70001 })
		expect(env.h:action(r, I.Reports, "submit", OTHER, "cheating", nil)).toBe(true)
		local id = env.fetch(owner, "reports", 1).rows[1].id
		local before = #env.h:sent("Admin")
		local fakes = {
			{ "ban", OTHER, "Moderation.ban.rules", 3600 },
			{ "unban", OTHER },
			{ "kick", OTHER, "Moderation.kick.generic" },
			{ "serverban", OTHER, nil, 600 },
			{ "mute", OTHER, nil, 600 },
			{ "unmute", OTHER },
			{ "warn", OTHER, "Moderation.warn.rules" },
			{ "punish", OTHER, "Moderation.offense.rules" },
			{ "reports/claim", nil, id },
			{ "reports/resolve", nil, id, nil, "Reports.resolution.dismissed" },
			{ "announce", nil, "Admin.announce.event" },
			{ "grant", OTHER, "Coins", 10 },
		}
		for _, a in fakes do
			expect(env.run(p, a[1], a[2], a[3], a[4], a[5])).toBe(nil)
		end
		for _, tab in { "audit", "reports", "players" } do
			expect(env.fetch(p, tab, 1)).toBe(nil)
		end
		expect(env.h:action(p, I.Admin, "panelOpen", 0)).toBe(true)
		env.h:tick(6)
		expect(#env.h:sent("Admin")).toBe(before)
		expect(env.players.count("BanAsync")).toBe(0)
		expect(#entries(env, function(e)
			return e.by == PLAYER
		end)).toBe(0)
		local okQ, queue = env.reports.queue({ by = "server" })
		expect(okQ).toBe(true)
		expect(queue[1].status).toBe("open")
	end)
end)
