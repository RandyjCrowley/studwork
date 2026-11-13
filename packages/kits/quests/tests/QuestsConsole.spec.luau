--!nocheck
--[[
	Quests console (docs/framework/kits/quests.md, "Console"): `quests state` for Studio or admins;
	`quests progress`, `quests complete` (through the same path as server progress) and
	`quests timeshift` Studio only, refused anywhere else.
]]
local K = require("packages/kits/quests/tests/QuestsKit.luau")

describe("Quests console", function()
	it("refuses the Studio-only commands outside Studio and changes nothing", function()
		local h, p, q = K.boot({ isStudio = false })
		local uid = tostring(p.UserId)
		expect(h:console("quests", "progress", "tutorial", "1", uid)).toBe("quests progress is Studio-only")
		expect(h:console("quests", "complete", "once", uid)).toBe("quests complete is Studio-only")
		expect(h:console("quests", "timeshift", "86400")).toBe("quests timeshift is Studio-only")
		expect(q.state(p, "once").values).toEqual({ 0 })
		expect(q.active(p)[1].periodId).toBe(19675)
		-- the command bar has no calling player: state is allowed (admins and Studio)
		expect(string.find(h:console("quests", "state", uid), "quests for 1", 1, true) ~= nil).toBe(true)
	end)

	it("progresses, completes and shifts the clock in Studio", function()
		local h, p, q = K.boot({ isStudio = true })
		local uid = tostring(p.UserId)
		expect(h:console("quests", "progress", "coin", "2", uid)).toBe("progress coin: moved")
		expect(q.state(p, "d1").values).toEqual({ 2 })
		expect(h:console("quests", "complete", "s1", uid)).toBe("s1: filled")
		h:tick(1)
		expect(q.state(p, "s1").status).toBe("complete")
		expect(h:console("quests", "complete", "d2", uid)).toBe(
			"d2: not filled (not active, or already complete)"
		)
		expect(h:console("quests", "complete", "nope", uid)).toBe("unknown quest 'nope'")
		local reply = h:console("quests", "timeshift", "86400")
		expect(string.find(reply, "day 19676", 1, true) ~= nil).toBe(true)
		h:tick(1) -- the shifted clock crosses the boundary: rotation
		expect(q.active(p)[1].periodId).toBe(19676)
		local state = h:console("quests", "state", uid)
		expect(string.find(state, "s1 [chain] complete", 1, true) ~= nil).toBe(true)
	end)
end)
