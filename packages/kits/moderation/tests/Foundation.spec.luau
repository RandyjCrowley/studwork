--!nocheck
--!nolint DeprecatedApi
--[[
	Moderation kit foundation (design §0-§10): the three definitions (Admin, Moderation, Reports)
	boot alone, together, with and without TextFilter / Economy; their config defaults match the
	design; config the schema can't express fails boot; `opts.by` is required (B5); the engine
	fakes in ./Fakes.luau behave like the Roblox APIs they stand in for. Behaviour specs belong to
	each module's builder.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Fakes = require("packages/kits/moderation/tests/Fakes.luau")
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local function kit(name)
	return require(Modules:WaitForChild(name):WaitForChild("module"))
end
local Admin = kit("Admin")
local Moderation = kit("Moderation")
local Reports = kit("Reports")
local TextFilter = kit("TextFilter")
local Economy = kit("Economy")

local ServerModules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local AdminServer = require(ServerModules:WaitForChild("Admin"))
local ModerationServer = require(ServerModules:WaitForChild("Moderation"))
local ReportsServer = require(ServerModules:WaitForChild("Reports"))

local function services()
	return {
		Players = Fakes.players(),
		GroupService = Fakes.groupService(),
		TextChatService = Fakes.textChatService(),
		TextService = StudWork.test.fakes.textService({}),
	}
end

local function boot(modules, opts)
	opts = opts or {}
	return StudWork.test.boot({
		modules = modules,
		config = opts.config,
		serverConfig = opts.serverConfig,
		services = services(),
		servers = opts.servers,
	})
end

local function bootOk(modules, opts)
	local h, err = boot(modules, opts)
	assert(h, err)
	return h
end

describe("moderation kit definitions", function()
	it("are normal modules on framework ^1.7.0", function()
		for _, ref in { Admin, Moderation, Reports } do
			expect(StudWork.isModuleRef(ref)).toBe(true)
			expect(ref.version).toBe("1.0.0")
			expect(ref.framework).toBe("^1.7.0")
		end
		expect(Admin.name).toBe("Admin")
		expect(Moderation.name).toBe("Moderation")
		expect(Reports.name).toBe("Reports")
		expect(Admin.client).toBe("Admin")
		expect(Moderation.client).toBe("Moderation")
		expect(Reports.client).toBe("Reports")
	end)

	it("depend on nothing hard; optional deps exactly as the design (§0)", function()
		local function names(list)
			local out = {}
			for _, ref in list or {} do
				table.insert(out, ref.name)
			end
			table.sort(out)
			return out
		end
		for _, ref in { Admin, Moderation, Reports } do
			expect(#(ref.dependsOn or {})).toBe(0)
		end
		expect(names(Admin.optional)).toEqual({ "Economy", "TextFilter" })
		expect(names(Moderation.optional)).toEqual({ "Admin", "TextFilter" })
		expect(names(Reports.optional)).toEqual({ "Admin", "Moderation", "TextFilter" })
	end)

	it("own their save sections (v1, never replicated); Admin has none", function()
		expect(Admin.data).toBe(nil)
		expect(Moderation.data.key).toBe("moderation")
		expect(Moderation.data.version).toBe(1)
		expect(Moderation.data.replicate).toBe(false)
		expect(Moderation.data.default).toEqual({
			mute = { untilTs = 0, reasonKey = "" },
			strikes = {},
			warnings = 0,
			seen = {},
		})
		expect(Reports.data.key).toBe("reports")
		expect(Reports.data.version).toBe(1)
		expect(Reports.data.replicate).toBe(false)
		expect(Reports.data.default).toEqual({ sent = {} })
	end)

	it("carry the design's config defaults (§3-§5, Addenda A-C)", function()
		local a = Admin.config.defaults
		expect(a.studioRole).toBe("owner")
		expect(a.groupCacheSeconds).toBe(600)
		expect(a.groupLookupsPerMinute).toBe(60)
		expect(a.limits).toEqual({ actionsPerMinute = 30, bansPerHour = 20 })
		expect(a.panel.playerListMax).toBe(50)
		expect(a.grant).toEqual({ max = 10000, currencies = {} })
		expect(a.roles.owner.rank).toBe(400)
		expect(a.roles.owner.permissions).toEqual({ "*" })
		expect(a.roles.admin.rank).toBe(300)
		expect(table.find(a.roles.admin.permissions, "data.grant")).toBe(nil)
		expect(table.find(a.roles.admin.permissions, "shutdown")).toBe(nil)
		expect(table.find(a.roles.admin.permissions, "reports.reporters")).never.toBe(nil)
		expect(a.roles.admin.maxMuteSeconds).toBe(nil)
		expect(a.roles.moderator.rank).toBe(200)
		expect(a.roles.moderator.maxBanSeconds).toBe(7 * 86400)
		expect(a.roles.moderator.maxMuteSeconds).toBe(86400)
		expect(table.find(a.roles.moderator.permissions, "ban.permanent")).toBe(nil)
		expect(table.find(a.roles.moderator.permissions, "reports.reporters")).toBe(nil)
		expect(a.roles.helper.rank).toBe(100)
		expect(a.roles.helper.permissions).toEqual({ "kick", "mute", "warn", "reports.read" })
		expect(a.roles.helper.maxMuteSeconds).toBe(3600)

		local m = Moderation.config.defaults
		expect(m.ban.excludeAltAccounts).toBe(false)
		expect(m.ban.applyDeviceBlock).toBe(false)
		expect(m.ban.defaultDisplayKey).toBe("Moderation.ban.rules")
		expect(m.ban.maxDisplayLength).toBe(200)
		expect(m.serverBan).toEqual({ defaultSeconds = 3600, maxSeconds = 86400 })
		expect(m.mute.defaultSeconds).toBe(600)
		expect(m.mute.maxSeconds).toBe(604800)
		expect(m.mute.textChat).toBe(true)
		expect(m.mute.voice).toBe(false)
		expect(#m.ladders.default).toBe(4)
		expect(m.ladders.default[4]).toEqual({ action = "ban", seconds = 86400 })
		expect(m.strikes).toEqual({ decayDays = 30, max = 20 })
		expect(m.auto.enabled).toBe(true)
		expect(m.auto.permissions).toEqual({ "warn", "mute", "kick" })
		expect(m.audit.retentionDays).toBe(30)
		expect(m.audit.maxPerDay).toBe(nil) -- dropped (Addendum C)
		expect(m.audit.perTargetMax).toBe(30)
		expect(m.audit.flushSeconds).toBe(15)
		expect(m.audit.chunkSize).toBe(100)
		expect(m.audit.bufferMax).toBe(500)
		expect(m.audit.readSecondsPerStaff).toBe(5)
		expect(m.audit.readCacheSeconds).toBe(30)
		expect(m.audit.privateReasonMax).toBe(300)
		expect(m.audit.detailsMaxBytes).toBe(200)
		expect(m.audit.refusedEverySeconds).toBe(3600)
		expect(m.audit.shutdownSeconds).toBe(5)
		expect(m.retry).toEqual({ base = 5, factor = 2, max = 300, maxAttempts = 20 })
		expect(m.crossServer).toEqual({ kickMaxAgeSeconds = 600, perTargetPerHour = 5 })
		expect(m.pending).toEqual({ indexExpiryDays = 7, pollSeconds = 60 })
		expect(m.onUnknownStatus).toBe("admit")

		local r = Reports.config.defaults
		expect(r.categories).toEqual({ "cheating", "harassment", "inappropriate", "scam", "other" })
		expect(r.note).toEqual({ enabled = true, maxLength = 120 })
		expect(r.limits.perReporterPerHour).toBe(5)
		expect(r.limits.perReporterPerDay).toBe(15)
		expect(r.limits.perPairPerDay).toBe(1)
		expect(r.limits.perTargetPerDay).toBe(30)
		expect(r.limits.maxOpen).toBe(nil) -- moved to queue (Addendum C)
		expect(r.queue).toEqual({ maxOpen = 300, indexExpiryDays = 7 })
		expect(r.retentionDays).toBe(nil) -- dropped (Addendum C)
		expect(r.recentSeconds).toBe(600)
		expect(r.contextMaxBytes).toBe(600)
		expect(r.autoAction.enabled).toBe(false)
		expect(r.autoAction.distinctReporters).toBe(5)
		expect(r.autoAction.windowSeconds).toBe(1800)
		expect(r.blockPrompt).toBe(true)
	end)
end)

describe("moderation kit boot", function()
	it("each module boots alone with no warnings", function()
		for _, ref in { Admin, Moderation, Reports } do
			local h = bootOk({ ref })
			h:addPlayer({ userId = 1 })
			expect(h:warnings()).toEqual({})
			expect(h:use(ref)).never.toBe(nil)
		end
	end)

	it("all three boot together, with TextFilter and Economy, and save their sections", function()
		local h = bootOk({ Economy, TextFilter, Admin, Moderation, Reports })
		local p = h:addPlayer({ userId = 1 })
		expect(h:warnings()).toEqual({})
		h:removePlayer(p)
		local saved = h:saved(p)
		expect(saved.moderation.warnings).toBe(0)
		expect(saved.reports.sent).toEqual({})
		expect(saved.admin).toBe(nil)
	end)

	it("all three boot together without TextFilter or Economy", function()
		local h = bootOk({ Admin, Moderation, Reports })
		h:addPlayer({ userId = 1 })
		expect(h:warnings()).toEqual({})
	end)

	it("Moderation + Reports boot without Admin; Reports alone with TextFilter", function()
		bootOk({ Moderation, Reports, TextFilter })
		bootOk({ Reports, TextFilter })
	end)

	it("register their strings, including keys built from config", function()
		local captured
		local probe = StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" })
		bootOk({ Admin, Moderation, Reports, probe }, {
			config = {
				Admin = { roles = { trial = { rank = 50, permissions = { "warn" } } } },
				Moderation = { offenses = { spam = { ladder = "default" } } },
				Reports = { categories = { "cheating", "griefing" } },
			},
			servers = {
				Probe = {
					init = function(ctx)
						captured = ctx
					end,
				},
			},
		})
		local t = captured.text
		expect(t.english("Admin.title")).toBe("Staff panel")
		expect(t.english("Admin.role.trial")).toBe("trial")
		expect(t.english("Admin.role.owner")).toBe("Owner")
		expect(t.english("Moderation.ban.appeal")).never.toBe("Moderation.ban.appeal")
		expect(t.english("Moderation.history.custom")).toBe("Custom reason")
		expect(t.english("Moderation.offense.spam")).toBe("spam")
		expect(t.english("Reports.category.griefing")).toBe("griefing")
		expect(t.english("Reports.category.cheating")).toBe("Cheating or exploiting")
		-- every preset key the config defaults name has an English default
		for _, ref in { Admin, Moderation } do
			local d = ref.config.defaults
			local lists = if ref == Admin
				then { d.announce.presetKeys, d.shutdown.presetKeys }
				else { d.ban.displayKeys, d.kick.presetKeys, d.mute.presetKeys, d.warn.presetKeys }
			for _, list in lists do
				for _, key in list do
					expect(t.english(key)).never.toBe(key)
				end
			end
		end
		for _, offense in Moderation.config.defaults.offenses do
			expect(t.english(offense.displayKey)).never.toBe(offense.displayKey)
		end
		for _, role in Admin.config.defaults.roles do
			expect(t.english(role.label)).never.toBe(role.label)
		end
	end)

	it("signals exist after init (the api.signals proxy)", function()
		local h = bootOk({ Admin, Moderation, Reports })
		expect(h:use(Admin).signals.StaffJoined).never.toBe(nil)
		local m = h:use(Moderation).signals
		expect(m.Actioned).never.toBe(nil)
		expect(m.Muted).never.toBe(nil)
		expect(m.Banned).never.toBe(nil)
		local r = h:use(Reports).signals
		expect(r.Submitted).never.toBe(nil)
		expect(r.Resolved).never.toBe(nil)
	end)

	it("declare the client actions their net.blink backs", function()
		local h = bootOk({ Admin, Reports })
		local p = h:addPlayer({ userId = 1 })
		-- skeleton handlers: a non-staff request is dropped with no reply
		expect(h:action(p, Admin, "run", "announce", nil, "Admin.announce.event", nil, nil)).toBe(true)
		expect(h:action(p, Admin, "fetch", "players", 1)).toBe(true)
		expect(h:action(p, Admin, "panelOpen", 0)).toBe(true)
		expect(h:action(p, Reports, "submit", 2, "cheating", nil)).toBe(true)
		expect(h:sent("Admin")).toEqual({})
	end)

	it("the skeleton APIs answer with safe defaults", function()
		local h = bootOk({ Admin, Moderation, Reports })
		local p = h:addPlayer({ userId = 1 })
		local a = h:use(Admin)
		expect(a.can(p, "ban")).toBe(false)
		expect(a.isStaff(p)).toBe(false)
		expect(a.roleOf(p)).toBe(nil)
		expect(a.permissions(p)).toEqual({})
		expect(a.onlineStaff()).toEqual({})
		local m = h:use(Moderation)
		expect(m.isMuted(p)).toBe(false)
		expect(m.report(p, "speed", 1)).toBe(false)
	end)
end)

describe("config the schema can't express fails boot", function()
	local function bootErr(modules, config, serverConfig)
		local h, err = boot(modules, { config = config, serverConfig = serverConfig })
		expect(h).toBe(nil)
		return tostring(err)
	end

	it("schema errors (wrong types, ranges, enums)", function()
		expect(bootErr({ Admin }, { Admin = { groupLookupsPerMinute = 0 } })).toContain(
			"groupLookupsPerMinute"
		)
		expect(bootErr({ Moderation }, { Moderation = { onUnknownStatus = "maybe" } })).toContain(
			"onUnknownStatus"
		)
		expect(bootErr({ Moderation }, { Moderation = { audit = { retentionDays = 400 } } })).toContain(
			"retentionDays"
		)
		expect(bootErr({ Reports }, { Reports = { note = { maxLength = 500 } } })).toContain("maxLength")
	end)

	it("Admin: roles, studioRole and ServerConfig.Admin", function()
		expect(bootErr({ Admin }, { Admin = { roles = { bad = { rank = 5000, permissions = {} } } } })).toContain(
			"config.Admin.roles.bad.rank"
		)
		expect(bootErr({ Admin }, { Admin = { studioRole = "nobody" } })).toContain("config.Admin.studioRole")
		expect(bootErr({ Admin }, nil, { Admin = { users = { [5] = "ghost" } } })).toContain(
			"ServerConfig.Admin.users"
		)
		expect(
			bootErr(
				{ Admin },
				nil,
				{ Admin = { groups = { { groupId = 1, roles = { { role = "admin" } } } } } }
			)
		).toContain("needs roleId or minRank")
	end)

	it("Moderation: ladders, offences, auto permissions and sources", function()
		expect(bootErr({ Moderation }, { Moderation = { ladders = { x = { { action = "explode" } } } } })).toContain(
			"config.Moderation.ladders.x[1].action"
		)
		expect(bootErr({ Moderation }, { Moderation = { offenses = { spam = { ladder = "nope" } } } })).toContain(
			"config.Moderation.offenses.spam.ladder"
		)
		expect(bootErr({ Moderation }, { Moderation = { auto = { permissions = { "nuke" } } } })).toContain(
			"auto.permissions"
		)
		expect(bootErr({ Moderation }, nil, {
			Moderation = {
				autoSources = { speed = { threshold = 0, windowSeconds = 1, offense = "cheating" } },
			},
		})).toContain("ServerConfig.Moderation.autoSources.speed.threshold")
	end)

	it("Reports: categories", function()
		expect(bootErr({ Reports }, { Reports = { categories = { "bad id" } } })).toContain(
			"config.Reports.categories"
		)
		expect(bootErr({ Reports }, { Reports = { categories = { "a", "a" } } })).toContain("listed twice")
	end)

	it("a valid custom config boots", function()
		bootOk({ Admin, Moderation }, {
			config = {
				Admin = { roles = { trial = { rank = 50, permissions = { "warn" }, maxMuteSeconds = 60 } } },
				Moderation = {
					ladders = { strict = { { action = "kick" }, { action = "ban", seconds = -1 } } },
					offenses = { spam = { ladder = "strict" } },
					auto = {
						sources = { speed = { threshold = 3, windowSeconds = 60, offense = "cheating" } },
					},
				},
			},
			serverConfig = {
				Admin = {
					users = { [10] = "admin" },
					groups = { { groupId = 7, roles = { { roleId = 1, role = "moderator" } } } },
				},
				Moderation = { admins = { 10 } },
			},
		})
	end)
end)

describe("the actor (opts.by, design B5)", function()
	local function mustRaise(fn, where)
		local ok, err = pcall(fn)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain(where .. ": opts.by is required")
		expect(tostring(err)).toContain('"server"')
	end

	it("nil or any other value raises an error naming the fix, on every mutating call", function()
		local h = bootOk({ Admin, Moderation, Reports })
		local p = h:addPlayer({ userId = 1 })
		local m = h:use(Moderation)
		mustRaise(function()
			m.ban(2, {})
		end, "Moderation.ban")
		mustRaise(function()
			m.ban(2, { by = "admin" })
		end, "Moderation.ban")
		mustRaise(function()
			m.ban(2, { by = { UserId = 1 } }) -- a table is not a Player
		end, "Moderation.ban")
		mustRaise(function()
			m.unban(2, nil)
		end, "Moderation.unban")
		for _, name in { "kick", "serverBan", "mute", "unmute", "warn" } do
			mustRaise(function()
				m[name](2, { key = "x" })
			end, "Moderation." .. name)
		end
		mustRaise(function()
			m.punish(2, "cheating", {})
		end, "Moderation.punish")
		mustRaise(function()
			m.history(2, {})
		end, "Moderation.history")
		mustRaise(function()
			m.audit({})
		end, "Moderation.audit")
		mustRaise(function()
			m.record({ action = "custom" }, {})
		end, "Moderation.record")
		local r = h:use(Reports)
		mustRaise(function()
			r.queue({})
		end, "Reports.queue")
		mustRaise(function()
			r.claim("x", {})
		end, "Reports.claim")
		mustRaise(function()
			r.resolve("x", "dismissed", {})
		end, "Reports.resolve")
		-- the four valid actors pass the check
		for _, by in { p, "server", "console", "system" } do
			local ok = pcall(m.kick, 2, { by = by })
			expect(ok).toBe(true)
		end
	end)

	it("Actor kinds and user ids", function()
		local A = ModerationServer.Actor
		local p = StudWork.test.player(7, "Seven", true)
		expect(A.kind(p, "x")).toBe("staff")
		expect(A.kind("server", "x")).toBe("server")
		expect(A.kind("console", "x")).toBe("console")
		expect(A.kind("system", "x")).toBe("system")
		expect(A.userId(p)).toBe(7)
		expect(A.userId("server")).toBe(0)
		expect(A.isTrusted("server")).toBe(true)
		expect(A.isTrusted("console")).toBe(true)
		expect(A.isTrusted("system")).toBe(false)
		expect(A.isTrusted("staff")).toBe(false)
		expect(A.isPlayer(StudWork.test.player(8))).toBe(false) -- a plain table mock is not a Player
		expect(pcall(A.kind, nil, "x")).toBe(false)
	end)

	it("the Moderation and Reports copies are identical", function()
		expect(fs.readFile("packages/kits/moderation/Reports/server/Actor.luau")).toBe(
			fs.readFile("packages/kits/moderation/Moderation/server/Actor.luau")
		)
		expect(ReportsServer.Actor).never.toBe(nil)
	end)
end)

describe("Admin extensions keep what modules register in init", function()
	local function withAdmin(register)
		local part = AdminServer.new()
		local probe = StudWork.defineModule({
			name = "Probe",
			version = "1.0.0",
			framework = "^1.7.0",
			dependsOn = { Admin },
		})
		local h, err = StudWork.test.boot({
			modules = { Admin, probe },
			services = services(),
			servers = {
				Admin = part,
				Probe = {
					init = function(ctx)
						register(ctx.depsExt[Admin])
					end,
				},
			},
		})
		return h, err, part
	end

	local function action(id)
		return {
			id = id,
			permission = "kick",
			labelKey = "Admin.action.bring",
			target = "player",
			run = function()
				return true
			end,
		}
	end

	it("actions, tabs, data views, permissions, move hooks and the audit sink", function()
		local h, err, part = withAdmin(function(ext)
			ext.registerPermission("game.fly", { roles = { "admin" } })
			ext.registerAction(action("fly"))
			ext.registerTab({
				id = "audit",
				permission = "audit.read",
				labelKey = "Admin.tab.audit",
				fetch = function()
					return { rows = {}, columns = {} }
				end,
			})
			ext.registerDataView("pets", function()
				return {}
			end)
			ext.onStaffMove(function() end)
			ext.registerAuditSink(function() end)
		end)
		assert(h, err)
		local reg = part.registered()
		expect(reg.permissions["game.fly"].roles).toEqual({ "admin" })
		expect(reg.actions).toEqual({ "fly" })
		expect(reg.tabs).toEqual({ "audit" })
		expect(reg.dataViews).toEqual({ "pets" })
		expect(reg.moveHooks).toBe(1)
		expect(reg.auditSink).toBe(true)
	end)

	it("refuses bad definitions, duplicates and a second sink", function()
		local cases = {
			function(ext)
				ext.registerAction({
					id = "bad id!",
					permission = "kick",
					labelKey = "k",
					target = "player",
					run = print,
				})
			end,
			function(ext)
				ext.registerAction(action("a"))
				ext.registerAction(action("a"))
			end,
			function(ext)
				ext.registerAction({
					id = "a",
					permission = "kick",
					labelKey = "k",
					target = "everyone",
					run = print,
				})
			end,
			function(ext)
				ext.registerTab({ id = "t", permission = "audit.read", labelKey = "k" })
			end,
			function(ext)
				ext.registerPermission("ban")
			end,
			function(ext)
				ext.registerAuditSink(print)
				ext.registerAuditSink(print)
			end,
		}
		for _, case in cases do
			local h = withAdmin(case)
			expect(h).toBe(nil)
		end
	end)

	it("registering after start errors", function()
		local h, err, part = withAdmin(function() end)
		assert(h, err)
		expect(pcall(part.extensions.registerAction, action("late"))).toBe(false)
	end)
end)

describe("engine fakes", function()
	it("Players: bans, validation, failNext, history pages, recorded calls", function()
		local players = Fakes.players()
		local p = StudWork.test.player(5, "Five", true)
		players.setOnline({ p })
		expect(players.BanningEnabled).toBe(true)
		local base = { UserIds = { 5 }, Duration = 60, DisplayReason = "x", PrivateReason = "y" }
		players.failNext(2)
		local ok, err = pcall(players.BanAsync, players, base)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("failure for UserId 5")
		players.failNext(0)
		expect(pcall(players.BanAsync, players, base)).toBe(false) -- the second injected failure
		players.failNext(1, "Players:BanAsync: invalid argument")
		local _, err2 = pcall(players.BanAsync, players, base)
		expect(tostring(err2)).toBe("Players:BanAsync: invalid argument")
		expect(pcall(players.BanAsync, players, base)).toBe(true)
		expect(players.bans[5].Duration).toBe(60)
		expect(p.kicked).toBe("x")
		expect(
			pcall(
				players.BanAsync,
				players,
				{ UserIds = { 5 }, Duration = 0, DisplayReason = "", PrivateReason = "" }
			)
		).toBe(false)
		expect(
			pcall(
				players.BanAsync,
				players,
				{ UserIds = { 5 }, Duration = 1.5, DisplayReason = "", PrivateReason = "" }
			)
		).toBe(false)
		expect(
			pcall(
				players.BanAsync,
				players,
				{ UserIds = { 5 }, Duration = -1, DisplayReason = string.rep("a", 401), PrivateReason = "" }
			)
		).toBe(false)
		expect(pcall(players.UnbanAsync, players, { UserIds = { 5 }, ApplyToUniverse = true })).toBe(true)
		expect(players.bans[5]).toBe(nil)
		expect(players.count("BanAsync")).toBe(7)
		expect(players.count("UnbanAsync")).toBe(1)

		players.BanAsync(players, { UserIds = { 5 }, Duration = -1, DisplayReason = "z", PrivateReason = "" })
		local pages = players:GetBanHistoryAsync(5)
		local first = pages:GetCurrentPage()
		expect(#first).toBe(2)
		expect(first[1].Ban).toBe(true) -- newest first
		expect(first[1].Duration).toBe(-1)
		expect(first[2].Ban).toBe(false)
		expect(pages.IsFinished).toBe(false)
		pages:AdvanceToNextPageAsync()
		expect(#pages:GetCurrentPage()).toBe(1)
		expect(pages.IsFinished).toBe(true)
		expect(players:GetPlayerByUserId(5)).toBe(p)
		expect(#players:GetPlayers()).toBe(1)
		expect(Fakes.players({ banningEnabled = false }).BanningEnabled).toBe(false)
	end)

	it("GroupService: roles per user and group, failNext, call counter", function()
		local g = Fakes.groupService({
			roles = {
				[7] = {
					[1] = { { Id = 11, Name = "Mod", Rank = 50 }, { Id = 12, Name = "Lead", Rank = 200 } },
				},
			},
		})
		local info = g:GetRolesInGroupAsync(1, 7)
		expect(info.IsMember).toBe(true)
		expect(info.Roles[1].Id).toBe(12) -- highest first
		expect(g:GetRolesInGroupAsync(2, 7)).toEqual({ IsMember = false, Roles = {} })
		g.failNext(1)
		expect(pcall(g.GetRolesInGroupAsync, g, 1, 7)).toBe(false)
		g.setRoles(7, 2, { { Id = 11, Name = "Mod", Rank = 50 } })
		expect(g:GetRolesInGroupAsync(2, 7).IsMember).toBe(true)
		expect(g.lookups()).toBe(4)
	end)

	it("TextChatService: channels, TextSources with CanSend, DescendantAdded", function()
		local t = Fakes.textChatService()
		local added = {}
		t.DescendantAdded:Connect(function(d)
			table.insert(added, d.ClassName)
		end)
		local general = t.addChannel("RBXGeneral")
		local src = general:AddUserAsync(3)
		expect(src.UserId).toBe(3)
		expect(src.CanSend).toBe(true)
		src.CanSend = false
		expect(t.source(3).CanSend).toBe(false)
		expect(t.TextChannels:FindFirstChild("RBXGeneral")).toBe(general)
		expect(#t.TextChannels:GetDescendants()).toBe(2)
		expect(added).toEqual({ "TextChannel", "TextSource" })
		expect(#t.sources(3)).toBe(1)
		expect(t.connections()).toBe(1)
	end)

	it("giveGui: a fake PlayerGui on a harness player, lookups recorded", function()
		local h = bootOk({ Admin })
		local p = h:addPlayer({ userId = 1 })
		local gui = Fakes.giveGui(p)
		expect(p:FindFirstChild("PlayerGui")).toBe(gui)
		expect(p:FindFirstChild("Backpack")).toBe(nil)
		gui.add({ Name = "Panel" })
		expect(gui:FindFirstChild("Panel").Name).toBe("Panel")
		expect(gui.lookups).toBe(1)
	end)

	it("the fakes pass through ctx.services.get (GroupService and TextChatService are allowed)", function()
		local got = {}
		local probe = StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" })
		local given = services()
		local h = StudWork.test.harness({
			modules = { probe },
			services = given,
			servers = {
				Probe = {
					init = function(ctx)
						got.g = ctx.services.get("GroupService")
						got.t = ctx.services.get("TextChatService")
						got.p = ctx.services.get("Players")
					end,
				},
			},
		})
		expect(h).never.toBe(nil)
		expect(got.g).toBe(given.GroupService)
		expect(got.t).toBe(given.TextChatService)
		expect(got.p).toBe(given.Players)
	end)
end)
