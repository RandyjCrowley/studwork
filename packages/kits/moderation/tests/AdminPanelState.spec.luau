--!nocheck
--[[
	Admin panel view state (Admin/server/Panel/State.luau, pure): tabs from the replicated staff
	state, quick actions, pickers, the Run each choice turns into, row payloads, durations,
	announcement payloads.
]]
local H = require("packages/kits/moderation/tests/AdminHelpers.luau")
local State = H.State

local function staffState(extra)
	local s = {
		role = "moderator",
		rank = 200,
		permissions = { "ban", "kick", "teleport", "spectate" },
		actions = {
			{
				id = "teleportTo",
				labelKey = "Admin.action.teleportTo",
				target = "player",
				permission = "teleport",
			},
			{
				id = "stopSpectate",
				labelKey = "Admin.action.stopSpectate",
				target = "none",
				permission = "spectate",
			},
			{
				id = "ban",
				labelKey = "Moderation.action.ban",
				target = "userId",
				permission = "ban",
				presets = { "Moderation.ban.rules", "Moderation.ban.cheating" },
				durations = { 3600, 86400, -1 },
				freeText = true,
			},
		},
		tabs = {
			{ id = "reports", labelKey = "Admin.tab.reports", permission = "reports.read", rowActions = {} },
		},
		playerListMax = 50,
	}
	for k, v in extra or {} do
		s[k] = v
	end
	return s
end

local function ids(list)
	local out = {}
	for _, t in list do
		table.insert(out, t.id)
	end
	return out
end

describe("Admin panel state", function()
	it("tabs: Players, registered tabs, then Announce and Data when offered", function()
		expect(ids(State.tabs(staffState()))).toEqual({ "players", "reports" })
		local owner = staffState()
		table.insert(
			owner.actions,
			{ id = "announce", labelKey = "x", target = "none", permission = "announce" }
		)
		table.insert(
			owner.actions,
			{ id = "dataView", labelKey = "x", target = "player", permission = "data.read" }
		)
		expect(ids(State.tabs(owner))).toEqual({ "players", "reports", "announce", "data" })
		expect(State.tabs(nil)).toEqual({})
		expect(State.tabs(owner)[2].kind).toBe("rows")
	end)

	it("quick actions are the actions on a player", function()
		expect(ids(State.playerActions(staffState()))).toEqual({ "teleportTo", "ban" })
		expect(State.has(staffState(), "ban")).toBe(true)
		expect(State.has(staffState(), "shutdown")).toBe(false)
	end)

	it("durations as minutes, hours, days and permanent", function()
		expect({ State.durationLabel(600) }).toEqual({ "Admin.duration.minutes", { n = 10 } })
		expect({ State.durationLabel(7200) }).toEqual({ "Admin.duration.hours", { n = 2 } })
		expect({ State.durationLabel(3 * 86400) }).toEqual({ "Admin.duration.days", { n = 3 } })
		expect({ State.durationLabel(-1) }).toEqual({ "Admin.duration.permanent", {} })
		expect({ State.durationLabel(90) }).toEqual({ "Admin.duration.minutes", { n = 2 } })
	end)

	it("pickers cycle through their choices", function()
		local list = { "a", "b", "c" }
		expect(State.cycle(list, nil)).toBe("a")
		expect(State.cycle(list, "a")).toBe("b")
		expect(State.cycle(list, "c")).toBe("a")
		expect(State.cycle({}, nil)).toBe(nil)
	end)

	it("reduce never changes the old state; a tab change resets the page and the choice", function()
		local s0 = State.new(staffState())
		local s1 = State.reduce(s0, { type = "action", id = "ban" })
		local s2 = State.reduce(s1, { type = "preset", value = "Moderation.ban.rules" })
		expect(s0.actionId).toBe(nil)
		expect(s2.actionId).toBe("ban")
		expect(s2.preset).toBe("Moderation.ban.rules")
		local s3 =
			State.reduce(State.reduce(s2, { type = "page", delta = 1 }), { type = "tab", id = "reports" })
		expect(s3.page).toBe(1)
		expect(s3.actionId).toBe(nil)
		expect(s3.preset).toBe(nil)
		expect(State.reduce(s0, { type = "page", delta = -5 }).page).toBe(1)
		expect(State.reduce(s0, { type = "amount", value = "12.7" }).amount).toBe(12)
		expect(State.reduce(s0, { type = "amount", value = "x" }).amount).toBe(nil)
	end)

	it("request: what is missing first, then the exact Run", function()
		local staff = staffState()
		local s = State.new(staff)
		expect(select(2, State.request(s, staff))).toBe("Admin.panel.pickAction")
		s = State.reduce(s, { type = "action", id = "ban" })
		expect(select(2, State.request(s, staff))).toBe("Admin.panel.pickPlayer")
		s = State.reduce(s, { type = "select", userId = 42 })
		expect(select(2, State.request(s, staff))).toBe("Admin.panel.pickReason")
		s = State.reduce(s, { type = "preset", value = "Moderation.ban.rules" })
		expect(select(2, State.request(s, staff))).toBe("Admin.panel.pickDuration")
		s = State.reduce(s, { type = "duration", value = 86400 })
		expect(State.request(s, staff)).toEqual({
			actionId = "ban",
			targetUserId = 42,
			preset = "Moderation.ban.rules",
			duration = 86400,
		})
		-- typed text instead of a preset is fine for a freeText action
		local t =
			State.reduce(State.reduce(s, { type = "preset", value = nil }), { type = "text", value = "x" })
		expect(State.request(t, staff).text).toBe("x")
		-- a preset the action doesn't offer
		local bad = State.reduce(s, { type = "preset", value = "Nope" })
		expect(select(2, State.request(bad, staff))).toBe("Admin.panel.pickReason")
	end)

	it("an amount action sends the amount in duration, within its bounds", function()
		local staff = staffState({
			actions = {
				{
					id = "grant",
					labelKey = "Admin.action.grant",
					target = "player",
					permission = "data.grant",
					presets = { "Coins" },
					amount = { min = 1, max = 100 },
				},
			},
		})
		local s = State.reduce(State.new(staff), { type = "action", id = "grant" })
		s = State.reduce(s, { type = "select", userId = 3 })
		s = State.reduce(s, { type = "preset", value = "Coins" })
		expect(select(2, State.request(s, staff))).toBe("Admin.panel.pickAmount")
		expect(select(2, State.request(State.reduce(s, { type = "amount", value = "101" }), staff))).toBe(
			"Admin.panel.pickAmount"
		)
		local run = State.request(State.reduce(s, { type = "amount", value = "100" }), staff)
		expect(run).toEqual({ actionId = "grant", targetUserId = 3, preset = "Coins", duration = 100 })
	end)

	it("announce: a preset or typed text, not both; row requests carry the row id in preset", function()
		local staff = staffState({
			actions = {
				{
					id = "announce",
					labelKey = "Admin.action.announce",
					target = "none",
					permission = "announce",
					presets = { "Admin.announce.event" },
					freeText = true,
				},
			},
		})
		local s = State.reduce(State.new(staff), { type = "preset", value = "Admin.announce.event" })
		expect(State.announceRequest(s, staff)).toEqual({
			actionId = "announce",
			preset = "Admin.announce.event",
		})
		s = State.reduce(s, { type = "text", value = "hi" })
		expect(State.announceRequest(s, staff)).toEqual({ actionId = "announce", text = "hi" })
		expect(State.rowRequest("reports", "claim", "123")).toEqual({
			actionId = "reports/claim",
			preset = "123",
		})
	end)

	it("row actions: pick one on a row, then its preset and note; the Run carries them in text", function()
		local staff = staffState({
			tabs = {
				{
					id = "reports",
					labelKey = "Admin.tab.reports",
					permission = "reports.read",
					rowActions = {
						{ id = "claim", labelKey = "x", permission = "reports.read" },
						{
							id = "resolve",
							labelKey = "y",
							permission = "reports.resolve",
							presets = { "R.actioned", "R.dismissed" },
							notes = { "N.one" },
						},
					},
				},
			},
		})
		local s = State.new(staff)
		expect(select(2, State.rowRun(s, staff))).toBe("Admin.panel.pickAction")
		s = State.reduce(s, { type = "rowAction", tabId = "reports", id = "claim", rowId = "5" })
		expect(State.rowRun(s, staff)).toEqual({ actionId = "reports/claim", preset = "5" })
		s = State.reduce(s, { type = "rowAction", tabId = "reports", id = "resolve", rowId = "5" })
		expect(select(2, State.rowRun(s, staff))).toBe("Admin.panel.pickReason")
		s = State.reduce(s, { type = "preset", value = "R.dismissed" })
		expect(State.rowRun(s, staff)).toEqual({
			actionId = "reports/resolve",
			preset = "5",
			text = "R.dismissed",
		})
		s = State.reduce(s, { type = "note", value = "N.one" })
		expect(State.rowRun(s, staff).text).toBe("R.dismissed|N.one")
		expect(select(2, State.rowRun(State.reduce(s, { type = "note", value = "N.x" }), staff))).toBe(
			"Admin.panel.pickNote"
		)
		local cleared = State.reduce(s, { type = "rowAction" })
		expect(cleared.rowAction).toBe(nil)
		expect(cleared.preset).toBe(nil)
		expect(State.reduce(s, { type = "tab", id = "reports" }).rowAction).toBe(nil)
	end)

	it("rows: payload cleaned; cells shown as text", function()
		local data = State.decodeRows({
			columns = { "who", 5, "n" },
			rows = { { id = "1", who = "Admin.role.owner", n = 2.5, bad = {} }, "junk" },
			target = 9,
		})
		expect(data.columns).toEqual({ "who", "n" })
		expect(data.rows).toEqual({ { id = "1", who = "Admin.role.owner", n = 2.5 } })
		expect(data.target).toBe(9)
		local function resolve(k)
			return "<" .. k .. ">"
		end
		expect(State.cellText("Admin.role.owner", nil, resolve)).toBe("<Admin.role.owner>")
		expect(State.cellText(3, nil, resolve)).toBe("3")
		expect(State.cellText(2.5, nil, resolve)).toBe("2.50")
		expect(State.cellText(true, nil, resolve)).toBe("<Admin.value.yes>")
		expect(State.cellText(0, "time", resolve)).toBe("1970-01-01 00:00")
		expect(State.cellText(nil, nil, resolve)).toBe("")
		local s =
			State.reduce(State.new(nil), { type = "rows", tabId = "reports", page = 1, data = { rows = {} } })
		expect(s.rows.reports.page).toBe(1)
	end)

	it("announce payloads decode to a key or filtered text", function()
		expect({ State.decodeAnnounce("k|Admin.announce.event") }).toEqual({ "key", "Admin.announce.event" })
		expect({ State.decodeAnnounce("t|hello") }).toEqual({ "text", "hello" })
		expect({ State.decodeAnnounce("hello") }).toEqual({})
		expect({ State.decodeAnnounce("k|") }).toEqual({})
		expect(State.ANNOUNCE_KEY).toBe(H.AdminServer.ANNOUNCE_KEY)
		expect(State.ANNOUNCE_TEXT).toBe(H.AdminServer.ANNOUNCE_TEXT)
	end)
end)
