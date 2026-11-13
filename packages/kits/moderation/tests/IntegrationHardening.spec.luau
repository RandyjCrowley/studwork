--!nocheck
--[[
	Addendum G (after the final review), end to end with the REAL Admin, Moderation and Reports:
	  H1  a staff target whose role lookup failed is unknown, never "not staff": Moderation refuses
	      (unknown_rank) and Reports hides reports about them; Admin.rankOfChecked
	  M   the Reports viewer rule never spends a group lookup: Admin's in-server and cached ranks only
	      (fix 2: a rank remembered from an earlier report is never used; unknown = hidden)
	  L   (fix 2) queue() summaries carry the documented fields only (no target rank)
	  M   an absent-target punish carries the sender's role caps and they are enforced on delivery
	  L   unban / history don't count toward bansPerHour; a claimed report is resolved only by its
	      claimer or a higher rank
]]
local I = require("packages/kits/moderation/tests/IntegrationHelpers.luau")

local OWNER, ADMIN, MOD, MOD2, HELPER = 10, 11, 12, 14, 13
local GROUP_ADMIN = 777
local PLAYER = 50
local DAY = 86400

local USERS = {
	[OWNER] = "owner",
	[ADMIN] = "admin",
	[MOD] = "moderator",
	[MOD2] = "moderator",
	[HELPER] = "helper",
}
local GROUPS = { { groupId = 7, roles = { { minRank = 200, role = "admin" } } } }

local function boot(opts)
	opts = opts or {}
	opts.users = opts.users or USERS
	return I.boot(opts)
end

local function rowTargets(rows)
	local out = {}
	for _, row in (rows and rows.rows) or {} do
		table.insert(out, row.target)
	end
	return out
end

local function mentions(rows, userId)
	for _, t in rowTargets(rows) do
		if string.find(t, tostring(userId), 1, true) then
			return true
		end
	end
	return false
end

describe("H1: an unresolved staff target fails closed", function()
	it("Moderation refuses unknown_rank until the lookup succeeds, then outranked", function()
		local env = boot({ groups = GROUPS })
		env.groups.setRoles(7, GROUP_ADMIN, { { Id = 1, Name = "Lead", Rank = 250 } })
		local mod = env.add(MOD)
		env.groups.failNext(1)
		local groupAdmin = env.add(GROUP_ADMIN)
		-- the lookup failed: Admin doesn't know the rank (rankOf still answers 0 for compatibility)
		expect(env.admin.rankOf(groupAdmin)).toBe(0)
		expect(env.admin.rankOfChecked(groupAdmin)).toBe(nil)
		expect(env.admin.rankOfChecked(GROUP_ADMIN)).toBe(nil)
		-- game code acting for the moderator: refused, nothing applied
		expect(select(2, env.mod.kick(groupAdmin, { by = mod }))).toBe("unknown_rank")
		expect(select(2, env.mod.ban(groupAdmin, { by = mod, seconds = 3600 }))).toBe("unknown_rank")
		expect(groupAdmin.kicked).toBe(nil)
		expect(env.players.bans[GROUP_ADMIN]).toBe(nil)
		-- a regular player resolved in this server is known: rank 0
		local p = env.add(PLAYER)
		expect(env.admin.rankOfChecked(p)).toBe(0)
		-- the re-check after groupRetrySeconds resolves the role: now outranked
		env.h:tick(61)
		expect(env.admin.rankOfChecked(groupAdmin)).toBe(300)
		expect(select(2, env.mod.kick(groupAdmin, { by = mod }))).toBe("outranked")
		expect(groupAdmin.kicked).toBe(nil)
	end)

	it("Reports hides reports about a staff member whose rank is unknown", function()
		local env = boot({ groups = GROUPS })
		env.groups.setRoles(7, GROUP_ADMIN, { { Id = 1, Name = "Lead", Rank = 250 } })
		local mod = env.add(MOD)
		env.groups.failNext(1)
		env.add(GROUP_ADMIN)
		env.add(PLAYER)
		for i = 1, 2 do
			local r = env.h:addPlayer({ userId = 70000 + i })
			expect(env.h:action(r, I.Reports, "submit", GROUP_ADMIN, "harassment", nil)).toBe(true)
			expect(env.h:action(r, I.Reports, "submit", PLAYER, "harassment", nil)).toBe(true)
		end
		local rows = env.fetch(mod, "reports", 1)
		expect(mentions(rows, PLAYER)).toBe(true)
		expect(mentions(rows, GROUP_ADMIN)).toBe(false)
		local okQ, list = env.reports.queue({ by = mod })
		expect(okQ).toBe(true)
		for _, s in list do
			expect(s.target).never.toBe(GROUP_ADMIN)
		end
		-- claim and detail of the hidden report: not found for the moderator
		local okAll, all = env.reports.queue({ by = "server" })
		expect(okAll).toBe(true)
		local hiddenId
		for _, s in all do
			if s.target == GROUP_ADMIN then
				hiddenId = s.id
			end
		end
		expect(hiddenId).never.toBe(nil)
		expect(select(2, env.reports.detail(hiddenId, { by = mod }))).toBe("not_found")
		expect(select(2, env.reports.claim(hiddenId, { by = mod }))).toBe("not_found")
	end)
end)

describe("the Reports viewer rule spends no group lookup", function()
	it("offline targets: Admin's cache only; once it expires the rank is unknown and hidden", function()
		local env = boot({ groups = GROUPS })
		env.groups.setRoles(7, GROUP_ADMIN, { { Id = 1, Name = "Lead", Rank = 250 } })
		local mod = env.add(MOD)
		local groupAdmin = env.add(GROUP_ADMIN)
		local targets = {}
		for i = 1, 5 do
			targets[i] = env.add(PLAYER + i)
		end
		local n = 0
		for _, target in { GROUP_ADMIN, PLAYER + 1, PLAYER + 2, PLAYER + 3, PLAYER + 4, PLAYER + 5 } do
			n += 1
			local r = env.h:addPlayer({ userId = 70000 + n })
			expect(env.reports.submit(r, target, "harassment", nil)).toBe(true)
		end
		-- every target leaves: Admin's group cache still knows their ranks
		env.h:removePlayer(groupAdmin)
		for _, t in targets do
			env.h:removePlayer(t)
		end
		local before = env.groups.lookups()
		local rows = env.fetch(mod, "reports", 1)
		expect(env.groups.lookups()).toBe(before)
		-- the five regular players (cached rank 0) are shown; the admin isn't
		expect(#rows.rows).toBe(5)
		expect(mentions(rows, GROUP_ADMIN)).toBe(false)
		local okQ, list = env.reports.queue({ by = mod })
		expect(okQ).toBe(true)
		expect(#list).toBe(5)
		expect(env.groups.lookups()).toBe(before)
		-- (fix 2) the group cache expires: every rank is unknown, so every report is hidden from the
		-- moderator (trusted code still sees them); still no lookup spent
		env.h:tick(700)
		rows = env.fetch(mod, "reports", 1)
		expect(#rows.rows).toBe(0)
		okQ, list = env.reports.queue({ by = mod })
		expect(okQ).toBe(true)
		expect(#list).toBe(0)
		local okAll, all = env.reports.queue({ by = "server" })
		expect(okAll).toBe(true)
		expect(#all).toBe(6)
		expect(env.groups.lookups()).toBe(before)
	end)

	it(
		"fix 2: a player reported as rank 0 and promoted later is hidden while the new rank is unknown",
		function()
			local env = boot({ groups = GROUPS })
			local mod = env.add(MOD)
			-- not in the group yet: rank 0, known, so the report is visible
			local x = env.add(GROUP_ADMIN)
			expect(env.admin.rankOfChecked(x)).toBe(0)
			local r1 = env.h:addPlayer({ userId = 70001 })
			expect(env.h:action(r1, I.Reports, "submit", GROUP_ADMIN, "harassment", nil)).toBe(true)
			expect(mentions(env.fetch(mod, "reports", 1), GROUP_ADMIN)).toBe(true)
			-- promoted to a group admin role; leaves, the cache expires, and rejoins while the lookup fails
			env.groups.setRoles(7, GROUP_ADMIN, { { Id = 1, Name = "Lead", Rank = 250 } })
			env.h:removePlayer(x)
			env.h:tick(700)
			env.groups.failNext(1)
			x = env.add(GROUP_ADMIN)
			expect(env.admin.rankOfChecked(x)).toBe(nil)
			-- the rank 0 known when the report was filed doesn't make it visible
			local rows = env.fetch(mod, "reports", 1)
			expect(mentions(rows, GROUP_ADMIN)).toBe(false)
			local okQ, list = env.reports.queue({ by = mod })
			expect(okQ).toBe(true)
			expect(#list).toBe(0)
			-- nor does another report filed while the rank is unknown
			local r2 = env.h:addPlayer({ userId = 70002 })
			expect(env.h:action(r2, I.Reports, "submit", GROUP_ADMIN, "harassment", nil)).toBe(true)
			okQ, list = env.reports.queue({ by = mod })
			expect(okQ).toBe(true)
			expect(#list).toBe(0)
			local _, all = env.reports.queue({ by = "server" })
			expect(#all).toBe(1)
			expect(select(2, env.reports.detail(all[1].id, { by = mod }))).toBe("not_found")
			expect(select(2, env.reports.claim(all[1].id, { by = mod }))).toBe("not_found")
			-- once Admin knows the rank (300 > the moderator's 200), it stays hidden
			env.h:tick(61)
			expect(env.admin.rankOfChecked(x)).toBe(300)
			okQ, list = env.reports.queue({ by = mod })
			expect(#list).toBe(0)
		end
	)

	it("fix 2: queue() summaries carry the documented fields only", function()
		local env = boot()
		local mod = env.add(MOD)
		env.add(PLAYER)
		local r = env.h:addPlayer({ userId = 70001 })
		expect(env.h:action(r, I.Reports, "submit", PLAYER, "harassment", nil)).toBe(true)
		local documented = {
			id = true,
			at = true,
			lastAt = true,
			target = true,
			targetName = true,
			category = true,
			count = true,
			distinct = true,
			status = true,
			claimedBy = true,
		}
		for _, who in { mod, "server" } do
			local ok, list = env.reports.queue({ by = who })
			expect(ok).toBe(true)
			expect(#list).toBe(1)
			for k in list[1] do
				expect(documented[k]).toBe(true)
			end
			expect(list[1].targetRank).toBe(nil)
		end
	end)
end)

describe("role caps on an absent-target punish", function()
	it("the sender's maxBanSeconds rides with the message and is enforced on delivery", function()
		local config = {
			Moderation = {
				ladders = { long = { { action = "ban", seconds = 30 * DAY } } },
				offenses = { exploit = { ladder = "long", displayKey = "Moderation.ban.cheating" } },
			},
		}
		local env = boot({ config = config })
		local mod = env.add(MOD) -- moderator: maxBanSeconds = 7 days
		expect(select(2, env.mod.punish(PLAYER, "exploit", { by = mod }))).toBe("sent")
		env.h:tick(2)
		local p = env.add(PLAYER)
		env.h:tick(2)
		expect(env.players.bans[PLAYER]).toBe(nil)
		expect(p.kicked).toBe(nil)
		local refused = I.find(env.audit({ target = PLAYER }), function(e)
			return e.action == "ban" and e.status == "refused"
		end)
		expect(#refused).toBe(1)
		expect(refused[1].by).toBe(MOD)
		-- the owner has no cap: the same punish bans on delivery
		local owner = env.add(OWNER)
		expect(select(2, env.mod.punish(PLAYER + 1, "exploit", { by = owner }))).toBe("sent")
		env.h:tick(2)
		env.add(PLAYER + 1)
		env.h:tick(2)
		expect(env.players.bans[PLAYER + 1]).never.toBe(nil)
	end)
end)

describe("bansPerHour counts bans only", function()
	it("unbans, server bans and history reads don't use the ban allowance", function()
		local env = boot({ config = { Admin = { limits = { actionsPerMinute = 30, bansPerHour = 1 } } } })
		local mod = env.add(MOD)
		for i = 1, 3 do
			expect(select(2, env.mod.unban(600 + i, { by = mod }))).toBe("unbanned")
		end
		local victim = env.add(PLAYER)
		expect(env.mod.serverBan(victim, { by = mod, seconds = 600 })).toBe(true)
		env.mod.history(601, { by = mod })
		expect(select(2, env.mod.ban(700, { by = mod, seconds = 3600 }))).toBe("banned")
		expect(select(2, env.mod.ban(701, { by = mod, seconds = 3600 }))).toBe("rate_limited")
	end)
end)

describe("resolving a claimed report", function()
	it("only the claimer or a higher rank (or trusted code) may resolve it", function()
		local env = boot()
		local mod = env.add(MOD)
		local mod2 = env.add(MOD2)
		local admin = env.add(ADMIN)
		env.add(PLAYER)
		env.add(PLAYER + 1)
		local r = env.h:addPlayer({ userId = 70001 })
		expect(env.h:action(r, I.Reports, "submit", PLAYER, "harassment", nil)).toBe(true)
		expect(env.h:action(r, I.Reports, "submit", PLAYER + 1, "harassment", nil)).toBe(true)
		local _, list = env.reports.queue({ by = "server" })
		local idA, idB
		for _, s in list do
			if s.target == PLAYER then
				idA = s.id
			else
				idB = s.id
			end
		end
		expect(env.reports.claim(idA, { by = mod })).toBe(true)
		expect(env.reports.claim(idB, { by = mod })).toBe(true)
		-- an equal rank can't resolve another moderator's claim
		expect(select(2, env.reports.resolve(idA, "dismissed", { by = mod2 }))).toBe("claimed")
		-- a higher rank can; so can trusted code
		expect(env.reports.resolve(idA, "dismissed", { by = admin })).toBe(true)
		expect(env.reports.resolve(idB, "dismissed", { by = "server" })).toBe(true)
		local _, rest = env.reports.queue({ by = "server" })
		expect(#rest).toBe(0)
	end)
end)
