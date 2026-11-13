--!nocheck
--[[
	Admin permissions (design §2-§3, Addendum A): every built-in permission granted or denied by
	each default role, `can` is a pure check, `allow` adds the per-staff limits (actionsPerMinute,
	bansPerHour) and "disabled" when the flag is off.
]]
local H = require("packages/kits/moderation/tests/AdminHelpers.luau")
local Admin = H.Admin

local BUILT_IN = {
	"ban",
	"ban.permanent",
	"kick",
	"mute",
	"warn",
	"reports.read",
	"reports.resolve",
	"reports.reporters",
	"audit.read",
	"teleport",
	"spectate",
	"data.read",
	"data.grant",
	"announce",
	"shutdown",
}

-- the design's table (docs page "Built-in permissions and role defaults")
local GRANTED = {
	owner = BUILT_IN,
	admin = {
		"ban",
		"ban.permanent",
		"kick",
		"mute",
		"warn",
		"reports.read",
		"reports.resolve",
		"reports.reporters",
		"audit.read",
		"teleport",
		"spectate",
		"data.read",
		"announce",
	},
	moderator = {
		"ban",
		"kick",
		"mute",
		"warn",
		"reports.read",
		"reports.resolve",
		"audit.read",
		"teleport",
		"spectate",
	},
	helper = { "kick", "mute", "warn", "reports.read" },
}

local IDS = { owner = 1, admin = 2, moderator = 3, helper = 4 }

local function bootRoles(admin, extra)
	local opts = extra or {}
	opts.admin = admin
	opts.serverAdmin = H.users({ [1] = "owner", [2] = "admin", [3] = "moderator", [4] = "helper" })
	local h = H.boot(opts)
	local players = {}
	for name, id in IDS do
		players[name] = H.join(h, id)
	end
	players.none = H.join(h, 5)
	return h, players
end

describe("Admin permission boundaries", function()
	it("each built-in permission, granted or denied by each default role", function()
		local h, players = bootRoles()
		local a = h:use(Admin)
		for roleName, granted in GRANTED do
			local p = players[roleName]
			for _, perm in BUILT_IN do
				local want = table.find(granted, perm) ~= nil
				if a.can(p, perm) ~= want then
					error(`{roleName} {perm}: expected {tostring(want)}`)
				end
				expect(a.can(p, perm)).toBe(want)
				local ok, why = a.allow(p, perm)
				expect(ok).toBe(want)
				if not want then
					expect(why).toBe("no_permission")
				end
			end
			local list = a.permissions(p)
			expect(#list).toBe(#granted)
		end
		for _, perm in BUILT_IN do
			expect(a.can(players.none, perm)).toBe(false)
			expect({ a.allow(players.none, perm) }).toEqual({ false, "no_permission" })
		end
	end)

	it("an unknown permission or a non-player is never granted (except *)", function()
		local h, players = bootRoles()
		local a = h:use(Admin)
		expect(a.can(players.admin, "made.up")).toBe(false)
		expect(a.can(players.owner, "made.up")).toBe(true)
		expect(a.can(nil, "ban")).toBe(false)
		expect(a.can({ UserId = 1 }, "ban")).toBe(false)
		expect(a.can(players.owner, 5)).toBe(false)
	end)

	it("a game's roles config replaces a role's permission list", function()
		local h, players = bootRoles({ roles = { helper = { rank = 100, permissions = { "warn" } } } })
		local a = h:use(Admin)
		expect(a.can(players.helper, "warn")).toBe(true)
		expect(a.can(players.helper, "kick")).toBe(false)
	end)
end)

describe("Admin per-staff limits (allow)", function()
	it("actionsPerMinute counts every allowed call; can never counts", function()
		local h, players = bootRoles({ limits = { actionsPerMinute = 3, bansPerHour = 20 } })
		local a = h:use(Admin)
		local m = players.moderator
		for _ = 1, 10 do
			expect(a.can(m, "kick")).toBe(true)
		end
		for _ = 1, 3 do
			expect({ a.allow(m, "kick") }).toEqual({ true })
		end
		expect({ a.allow(m, "warn") }).toEqual({ false, "rate_limited" })
		-- per staff member: another one isn't affected
		expect({ a.allow(players.admin, "warn") }).toEqual({ true })
		h.clock += 61
		expect({ a.allow(m, "kick") }).toEqual({ true })
	end)

	it("bansPerHour counts ban and ban.permanent only", function()
		local h, players = bootRoles({ limits = { actionsPerMinute = 100, bansPerHour = 2 } })
		local a = h:use(Admin)
		local p = players.admin
		expect({ a.allow(p, "ban") }).toEqual({ true })
		expect({ a.allow(p, "ban.permanent") }).toEqual({ true })
		expect({ a.allow(p, "ban") }).toEqual({ false, "rate_limited" })
		expect({ a.allow(p, "kick") }).toEqual({ true })
		h.clock += 3599
		expect({ a.allow(p, "ban") }).toEqual({ false, "rate_limited" })
		h.clock += 2
		expect({ a.allow(p, "ban") }).toEqual({ true })
	end)

	it("a refused call (no permission) doesn't count", function()
		local h, players = bootRoles({ limits = { actionsPerMinute = 2, bansPerHour = 20 } })
		local a = h:use(Admin)
		for _ = 1, 5 do
			expect({ a.allow(players.helper, "ban") }).toEqual({ false, "no_permission" })
		end
		expect({ a.allow(players.helper, "kick") }).toEqual({ true })
	end)

	it("the limits survive a rejoin in the same server", function()
		local h, players = bootRoles({ limits = { actionsPerMinute = 1, bansPerHour = 20 } })
		local a = h:use(Admin)
		expect({ a.allow(players.helper, "kick") }).toEqual({ true })
		h:rejoin(players.helper, { secondsAway = 5 })
		expect({ a.allow(players.helper, "kick") }).toEqual({ false, "rate_limited" })
	end)
end)

describe("Admin flag (kill switch)", function()
	it("off: nobody is staff, can is false, allow says disabled", function()
		local flags = { staffOn = { default = true } }
		local h = H.boot({ isStudio = true, flags = flags, admin = { flag = "staffOn" } })
		local p = H.join(h, 1)
		local a = h:use(Admin)
		expect(a.can(p, "ban")).toBe(true)
		h:console("flags set staffOn false")
		expect(a.can(p, "ban")).toBe(false)
		expect(a.isStaff(p)).toBe(false)
		expect(a.roleOf(p)).toBe(nil)
		expect(a.permissions(p)).toEqual({})
		expect(a.onlineStaff()).toEqual({})
		expect({ a.allow(p, "ban") }).toEqual({ false, "disabled" })
		expect({ a.rankOfUserId(1) }).toEqual({ true, 0 })
		h:console("flags set staffOn true")
		expect(a.isStaff(p)).toBe(true)
	end)
end)

describe("Admin limitsOf (design §12)", function()
	it("the role's caps; none for owner and admin; {} for non-staff", function()
		local h, players = bootRoles()
		local a = h:use(Admin)
		expect(a.limitsOf(players.moderator)).toEqual({ maxBanSeconds = 7 * 86400, maxMuteSeconds = 86400 })
		expect(a.limitsOf(players.helper)).toEqual({ maxMuteSeconds = 3600 })
		expect(a.limitsOf(players.owner)).toEqual({})
		expect(a.limitsOf(players.admin)).toEqual({})
		expect(a.limitsOf(players.none)).toEqual({})
		expect(table.isfrozen(a.limitsOf(players.moderator))).toBe(true)
	end)
end)
