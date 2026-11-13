--!nocheck
--[[
	Admin roles (design §3, B4): ServerConfig.Admin users and group rules (GroupService through
	ctx.services, faked), the group cache, the per-server lookup budget, the re-check after a
	failure, Studio vs live, rankOfUserId (fail closed), onlineStaff, StaffJoined, permissions().
]]
local H = require("packages/kits/moderation/tests/AdminHelpers.luau")
local Fakes = H.Fakes
local Admin = H.Admin

local GROUP = 7
local function role(id, rank)
	return { Id = id, Name = "r" .. id, Rank = rank }
end

local function groupRules()
	return {
		groups = {
			{
				groupId = GROUP,
				roles = {
					{ minRank = 200, role = "moderator" },
					{ roleId = 9001, role = "admin" },
					{ minRank = 100, role = "helper" },
				},
			},
		},
	}
end

describe("Admin roles: live", function()
	it("nobody is staff unless configured", function()
		local h = H.boot()
		local p = H.join(h, 1)
		local a = h:use(Admin)
		expect(a.isStaff(p)).toBe(false)
		expect(a.roleOf(p)).toBe(nil)
		expect(a.rankOf(p)).toBe(0)
		expect(a.permissions(p)).toEqual({})
		expect(a.onlineStaff()).toEqual({})
		expect(h:state(p).modules.Admin).toBe(nil)
	end)

	it("the users map gives a role; onlineStaff and StaffJoined", function()
		local h = H.boot({ serverAdmin = H.users({ [5] = "moderator" }) })
		local joined = {}
		h:use(Admin).signals.StaffJoined:Connect(function(p, r)
			table.insert(joined, { p.UserId, r })
		end)
		local mod = H.join(h, 5)
		local other = H.join(h, 6)
		local a = h:use(Admin)
		expect(a.roleOf(mod)).toBe("moderator")
		expect(a.rankOf(mod)).toBe(200)
		expect(a.isStaff(other)).toBe(false)
		expect(a.onlineStaff()).toEqual({ mod })
		expect(joined).toEqual({ { 5, "moderator" } })
		expect(table.isfrozen(a.permissions(mod))).toBe(true)
		expect(table.find(a.permissions(mod), "ban")).never.toBe(nil)
		expect(table.find(a.permissions(mod), "ban.permanent")).toBe(nil)
	end)

	it("group rules: minRank or roleId, the highest-rank matching role wins", function()
		local groups = Fakes.groupService({
			roles = {
				[GROUP] = {
					[1] = { role(1, 150) }, -- helper (minRank 100)
					[2] = { role(2, 220) }, -- moderator (minRank 200), helper too: moderator wins
					[3] = { role(9001, 10) }, -- roleId 9001 -> admin despite the low rank
					[4] = { role(4, 50) }, -- no rule matches
				},
			},
		})
		local h = H.boot({ groups = groups, serverAdmin = groupRules() })
		local a = h:use(Admin)
		expect(a.roleOf(H.join(h, 1))).toBe("helper")
		expect(a.roleOf(H.join(h, 2))).toBe("moderator")
		expect(a.roleOf(H.join(h, 3))).toBe("admin")
		expect(a.roleOf(H.join(h, 4))).toBe(nil)
		expect(a.roleOf(H.join(h, 5))).toBe(nil) -- not a member
		expect(groups.lookups()).toBe(5)
	end)

	it("the users map is used first: no group lookup for a listed user", function()
		local groups = Fakes.groupService({ roles = { [GROUP] = { [1] = { role(9001, 1) } } } })
		local sc = groupRules()
		sc.users = { [1] = "helper" }
		local h = H.boot({ groups = groups, serverAdmin = sc })
		expect(h:use(Admin).roleOf(H.join(h, 1))).toBe("helper")
		expect(groups.lookups()).toBe(0)
	end)

	it("group results are cached per user and group for groupCacheSeconds", function()
		local groups = Fakes.groupService({ roles = { [GROUP] = { [50] = { role(1, 250) } } } })
		local h = H.boot({ groups = groups, serverAdmin = groupRules(), admin = { groupCacheSeconds = 100 } })
		local a = h:use(Admin)
		expect({ a.rankOfUserId(50) }).toEqual({ true, 200 })
		expect({ a.rankOfUserId(50) }).toEqual({ true, 200 })
		expect(groups.lookups()).toBe(1)
		h.clock += 99
		a.rankOfUserId(50)
		expect(groups.lookups()).toBe(1)
		h.clock += 2
		groups.setRoles(GROUP, 50, nil) -- left the group
		expect({ a.rankOfUserId(50) }).toEqual({ true, 0 })
		expect(groups.lookups()).toBe(2)
	end)

	it("the lookup budget: over it a joiner isn't staff yet and is checked again later", function()
		local list = {}
		for id = 1, 3 do
			list[id] = { role(1, 150) }
		end
		local groups = Fakes.groupService({ roles = { [GROUP] = list } })
		local h = H.boot({
			groups = groups,
			serverAdmin = groupRules(),
			admin = { groupLookupsPerMinute = 2, groupRetrySeconds = 30 },
		})
		local a = h:use(Admin)
		local p1, p2, p3 = H.join(h, 1), H.join(h, 2), H.join(h, 3)
		expect(a.isStaff(p1)).toBe(true)
		expect(a.isStaff(p2)).toBe(true)
		expect(a.isStaff(p3)).toBe(false)
		expect(groups.lookups()).toBe(2)
		-- over budget: rankOfUserId fails closed
		expect({ a.rankOfUserId(99) }).toEqual({ false, 0 })
		expect(groups.lookups()).toBe(2)
		h:tick(29)
		expect(a.isStaff(p3)).toBe(false)
		h:tick(31) -- the minute has passed: budget back, the re-check runs
		expect(a.isStaff(p3)).toBe(true)
		expect(a.roleOf(p3)).toBe("helper")
		expect(groups.lookups()).toBe(3)
	end)

	it("a failed lookup: not staff, logged, retried after groupRetrySeconds", function()
		local groups = Fakes.groupService({ roles = { [GROUP] = { [1] = { role(1, 250) } } } })
		groups.failNext(1)
		local h = H.boot({ groups = groups, serverAdmin = groupRules(), admin = { groupRetrySeconds = 60 } })
		local joined = 0
		h:use(Admin).signals.StaffJoined:Connect(function()
			joined += 1
		end)
		local p = H.join(h, 1)
		local a = h:use(Admin)
		expect(a.isStaff(p)).toBe(false)
		expect(h:state(p).modules.Admin).toBe(nil)
		local warned = false
		for _, w in h:warnings() do
			if string.find(w, "group lookup failed", 1, true) then
				warned = true
			end
		end
		expect(warned).toBe(true)
		h:tick(59)
		expect(a.isStaff(p)).toBe(false)
		h:tick(2)
		expect(a.roleOf(p)).toBe("moderator")
		expect(joined).toBe(1)
		expect(h:state(p).modules.Admin.extra.staff.role).toBe("moderator")
	end)

	it("a failed lookup keeps retrying while it fails, then stops", function()
		local groups = Fakes.groupService({ roles = { [GROUP] = { [1] = { role(1, 250) } } } })
		groups.failNext(3)
		local h = H.boot({ groups = groups, serverAdmin = groupRules(), admin = { groupRetrySeconds = 10 } })
		local p = H.join(h, 1)
		h:tick(35)
		expect(groups.lookups()).toBe(4)
		expect(h:use(Admin).isStaff(p)).toBe(true)
		h:tick(60)
		expect(groups.lookups()).toBe(4)
	end)
end)

describe("Admin roles: rankOfUserId for players not in this server (B4)", function()
	it("users map, group rules, not staff, and a failed lookup = (false, 0)", function()
		local groups = Fakes.groupService({ roles = { [GROUP] = { [21] = { role(9001, 1) } } } })
		local sc = groupRules()
		sc.users = { [20] = "owner" }
		local h = H.boot({ groups = groups, serverAdmin = sc })
		local a = h:use(Admin)
		expect({ a.rankOfUserId(20) }).toEqual({ true, 400 })
		expect({ a.rankOfUserId(21) }).toEqual({ true, 300 })
		expect({ a.rankOfUserId(22) }).toEqual({ true, 0 })
		groups.failNext(1)
		expect({ a.rankOfUserId(23) }).toEqual({ false, 0 })
		expect({ a.rankOfUserId("x") }).toEqual({ false, 0 })
		expect({ a.rankOfUserId(1.5) }).toEqual({ false, 0 })
	end)

	it("an online, resolved player answers from the session without a lookup", function()
		local groups = Fakes.groupService({ roles = { [GROUP] = { [1] = { role(1, 250) } } } })
		local h = H.boot({ groups = groups, serverAdmin = groupRules() })
		H.join(h, 1)
		expect(groups.lookups()).toBe(1)
		expect({ h:use(Admin).rankOfUserId(1) }).toEqual({ true, 200 })
		expect(groups.lookups()).toBe(1)
	end)
end)

describe("Admin roles: Studio", function()
	it("everyone is staff with studioRole; a users entry still wins", function()
		local h = H.boot({ isStudio = true, serverAdmin = H.users({ [2] = "helper" }) })
		local a = h:use(Admin)
		local p1, p2 = H.join(h, 1), H.join(h, 2)
		expect(a.roleOf(p1)).toBe("owner")
		expect(a.roleOf(p2)).toBe("helper")
		expect({ a.rankOfUserId(77) }).toEqual({ true, 400 })
	end)

	it("studioRole is configurable", function()
		local h = H.boot({ isStudio = true, admin = { studioRole = "moderator" } })
		expect(h:use(Admin).roleOf(H.join(h, 1))).toBe("moderator")
	end)

	it("the same players in a live server are not staff", function()
		local h = H.boot({ isStudio = false })
		expect(h:use(Admin).isStaff(H.join(h, 1))).toBe(false)
	end)
end)

describe("Admin roles: registered permissions and *", function()
	it("registerPermission adds to the listed roles; * includes it", function()
		local h = H.boot({
			serverAdmin = H.users({ [1] = "owner", [2] = "helper", [3] = "moderator" }),
			register = function(ext)
				ext.registerPermission("game.fly", { roles = { "helper" } })
			end,
		})
		local a = h:use(Admin)
		local owner, helper, mod = H.join(h, 1), H.join(h, 2), H.join(h, 3)
		expect(a.can(owner, "game.fly")).toBe(true)
		expect(a.can(helper, "game.fly")).toBe(true)
		expect(a.can(mod, "game.fly")).toBe(false)
		expect(table.find(a.permissions(owner), "game.fly")).never.toBe(nil)
		expect(table.find(a.permissions(owner), "shutdown")).never.toBe(nil)
		expect(table.find(a.permissions(helper), "game.fly")).never.toBe(nil)
	end)

	it("a role is dropped when the player leaves", function()
		local h = H.boot({ serverAdmin = H.users({ [1] = "admin" }) })
		local p = H.join(h, 1)
		h:removePlayer(p)
		local a = h:use(Admin)
		expect(a.isStaff(p)).toBe(false)
		expect(a.onlineStaff()).toEqual({})
		expect({ a.rankOfUserId(1) }).toEqual({ true, 300 })
	end)
end)
