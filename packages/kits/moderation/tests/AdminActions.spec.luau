--!nocheck
--[[
	Admin built-in actions (design §3, B7, M18, M19): announce (preset, or free text through the
	registered "public" filter, refused without one), teleport-to / bring (onStaffMove first),
	spectate (to that staff only), shutdown (kicks everyone, refuses later joins), grant currency
	(optional Economy; 1..grant.max; listed currencies only; paid only when listed), data view
	(framework facts, data views typed per B7, Economy balance), the audit sink and its ctx.log
	fallback, the console commands.
]]
local H = require("packages/kits/moderation/tests/AdminHelpers.luau")
local Economy = H.Economy
local TextFilter = H.TextFilter
local HttpService = game:GetService("HttpService")

local function withFilter(extra)
	return function(ext, ctx)
		ext.registerTextFilter(function(author, text)
			local ok, r = ctx.deps[TextFilter].filter(author, text, "public")
			if ok then
				return true, r.public
			end
			return false, r
		end)
		if extra then
			extra(ext, ctx)
		end
	end
end

local function character(log, name)
	return {
		GetPivot = function()
			return name
		end,
		PivotTo = function(_self, where)
			table.insert(log, { who = name, to = where })
		end,
	}
end

describe("announce", function()
	it("a preset goes to everyone as k|<key> and is audited", function()
		local audits = {}
		local h = H.boot({
			serverAdmin = H.users({ [1] = "admin" }),
			register = function(ext)
				ext.registerAuditSink(function(entry)
					table.insert(audits, entry)
				end)
			end,
		})
		local admin = H.join(h, 1)
		H.join(h, 2)
		H.run(h, admin, "announce", nil, "Admin.announce.event")
		expect(H.last(h, admin)).toEqual({ ok = true, key = "Admin.result.done" })
		local sent = h:sent("Admin", "Announce")
		expect(#sent).toBe(1)
		expect(sent[1].all).toBe(true)
		expect(sent[1].args[1]).toBe("k|Admin.announce.event")
		expect(audits[1].action).toBe("announce")
		expect(audits[1].by).toBe(1)
		expect(audits[1].byKind).toBe("staff")
		expect(audits[1].reasonKey).toBe("Admin.announce.event")
		expect(audits[1].status).toBe("ok")
	end)

	it("free text without a registered filter is refused (no_filter); nothing is sent", function()
		local h = H.boot({ serverAdmin = H.users({ [1] = "admin" }) })
		local admin = H.join(h, 1)
		H.run(h, admin, "announce", nil, nil, nil, "hello everyone")
		expect(H.last(h, admin)).toEqual({ ok = false, key = "Admin.result.no_filter" })
		expect(#h:sent("Admin", "Announce")).toBe(0)
	end)

	it("free text goes through TextFilter public; only the broadcast string is sent", function()
		local h = H.boot({
			modules = { TextFilter },
			probeOptional = { TextFilter },
			serverAdmin = H.users({ [1] = "admin" }),
			register = withFilter(),
		})
		local admin = H.join(h, 1)
		H.run(h, admin, "announce", nil, nil, nil, "a badword here")
		expect(H.last(h, admin)).toEqual({ ok = true, key = "Admin.result.done" })
		local sent = h:sent("Admin", "Announce")
		expect(sent[1].args[1]).toBe("t|a ####### here")
		for _, e in h:sent("Admin") do
			for _, v in e.args do
				expect(v == "a badword here" or v == "t|a badword here").toBe(false)
			end
		end
	end)

	it("a filter failure refuses the text; over announce.maxLength or blank is invalid", function()
		local failing = H.boot({
			serverAdmin = H.users({ [1] = "admin" }),
			admin = { announce = { maxLength = 10 } },
			register = function(ext)
				ext.registerTextFilter(function()
					return false, "filter_failed"
				end)
			end,
		})
		local admin = H.join(failing, 1)
		H.run(failing, admin, "announce", nil, nil, nil, "short")
		expect(H.last(failing, admin)).toEqual({ ok = false, key = "Admin.result.failed" })
		failing:tick(2)
		H.run(failing, admin, "announce", nil, nil, nil, "much too long here")
		expect(H.last(failing, admin)).toEqual({ ok = false, key = "Admin.result.invalid" })
		failing:tick(2)
		H.run(failing, admin, "announce", nil, nil, nil, "   ")
		expect(H.last(failing, admin)).toEqual({ ok = false, key = "Admin.result.invalid" })
		expect(#failing:sent("Admin", "Announce")).toBe(0)
	end)

	it("announce.freeText = false: typed text is invalid, presets still work", function()
		local h =
			H.boot({ serverAdmin = H.users({ [1] = "admin" }), admin = { announce = { freeText = false } } })
		local admin = H.join(h, 1)
		H.run(h, admin, "announce", nil, nil, nil, "hello")
		expect(H.last(h, admin)).toEqual({ ok = false, key = "Admin.result.invalid" })
		h:tick(2)
		H.run(h, admin, "announce", nil, "Admin.announce.rules")
		expect(H.last(h, admin).ok).toBe(true)
	end)

	it("no preset and no text is invalid", function()
		local h = H.boot({ serverAdmin = H.users({ [1] = "admin" }) })
		local admin = H.join(h, 1)
		H.run(h, admin, "announce")
		expect(H.last(h, admin)).toEqual({ ok = false, key = "Admin.result.invalid" })
	end)
end)

describe("teleport-to, bring, spectate", function()
	it("onStaffMove runs before the move; to moves the staff, bring moves the target", function()
		local order = {}
		local h = H.boot({
			serverAdmin = H.users({ [1] = "moderator" }),
			register = function(ext)
				ext.onStaffMove(function(staff, target, kind)
					table.insert(order, { hook = kind, staff = staff.UserId, target = target.UserId })
				end)
			end,
		})
		local mod = H.join(h, 1)
		local target = H.join(h, 2)
		mod.Character = character(order, "staffPivot")
		target.Character = character(order, "targetPivot")
		H.run(h, mod, "teleportTo", 2)
		expect(H.last(h, mod)).toEqual({ ok = true, key = "Admin.result.done" })
		h:tick(2)
		H.run(h, mod, "bring", 2)
		expect(order).toEqual({
			{ hook = "to", staff = 1, target = 2 },
			{ who = "staffPivot", to = "targetPivot" },
			{ hook = "bring", staff = 1, target = 2 },
			{ who = "targetPivot", to = "staffPivot" },
		})
	end)

	it("no character: failed (and audited failed through ctx.log without a sink)", function()
		local h = H.boot({ serverAdmin = H.users({ [1] = "moderator" }) })
		local mod = H.join(h, 1)
		H.join(h, 2)
		H.run(h, mod, "teleportTo", 2)
		expect(H.last(h, mod)).toEqual({ ok = false, key = "Admin.result.failed" })
		local logged = false
		for _, l in h.logs do
			if string.find(l.msg, "audit teleport by staff:1 target 2 status failed", 1, true) then
				logged = true
			end
		end
		expect(logged).toBe(true)
	end)

	it("spectate sends the target id to that staff player only; stop sends nil", function()
		local h = H.boot({ serverAdmin = H.users({ [1] = "moderator" }) })
		local mod = H.join(h, 1)
		local other = H.join(h, 2)
		H.join(h, 3)
		H.run(h, mod, "spectate", 3)
		local sent = h:sent("Admin", "Spectate")
		expect(#sent).toBe(1)
		expect(sent[1].player).toBe(mod)
		expect(sent[1].args[1]).toBe(3)
		h:tick(2)
		H.run(h, mod, "stopSpectate")
		sent = h:sent("Admin", "Spectate")
		expect(#sent).toBe(2)
		expect(sent[2].args.n).toBe(1)
		expect(sent[2].args[1]).toBe(nil)
		expect(H.sentTo(h, other)).toEqual({})
	end)
end)

describe("shutdown", function()
	it("kicks everyone with the preset and refuses later joins; owner only", function()
		local audits = {}
		local h = H.boot({
			serverAdmin = H.users({ [1] = "owner", [2] = "admin" }),
			register = function(ext)
				ext.registerAuditSink(function(entry)
					table.insert(audits, entry)
				end)
			end,
		})
		local owner, admin, plain = H.join(h, 1), H.join(h, 2), H.join(h, 3)
		H.run(h, admin, "shutdown", nil, "Admin.shutdown.update")
		expect(H.last(h, admin)).toEqual({ ok = false, key = "Admin.result.no_permission" })
		expect(plain.kicked).toBe(nil)
		H.run(h, owner, "shutdown")
		expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.invalid" })
		h:tick(2)
		H.run(h, owner, "shutdown", nil, "Admin.shutdown.update")
		local msg = "This server is shutting down for an update. Please rejoin."
		expect(plain.kicked).toBe(msg)
		expect(admin.kicked).toBe(msg)
		expect(owner.kicked).toBe(msg)
		-- the admin's refusal (no permission), then the shutdown itself
		expect(#audits).toBe(2)
		expect(audits[1].status).toBe("refused")
		expect(audits[1].note).toBe("Admin.result.no_permission")
		expect(audits[2].action).toBe("shutdown")
		expect(audits[2].status).toBe("ok")
		expect(audits[2].reasonKey).toBe("Admin.shutdown.update")
		local late = H.join(h, 4)
		expect(late.kicked).toBe(msg)
	end)
end)

describe("grant currency (optional Economy)", function()
	local function bootGrant(opts)
		opts = opts or {}
		local audits = {}
		local h = H.boot({
			modules = { Economy },
			config = { Economy = opts.economy },
			compliance = opts.compliance,
			admin = opts.admin,
			serverAdmin = H.users({ [1] = "owner", [2] = "admin" }),
			register = function(ext)
				ext.registerAuditSink(function(entry)
					table.insert(audits, entry)
				end)
			end,
		})
		return h, audits
	end

	it("1..grant.max of a listed currency to a player in this server, audited", function()
		local h, audits = bootGrant({ admin = { grant = { max = 500 } } })
		local owner = H.join(h, 1)
		local target = H.join(h, 3)
		local eco = h:use(Economy)
		local bad = { { 0 }, { 501 }, { 2.5 }, { -1 }, { 0 / 0 } }
		for _, b in bad do
			H.run(h, owner, "grant", 3, "Coins", b[1])
			expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.invalid" })
			h:tick(2)
		end
		H.run(h, owner, "grant", 3, "Gems", 10)
		expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.invalid" })
		h:tick(2)
		H.run(h, owner, "grant", 3, nil, 10)
		expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.invalid" })
		h:tick(2)
		H.run(h, owner, "grant", 99, "Coins", 10)
		expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.not_found" })
		h:tick(2)
		expect(eco.balance(target)).toBe(0)
		H.run(h, owner, "grant", 3, "Coins", 500)
		expect(H.last(h, owner)).toEqual({ ok = true, key = "Admin.result.done" })
		expect(eco.balance(target)).toBe(500)
		expect(audits[#audits].action).toBe("grant")
		expect(audits[#audits].amount).toBe(500)
		expect(audits[#audits].currency).toBe("Coins")
		expect(audits[#audits].target).toBe(3)
		local action
		for _, a in h:state(owner).modules.Admin.extra.staff.actions do
			if a.id == "grant" then
				action = a
			end
		end
		expect(action.presets).toEqual({ "Coins" })
		expect(action.amount).toEqual({ min = 1, max = 500 })
	end)

	it("needs data.grant (admin hasn't it by default)", function()
		local h = bootGrant()
		local admin = H.join(h, 2)
		local target = H.join(h, 3)
		H.run(h, admin, "grant", 3, "Coins", 10)
		expect(H.last(h, admin)).toEqual({ ok = false, key = "Admin.result.no_permission" })
		expect(h:use(Economy).balance(target)).toBe(0)
	end)

	it("a paid currency is offered only when grant.currencies lists it", function()
		local paid = { paidCurrencies = { "Gems" } }
		local h = bootGrant({ economy = { primaryCurrency = "Gems" }, compliance = paid })
		local owner = H.join(h, 1)
		H.join(h, 3)
		for _, a in h:state(owner).modules.Admin.extra.staff.actions do
			expect(a.id).never.toBe("grant")
		end
		H.run(h, owner, "grant", 3, "Gems", 10)
		expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.invalid" })
		local h2 = bootGrant({
			economy = { primaryCurrency = "Gems" },
			compliance = paid,
			admin = { grant = { currencies = { "Gems" } } },
		})
		local owner2 = H.join(h2, 1)
		local t2 = H.join(h2, 3)
		H.run(h2, owner2, "grant", 3, "Gems", 10)
		expect(H.last(h2, owner2).ok).toBe(true)
		expect(h2:use(Economy).balance(t2, "Gems")).toBe(10)
	end)

	it("without Economy the action isn't offered or accepted", function()
		local h = H.boot({ serverAdmin = H.users({ [1] = "owner" }) })
		local owner = H.join(h, 1)
		H.join(h, 3)
		H.run(h, owner, "grant", 3, "Coins", 10)
		expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.invalid" })
	end)
end)

describe("data view", function()
	it("framework facts, registered views (number/boolean/declared key only), Economy balance", function()
		local h = H.boot({
			modules = { Economy },
			serverAdmin = H.users({ [1] = "admin" }),
			register = function(ext)
				ext.registerDataView("pets", function(target)
					return {
						count = target.UserId * 10,
						vip = true,
						tier = "Admin.role.helper", -- a declared key: kept
						nick = "player typed text", -- not a key: dropped
						nested = { x = 1 }, -- dropped
					}
				end)
				ext.registerDataView("broken", function()
					error("boom")
				end)
			end,
		})
		local admin = H.join(h, 1)
		local target = H.join(h, 3)
		h:use(Economy).grant(target, 42, "test")
		H.run(h, admin, "dataView", 3)
		expect(H.last(h, admin)).toEqual({ ok = true, key = "Admin.result.done" })
		local rows = H.sentTo(h, admin, "Rows")
		expect(rows[#rows].args[1]).toBe("data")
		local data = HttpService:JSONDecode(rows[#rows].args[3])
		expect(data.target).toBe(3)
		local seen = {}
		for _, r in data.rows do
			seen[r.section .. "/" .. r.label] = r.value
		end
		expect(type(seen["Admin.tab.data/Admin.data.firstJoin"])).toBe("number")
		expect(type(seen["Admin.tab.data/Admin.data.lastSeen"])).toBe("number")
		expect(seen["Admin.tab.data/Admin.data.sessions"]).toBe(1)
		expect(seen["pets/count"]).toBe(30)
		expect(seen["pets/vip"]).toBe(true)
		expect(seen["pets/tier"]).toBe("Admin.role.helper")
		expect(seen["pets/nick"]).toBe(nil)
		expect(seen["pets/nested"]).toBe(nil)
		expect(seen["Admin.data.balance/Coins"]).toBe(42)
	end)

	it("needs data.read; the moderator hasn't it", function()
		local h = H.boot({ serverAdmin = H.users({ [1] = "moderator" }) })
		local mod = H.join(h, 1)
		H.join(h, 3)
		H.run(h, mod, "dataView", 3)
		expect(H.last(h, mod)).toEqual({ ok = false, key = "Admin.result.no_permission" })
		expect(#H.sentTo(h, mod, "Rows")).toBe(0)
	end)
end)

describe("registered actions and the free-text path", function()
	it("an action with freeText gets the filtered string in args.text, never the raw text", function()
		local got = {}
		local h = H.boot({
			modules = { TextFilter },
			probeOptional = { TextFilter },
			serverAdmin = H.users({ [1] = "owner" }),
			register = withFilter(function(ext)
				ext.registerAction({
					id = "note",
					permission = "warn",
					labelKey = "Admin.panel.text",
					target = "none",
					freeText = true,
					run = function(_staff, _target, args)
						table.insert(got, args.text)
						return true, "Moderation.result.custom_key"
					end,
				})
			end),
		})
		local owner = H.join(h, 1)
		H.run(h, owner, "note", nil, nil, nil, "badword!")
		expect(got).toEqual({ "#######!" })
		expect(H.last(h, owner)).toEqual({ ok = true, key = "Moderation.result.custom_key" })
	end)

	it("an action that errors replies failed and logs", function()
		local h = H.boot({
			serverAdmin = H.users({ [1] = "owner" }),
			register = function(ext)
				ext.registerAction({
					id = "explode",
					permission = "warn",
					labelKey = "Admin.panel.text",
					target = "none",
					run = function()
						error("nope")
					end,
				})
			end,
		})
		local owner = H.join(h, 1)
		H.run(h, owner, "explode")
		expect(H.last(h, owner)).toEqual({ ok = false, key = "Admin.result.failed" })
	end)

	it("registerAction refuses a built-in id; registerTab refuses the panel's own tabs", function()
		for _, case in
			{
				function(ext)
					ext.registerAction(H.action("announce"))
				end,
				function(ext)
					ext.registerTab({
						id = "players",
						permission = "kick",
						labelKey = "k",
						fetch = function()
							return { rows = {}, columns = {} }
						end,
					})
				end,
				function(ext)
					ext.registerTextFilter(print)
					ext.registerTextFilter(print)
				end,
			}
		do
			local ok = pcall(H.boot, { register = case })
			expect(ok).toBe(false)
		end
	end)
end)

describe("console (server-only)", function()
	it("staff, role, announce, grant, tp, data, shutdown", function()
		local audits = {}
		local h = H.boot({
			modules = { Economy },
			serverAdmin = H.users({ [1] = "moderator", [50] = "owner" }),
			register = function(ext)
				ext.registerAuditSink(function(entry)
					table.insert(audits, entry)
				end)
			end,
		})
		local mod = H.join(h, 1)
		local p = H.join(h, 2)
		expect(h:console("admin", "staff")).toBe("1=moderator")
		expect(h:console("admin", "role", "1")).toBe("1: moderator (rank 200)")
		expect(h:console("admin", "role", "50")).toBe("50: rank 400")
		expect(h:console("admin", "announce", "Admin.announce.rules")).toBe("announced")
		expect(h:sent("Admin", "Announce")[1].args[1]).toBe("k|Admin.announce.rules")
		expect(h:console("admin", "announce", "free text")).toContain("usage")
		expect(h:console("admin", "grant", "20", "Coins", "2")).toBe("granted")
		expect(h:use(Economy).balance(p)).toBe(20)
		expect(h:console("admin", "grant", "20000", "Coins", "2")).toContain("usage")
		expect(audits[#audits].byKind).toBe("console")
		expect(audits[#audits].by).toBe(0)
		local log = {}
		mod.Character = character(log, "modPivot")
		p.Character = character(log, "pPivot")
		expect(h:console("admin", "tp", "2", "1")).toBe("moved")
		expect(log).toEqual({ { who = "pPivot", to = "modPivot" } })
		expect(h:console("admin", "data", "2")).toContain("Admin.data.balance/Coins=20")
		expect(h:console("admin", "shutdown", "Admin.shutdown.generic")).toBe("shutting down")
		expect(p.kicked).toBe("This server is shutting down. Please rejoin.")
	end)
end)

describe("refused built-in actions are audited (design §12)", function()
	it("one refused entry per staff and action per hour, only with a sink", function()
		local audits = {}
		local h = H.boot({
			serverAdmin = H.users({ [1] = "helper", [2] = "moderator" }),
			register = function(ext)
				ext.registerAuditSink(function(entry)
					table.insert(audits, entry)
				end)
			end,
		})
		local helper, mod = H.join(h, 1), H.join(h, 2)
		H.run(h, helper, "announce", nil, "Admin.announce.event")
		h:tick(2)
		H.run(h, helper, "announce", nil, "Admin.announce.event")
		h:tick(2)
		H.run(h, mod, "teleportTo", 1) -- allowed rank-wise; no character: failed, not refused
		h:tick(2)
		H.run(h, helper, "teleportTo", 2)
		expect(#audits).toBe(3)
		expect(audits[1]).toEqual({
			action = "announce",
			by = 1,
			byKind = "staff",
			note = "Admin.result.no_permission",
			status = "refused",
		})
		expect(audits[2].status).toBe("failed")
		expect(audits[3].action).toBe("teleport")
		expect(audits[3].status).toBe("refused")
		expect(audits[3].target).toBe(2)
		h:tick(3601)
		H.run(h, helper, "announce", nil, "Admin.announce.event")
		expect(#audits).toBe(4)
	end)

	it("without a sink nothing is logged as refused", function()
		local h = H.boot({ serverAdmin = H.users({ [1] = "helper" }) })
		local helper = H.join(h, 1)
		H.run(h, helper, "announce", nil, "Admin.announce.event")
		for _, l in h.logs do
			expect(string.find(l.msg, "status refused", 1, true)).toBe(nil)
		end
	end)
end)

describe("Studio (design §12)", function()
	it("the rank rule is skipped: two Studio owners can act on each other", function()
		local h = H.boot({ isStudio = true })
		local a, b = H.join(h, 1), H.join(h, 2)
		H.run(h, a, "spectate", 2)
		expect(H.last(h, a)).toEqual({ ok = true, key = "Admin.result.done" })
		H.run(h, b, "spectate", 1)
		expect(H.last(h, b)).toEqual({ ok = true, key = "Admin.result.done" })
	end)
end)
