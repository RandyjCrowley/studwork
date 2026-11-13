--!nocheck
--[[
	Admin, Addendum G (after the final review):
	  H1  rankOfChecked: the rank only when known without a group lookup (nil = unknown); never
	      spends the lookup budget for a user id outside this server
	  L   allow(staff, permission, action): only a ban action counts toward bansPerHour
	  L   spectate is cleared when the spectated player leaves
]]
local H = require("packages/kits/moderation/tests/AdminHelpers.luau")
local Fakes = H.Fakes
local Admin = H.Admin

local GROUP = 7

local function groupRules()
	return {
		users = { [1] = "owner" },
		groups = { { groupId = GROUP, roles = { { minRank = 200, role = "moderator" } } } },
	}
end

describe("rankOfChecked", function()
	it("nil while a player's lookup failed; the rank once resolved; 0 for a resolved non-staff", function()
		local groups =
			Fakes.groupService({ roles = { [GROUP] = { [5] = { { Id = 1, Name = "m", Rank = 250 } } } } })
		local h = H.boot({ serverAdmin = groupRules(), groups = groups, admin = { groupRetrySeconds = 30 } })
		local a = h:use(Admin)
		groups.failNext(1)
		local mod = H.join(h, 5)
		expect(a.rankOf(mod)).toBe(0)
		expect(a.rankOfChecked(mod)).toBe(nil)
		local p = H.join(h, 6)
		expect(a.rankOfChecked(p)).toBe(0)
		expect(a.rankOfChecked(1)).toBe(400) -- the users map: known without a lookup
		h:tick(31)
		expect(a.rankOfChecked(mod)).toBe(200)
		expect(a.rankOfChecked(5)).toBe(200)
	end)

	it("a user id outside this server: fresh group cache only, never a lookup", function()
		local groups =
			Fakes.groupService({ roles = { [GROUP] = { [5] = { { Id = 1, Name = "m", Rank = 250 } } } } })
		local h = H.boot({ serverAdmin = groupRules(), groups = groups })
		local a = h:use(Admin)
		expect(a.rankOfChecked(5)).toBe(nil)
		expect(a.rankOfChecked(8)).toBe(nil)
		expect(groups.lookups()).toBe(0)
		-- rankOfUserId spends a lookup and fills the cache; then rankOfChecked knows
		expect(select(2, a.rankOfUserId(5))).toBe(200)
		local spent = groups.lookups()
		expect(a.rankOfChecked(5)).toBe(200)
		expect(groups.lookups()).toBe(spent)
		-- the cache entry expires: unknown again
		h:tick(601)
		expect(a.rankOfChecked(5)).toBe(nil)
		expect(groups.lookups()).toBe(spent)
	end)
end)

describe("allow and bansPerHour", function()
	it("only a ban action counts toward bansPerHour; the permission is still checked", function()
		local h = H.boot({
			serverAdmin = H.users({ [1] = "moderator", [2] = "helper" }),
			admin = { limits = { actionsPerMinute = 30, bansPerHour = 1 } },
		})
		local a = h:use(Admin)
		local mod = H.join(h, 1)
		local helper = H.join(h, 2)
		for _ = 1, 3 do
			expect(a.allow(mod, "ban", "unban")).toBe(true)
			expect(a.allow(mod, "ban", "history")).toBe(true)
		end
		expect(select(2, a.allow(helper, "ban", "unban"))).toBe("no_permission")
		expect(a.allow(mod, "ban", "ban")).toBe(true)
		expect(select(2, a.allow(mod, "ban", "ban"))).toBe("rate_limited")
		-- without an action, the permission itself decides (unchanged)
		expect(select(2, a.allow(mod, "ban"))).toBe("rate_limited")
	end)
end)

describe("spectate", function()
	it("the spectated player leaving clears the staff member's spectate (Spectate(nil))", function()
		local h = H.boot({ serverAdmin = H.users({ [1] = "moderator" }) })
		local mod = H.join(h, 1)
		local target = H.join(h, 3)
		H.run(h, mod, "spectate", 3)
		mod.ReplicationFocus = "focus"
		h:removePlayer(target)
		local sent = h:sent("Admin", "Spectate")
		expect(#sent).toBe(2)
		expect(sent[2].player).toBe(mod)
		expect(sent[2].args[1]).toBe(nil)
		expect(mod.ReplicationFocus).toBe(nil)
	end)
end)
