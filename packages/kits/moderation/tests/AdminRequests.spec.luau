--!nocheck
--[[
	Admin client requests and replication (design §3, §9 actions, B4, B7, M18): a non-staff client
	faking every staff request gets no reply at all; extra.staff only for staff (never setAll);
	the panel only in a staff player's PlayerGui; the flag clears both; rank and self-target
	refusals (offline targets through rankOfUserId); argument checks; per-staff rate limits through
	requests.
]]
local H = require("packages/kits/moderation/tests/AdminHelpers.luau")
local Fakes = H.Fakes
local Admin = H.Admin
local Economy = H.Economy

-- a game module registering an action (target userId), a tab with a row action, and a data view
local function registerAll(record)
	return function(ext)
		local def, calls = H.action("poke", { permission = "kick", presets = { "Admin.panel.reason" } })
		record.calls = calls
		ext.registerAction(def)
		ext.registerTab({
			id = "queue",
			permission = "reports.read",
			labelKey = "Admin.tab.reports",
			fetch = function(_staff, page)
				record.fetched = (record.fetched or 0) + 1
				return {
					columns = { "who", "count" },
					rows = {
						{ id = "r1", who = "Admin.panel.reason", count = page },
						{ id = "r2", count = 2 },
					},
				}
			end,
			rowActions = {
				{
					id = "close",
					permission = "reports.resolve",
					labelKey = "Admin.panel.confirm",
					run = function(_staff, rowId)
						record.closed = rowId
						return true, "done"
					end,
				},
			},
		})
	end
end

describe("non-staff requests are dropped with no reply", function()
	it("Run (every action), Fetch (every tab), PanelOpen: nothing sent, nothing done, logged", function()
		local record = {}
		local h = H.boot({
			modules = { Economy },
			serverAdmin = H.users({ [1] = "owner" }),
			register = registerAll(record),
		})
		local owner = H.join(h, 1)
		local p, gui = H.join(h, 2, { gui = true })
		local before = #h:sent("Admin")
		local runs = {
			{ "teleportTo", 1 },
			{ "bring", 1 },
			{ "spectate", 1 },
			{ "stopSpectate" },
			{ "announce", nil, "Admin.announce.event" },
			{ "announce", nil, nil, nil, "hello" },
			{ "shutdown", nil, "Admin.shutdown.generic" },
			{ "grant", 2, "Coins", 100 },
			{ "dataView", 1 },
			{ "poke", 1, "Admin.panel.reason" },
			{ "queue/close", nil, "r1" },
			{ "nope", 1 },
			{ 42 },
		}
		for _, args in runs do
			local ok = H.run(h, p, args[1], args[2], args[3], args[4], args[5])
			expect(ok).toBe(true) -- the framework ran the handler; the handler said nothing
			h:tick(2) -- stay inside the framework's own action rate limit
		end
		for _, tab in { "players", "queue", "data", "announce", "nope" } do
			h:action(p, Admin, "fetch", tab, 1)
			h:tick(2)
		end
		h:action(p, Admin, "panelOpen", 0)
		expect(H.sentTo(h, p)).toEqual({})
		expect(#h:sent("Admin")).toBe(before) -- no Announce to all, no Spectate, no Rows anywhere
		expect(owner.kicked).toBe(nil)
		expect(p.kicked).toBe(nil)
		expect(h:use(Economy).balance(p)).toBe(0)
		expect(record.calls).toEqual({})
		expect(record.fetched).toBe(nil)
		expect(record.closed).toBe(nil)
		expect(gui.lookups).toBe(0)
		expect(#gui.children).toBe(0)
		expect(h:state(p).modules.Admin).toBe(nil)
		local drops = 0
		for _, l in h.logs do
			if
				string.find(l.msg, "dropped a", 1, true) and string.find(l.msg, "non-staff user 2", 1, true)
			then
				drops += 1
			end
		end
		expect(drops).toBe(#runs + 5 + 1)
	end)

	it("the same requests from staff do get replies (the drop is about who asks)", function()
		local h = H.boot({ serverAdmin = H.users({ [1] = "owner" }) })
		local owner = H.join(h, 1)
		H.join(h, 2)
		H.run(h, owner, "nope", 1)
		expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.invalid" })
		h:action(owner, Admin, "fetch", "players", 1)
		expect(#H.sentTo(h, owner, "Rows")).toBe(1)
	end)
end)

describe("replication: extra.staff only for staff", function()
	it("staff state is set for staff only; a non-staff player never has the key", function()
		local record = {}
		local h = H.boot({
			serverAdmin = H.users({ [1] = "moderator", [3] = "owner" }),
			register = registerAll(record),
		})
		local mod = H.join(h, 1)
		local plain = H.join(h, 2)
		local owner = H.join(h, 3)
		h:tick(5)
		local s = h:state(mod).modules.Admin.extra.staff
		expect(s.role).toBe("moderator")
		expect(s.rank).toBe(200)
		expect(table.find(s.permissions, "ban")).never.toBe(nil)
		local ids = {}
		for _, a in s.actions do
			table.insert(ids, a.id)
		end
		-- built-ins the moderator may use, then the registered action; no announce/shutdown/grant/data
		expect(ids).toEqual({ "teleportTo", "bring", "spectate", "stopSpectate", "poke" })
		expect(s.tabs[1].id).toBe("queue")
		expect(s.tabs[1].rowActions[1].id).toBe("close")
		local ownerIds = {}
		for _, a in h:state(owner).modules.Admin.extra.staff.actions do
			table.insert(ownerIds, a.id)
		end
		expect(ownerIds).toEqual({
			"teleportTo",
			"bring",
			"spectate",
			"stopSpectate",
			"announce",
			"shutdown",
			"dataView",
			"poke",
		})
		-- the non-staff player's state has no Admin slice and no staff list anywhere
		local plainState = h:state(plain)
		expect(plainState.modules.Admin).toBe(nil)
		local function mentions(t, depth)
			if depth > 8 or type(t) ~= "table" then
				return false
			end
			for k, v in t do
				if k == "staff" or v == "moderator" or v == "owner" then
					return true
				end
				if mentions(v, depth + 1) then
					return true
				end
			end
			return false
		end
		expect(mentions(plainState, 0)).toBe(false)
	end)

	it("a helper's tabs and row actions follow its permissions", function()
		local record = {}
		local h = H.boot({ serverAdmin = H.users({ [1] = "helper" }), register = registerAll(record) })
		local helper = H.join(h, 1)
		local s = h:state(helper).modules.Admin.extra.staff
		expect(#s.tabs).toBe(1)
		expect(s.tabs[1].rowActions).toEqual({}) -- reports.resolve is not a helper permission
		H.join(h, 2)
		h:action(helper, Admin, "fetch", "queue", 1)
		H.run(h, helper, "queue/close", nil, "r1")
		expect(H.last(h, helper)).toEqual({ ok = false, key = "Admin.result.no_permission" })
		expect(record.closed).toBe(nil)
	end)
end)

describe("panel delivery", function()
	it("is cloned into a staff player's PlayerGui only, once", function()
		H.withPanel(function()
			local h = H.boot({ serverAdmin = H.users({ [1] = "admin" }) })
			local staff, staffGui = H.join(h, 1, { gui = true })
			local plain, plainGui = H.join(h, 2, { gui = true })
			expect(#staffGui.children).toBe(1)
			expect(staffGui.children[1].Name).toBe("StudWorkAdminPanel")
			expect(plainGui.lookups).toBe(0)
			expect(#plainGui.children).toBe(0)
			h:action(staff, Admin, "panelOpen", 0)
			expect(#staffGui.children).toBe(1)
			h:action(plain, Admin, "panelOpen", 0)
			expect(plainGui.lookups).toBe(0)
			expect(#plainGui.children).toBe(0)
		end)
	end)

	it("panelOpen re-delivers a panel the staff player lost (respawn without the seam)", function()
		H.withPanel(function()
			local h = H.boot({ serverAdmin = H.users({ [1] = "admin" }) })
			local staff, gui = H.join(h, 1, { gui = true })
			gui.children[1]:Destroy()
			expect(#gui.children).toBe(0)
			h:action(staff, Admin, "panelOpen", 0)
			expect(#gui.children).toBe(1)
		end)
	end)

	it("a staff player without a PlayerGui gets nothing and nothing breaks", function()
		local h = H.boot({ serverAdmin = H.users({ [1] = "admin" }) })
		local staff = H.join(h, 1)
		h:action(staff, Admin, "panelOpen", 0)
		expect(h:use(Admin).isStaff(staff)).toBe(true)
	end)
end)

describe("flag off clears staff state and the panel", function()
	it("state key removed and panel destroyed; back on restores both", function()
		H.withPanel(function()
			local flags = { staffOn = { default = true } }
			local h = H.boot({ isStudio = true, flags = flags, admin = { flag = "staffOn" } })
			local p, gui = H.join(h, 1, { gui = true })
			expect(h:state(p).modules.Admin.extra.staff.role).toBe("owner")
			expect(#gui.children).toBe(1)
			h:console("flags set staffOn false")
			h:tick(1)
			local slice = h:state(p).modules.Admin
			expect(slice == nil or slice.extra == nil or slice.extra.staff == nil).toBe(true)
			expect(#gui.children).toBe(0)
			-- requests are now dropped silently
			local before = #H.sentTo(h, p)
			H.run(h, p, "stopSpectate")
			expect(#H.sentTo(h, p)).toBe(before)
			h:console("flags set staffOn true")
			h:tick(1)
			expect(h:state(p).modules.Admin.extra.staff.role).toBe("owner")
			expect(#gui.children).toBe(1)
		end)
	end)
end)

describe("rank and self-target rules", function()
	local function bootRank(groups)
		local record = {}
		local sc =
			H.users({ [1] = "moderator", [2] = "moderator", [3] = "admin", [4] = "helper", [30] = "owner" })
		sc.groups = { { groupId = 7, roles = { { minRank = 1, role = "helper" } } } }
		local h = H.boot({ groups = groups, serverAdmin = sc, register = registerAll(record) })
		return h, record
	end

	it("self, equal and higher rank are outranked; lower and non-staff are fine", function()
		local h, record = bootRank()
		local mod = H.join(h, 1)
		H.join(h, 2)
		H.join(h, 3)
		H.join(h, 4)
		local cases = {
			{ 1, false, "Admin.result.outranked" }, -- self
			{ 2, false, "Admin.result.outranked" }, -- equal
			{ 3, false, "Admin.result.outranked" }, -- higher
			{ 4, true, "Admin.result.done" }, -- helper: lower
			{ 5, true, "Admin.result.done" }, -- offline, not staff (group lookup: not a member)
		}
		for _, c in cases do
			H.run(h, mod, "poke", c[1], "Admin.panel.reason")
			expect(H.last(h, mod)).toEqual({ ok = c[2], key = c[3] })
			h:tick(2)
		end
		expect(#record.calls).toBe(2)
	end)

	it("offline targets: rank from the users map or a group lookup; a failed lookup fails closed", function()
		local groups =
			Fakes.groupService({ roles = { [7] = { [40] = { { Id = 1, Name = "m", Rank = 5 } } } } })
		local h, record = bootRank(groups)
		local helper = H.join(h, 4)
		-- 30 is an offline owner (users map)
		H.run(h, helper, "poke", 30, "Admin.panel.reason")
		expect(H.last(h, helper)).toEqual({ ok = false, key = "Admin.result.outranked" })
		h:tick(2)
		-- 40 is an offline helper through the group (equal rank)
		H.run(h, helper, "poke", 40, "Admin.panel.reason")
		expect(H.last(h, helper)).toEqual({ ok = false, key = "Admin.result.outranked" })
		h:tick(2)
		groups.failNext(1)
		H.run(h, helper, "poke", 41, "Admin.panel.reason")
		expect(H.last(h, helper)).toEqual({ ok = false, key = "Admin.result.unknown_rank" })
		expect(#record.calls).toBe(0)
	end)

	it("built-in actions follow the same rules (teleport to a higher rank is refused)", function()
		local h = bootRank()
		local mod = H.join(h, 1)
		H.join(h, 3)
		H.run(h, mod, "teleportTo", 3)
		expect(H.last(h, mod)).toEqual({ ok = false, key = "Admin.result.outranked" })
		H.run(h, mod, "spectate", 1)
		expect(H.last(h, mod)).toEqual({ ok = false, key = "Admin.result.outranked" })
	end)
end)

describe("arguments are checked against the action", function()
	it("unknown preset, duration not offered, free text not allowed, bad target", function()
		local record = {}
		local h = H.boot({ serverAdmin = H.users({ [1] = "owner" }), register = registerAll(record) })
		local owner = H.join(h, 1)
		H.join(h, 2)
		local bad = {
			{ "poke", 2, "Not.a.preset" },
			{ "poke", 2, "Admin.panel.reason", 60 },
			{ "poke", 2, "Admin.panel.reason", nil, "free" },
			{ "poke", 0 },
			{ "poke", 1.5 },
			{ "poke", "2" },
			{ "stopSpectate", 2 },
			{ "teleportTo", nil },
		}
		for _, args in bad do
			H.run(h, owner, args[1], args[2], args[3], args[4], args[5])
			expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.invalid" })
			h:tick(2)
		end
		H.run(h, owner, "teleportTo", 99)
		expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.not_found" })
		expect(record.calls).toEqual({})
	end)

	it("row actions take only a row id the server sent that staff member for that tab", function()
		local record = {}
		local h = H.boot({ serverAdmin = H.users({ [1] = "admin" }), register = registerAll(record) })
		local admin = H.join(h, 1)
		H.run(h, admin, "queue/close", nil, "r1")
		expect(H.last(h, admin)).toEqual({ ok = false, key = "Admin.result.invalid" }) -- not fetched yet
		h:action(admin, Admin, "fetch", "queue", 1)
		h:tick(2)
		H.run(h, admin, "queue/close", nil, "zzz")
		expect(H.last(h, admin)).toEqual({ ok = false, key = "Admin.result.invalid" })
		h:tick(2)
		H.run(h, admin, "queue/close", 5, "r1")
		expect(H.last(h, admin)).toEqual({ ok = false, key = "Admin.result.invalid" })
		h:tick(2)
		H.run(h, admin, "queue/close", nil, "r1")
		expect(H.last(h, admin)).toEqual({ ok = true, key = "Admin.result.done" })
		expect(record.closed).toBe("r1")
	end)

	it("fetch: pages, permission, rows cleaned and capped", function()
		local h = H.boot({
			serverAdmin = H.users({ [1] = "admin", [2] = "helper" }),
			register = function(ext)
				ext.registerTab({
					id = "audit",
					permission = "audit.read",
					labelKey = "Admin.tab.audit",
					fetch = function()
						local rows = {}
						for i = 1, 150 do
							rows[i] = { id = i, n = i, bad = { nested = true }, f = function() end }
						end
						return { columns = { "n" }, rows = rows }
					end,
				})
			end,
		})
		local admin, helper = H.join(h, 1), H.join(h, 2)
		h:action(admin, Admin, "fetch", "audit", 0)
		expect(H.last(h, admin)).toEqual({ ok = false, key = "Admin.result.invalid" })
		h:tick(2)
		h:action(helper, Admin, "fetch", "audit", 1)
		expect(H.last(h, helper)).toEqual({ ok = false, key = "Admin.result.no_permission" })
		h:action(admin, Admin, "fetch", "audit", 1)
		local sent = H.sentTo(h, admin, "Rows")
		local json = sent[#sent].args[3]
		local data = game:GetService("HttpService"):JSONDecode(json)
		expect(#data.rows).toBe(100)
		expect(data.rows[1]).toEqual({ id = "1", n = 1 })
		expect(sent[#sent].args[1]).toBe("audit")
	end)

	it("the Players tab lists this server's players, playerListMax per page", function()
		local h =
			H.boot({ serverAdmin = H.users({ [1] = "helper" }), admin = { panel = { playerListMax = 2 } } })
		local helper = H.join(h, 1)
		H.join(h, 2)
		H.join(h, 3)
		h:action(helper, Admin, "fetch", "players", 2)
		local sent = H.sentTo(h, helper, "Rows")
		local data = game:GetService("HttpService"):JSONDecode(sent[#sent].args[3])
		expect(#data.rows).toBe(1)
		expect(data.rows[1].userId).toBe(3)
		expect(data.rows[1].role).toBe(nil) -- roles aren't listed
	end)
end)

describe("per-staff rate limits through requests (design §11)", function()
	it("a built-in action counts once through allow: over actionsPerMinute it is rate_limited", function()
		local h = H.boot({
			serverAdmin = H.users({ [1] = "owner" }),
			admin = { limits = { actionsPerMinute = 3, bansPerHour = 20 } },
		})
		local owner = H.join(h, 1)
		for _ = 1, 3 do
			H.run(h, owner, "stopSpectate")
			expect(H.last(h, owner).ok).toBe(true)
			h:tick(2)
		end
		H.run(h, owner, "stopSpectate")
		expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.rate_limited" })
		expect(#h:sent("Admin", "Spectate")).toBe(3)
		h:tick(60)
		H.run(h, owner, "stopSpectate")
		expect(H.last(h, owner).ok).toBe(true)
	end)

	it("a registered action or row action checks the permission only; its module API counts", function()
		local record = {}
		local h = H.boot({
			serverAdmin = H.users({ [1] = "owner" }),
			admin = { limits = { actionsPerMinute = 2, bansPerHour = 20 } },
			register = registerAll(record),
		})
		local owner = H.join(h, 1)
		H.join(h, 2)
		for _ = 1, 4 do
			H.run(h, owner, "poke", 2, "Admin.panel.reason")
			expect(H.last(h, owner).ok).toBe(true)
			h:tick(2)
		end
		expect(#record.calls).toBe(4)
		-- nothing was counted: the staff member still has the whole minute's budget
		local a = h:use(Admin)
		expect({ a.allow(owner, "kick") }).toEqual({ true })
		expect({ a.allow(owner, "kick") }).toEqual({ true })
		expect({ a.allow(owner, "kick") }).toEqual({ false, "rate_limited" })
	end)

	it("a tab fetch counts once", function()
		local record = {}
		local h = H.boot({
			serverAdmin = H.users({ [1] = "owner" }),
			admin = { limits = { actionsPerMinute = 2, bansPerHour = 20 } },
			register = registerAll(record),
		})
		local owner = H.join(h, 1)
		h:action(owner, Admin, "fetch", "queue", 1)
		h:tick(2)
		h:action(owner, Admin, "fetch", "queue", 1)
		h:tick(2)
		h:action(owner, Admin, "fetch", "queue", 1)
		expect(record.fetched).toBe(2)
		expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.rate_limited" })
	end)

	it("a staff member without the permission gets no_permission", function()
		local record = {}
		local h = H.boot({ serverAdmin = H.users({ [1] = "helper" }), register = registerAll(record) })
		local helper = H.join(h, 1)
		H.run(h, helper, "announce", nil, "Admin.announce.event")
		expect(H.last(h, helper)).toEqual({ ok = false, key = "Admin.result.no_permission" })
		expect(#h:sent("Admin", "Announce")).toBe(0)
		H.join(h, 2)
		H.run(h, helper, "poke", 2, "Admin.panel.reason")
		expect(H.last(h, helper).ok).toBe(true) -- kick: a helper permission
	end)
end)

describe("row action choices (design §11)", function()
	it("presets and notes are offered, checked and passed to run", function()
		local got = {}
		local h = H.boot({
			serverAdmin = H.users({ [1] = "admin" }),
			register = function(ext)
				ext.registerTab({
					id = "reports",
					permission = "reports.read",
					labelKey = "Admin.tab.reports",
					fetch = function()
						return {
							columns = { "category" },
							rows = { { id = "77", category = "Admin.role.owner" } },
						}
					end,
					rowActions = {
						{
							id = "resolve",
							permission = "reports.resolve",
							labelKey = "Admin.panel.confirm",
							presets = { "Admin.value.yes", "Admin.value.no" },
							notes = { "Admin.panel.note" },
							run = function(_staff, rowId, args)
								table.insert(got, { rowId, args.preset, args.note })
								return true, "done"
							end,
						},
					},
				})
			end,
		})
		local admin = H.join(h, 1)
		local ra = h:state(admin).modules.Admin.extra.staff.tabs[1].rowActions[1]
		expect(ra.presets).toEqual({ "Admin.value.yes", "Admin.value.no" })
		expect(ra.notes).toEqual({ "Admin.panel.note" })
		h:action(admin, Admin, "fetch", "reports", 1)
		local bad = { nil, "free text", "Admin.value.yes|free", "Nope|Admin.panel.note", "a|b|c" }
		for i = 1, 5 do
			h:tick(2)
			H.run(h, admin, "reports/resolve", nil, "77", nil, bad[i])
			expect(H.last(h, admin)).toEqual({ ok = false, key = "Admin.result.invalid" })
		end
		h:tick(2)
		H.run(h, admin, "reports/resolve", nil, "77", nil, "Admin.value.no")
		h:tick(2)
		H.run(h, admin, "reports/resolve", nil, "77", nil, "Admin.value.yes|Admin.panel.note")
		expect(got).toEqual({
			{ "77", "Admin.value.no", nil },
			{ "77", "Admin.value.yes", "Admin.panel.note" },
		})
	end)

	it("a row action's presets / notes must be lists of keys", function()
		local ok = pcall(H.boot, {
			register = function(ext)
				ext.registerTab({
					id = "t",
					permission = "kick",
					labelKey = "k",
					fetch = function()
						return { rows = {}, columns = {} }
					end,
					rowActions = {
						{ id = "r", permission = "kick", labelKey = "k", presets = { "a|b" }, run = print },
					},
				})
			end,
		})
		expect(ok).toBe(false)
	end)
end)
