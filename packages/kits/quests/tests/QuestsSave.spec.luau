--!nocheck
--[[
	Quests save data (docs/framework/kits/quests.md, "Save data"): an old save with a removed id, a
	changed kind and over-long lists loads without an error or a kick and is pruned in the load tx;
	`done` (the claim ledger) is never pruned; objective values follow the quest's current
	objective count; the section stays bounded after 60 simulated days of play.
]]
local HttpService = game:GetService("HttpService")
local K = require("packages/kits/quests/tests/QuestsKit.luau")
local F = K.F

local DAY_ID = 19675

local function oldSection()
	local waiting = {}
	for i = 1, 10 do
		table.insert(waiting, {
			q = if i % 2 == 0 then "d1" else "w1",
			k = if i % 2 == 0 then "daily" else "weekly",
			p = DAY_ID - 20 + i,
		})
	end
	table.insert(waiting, 1, { q = "gone", k = "daily", p = DAY_ID - 30 }) -- removed quest
	table.insert(waiting, 2, { q = "once", k = "daily", p = DAY_ID - 29 }) -- kind changed
	return {
		day = {
			id = DAY_ID - 3,
			slots = { { q = "d1", n = { 4, 4, 4 }, s = 1, r = 0 } },
			seen = { d1 = true, gone = false },
		},
		week = { id = -1, slots = {}, seen = {} },
		prog = {
			gone = { n = { 1 }, s = 0 },
			once = { n = { 0, 0, 0 }, s = 0 }, -- objective values cut to 1
			s1 = { n = {}, s = 0 }, -- padded to 1
			rep = { n = { 2 }, s = 0 }, -- was a oneTime (no period key): a changed kind
			d2 = { n = { 1 }, s = 0 }, -- a daily quest can't have a prog entry
		},
		done = { retiredLongAgo = 1600000000, s9 = 1650000000 },
		waiting = waiting,
		pins = { "d1", "gone", "w1", "once", "s1" },
		granted = { gift = true, once = true, gone = true },
	}
end

describe("Quests save data", function()
	it("loads an old save, prunes it in the load tx and never errors", function()
		local cfg = F.questsConfig({ waitingMax = 6, pinMax = 3 })
		local h, p = K.boot({ quests = cfg, data = K.saveWith(oldSection(), { quests = cfg }) })
		expect(p.loaded).toBe(true)
		expect(p.kicked).toBeFalsy()
		expect(h:warnings()).toEqual({})
		h:removePlayer(p)
		local s = K.section(h, p)
		expect(s.prog.gone).toBe(nil)
		expect(s.prog.rep).toBe(nil)
		expect(s.prog.d2).toBe(nil)
		expect(s.prog.once.n).toEqual({ 0 })
		expect(s.prog.s1.n).toEqual({ 0 })
		expect(s.done).toEqual({ retiredLongAgo = 1600000000, s9 = 1650000000 }) -- never pruned
		expect(s.granted).toEqual({ gift = true })
		-- waiting: removed and changed-kind entries dropped, the newest waitingMax kept; the
		-- complete d1 of the old day joined them at the deal (oldest dropped)
		expect(#s.waiting).toBe(6)
		expect(s.waiting[6]).toEqual({ q = "d1", k = "daily", p = DAY_ID - 3 })
		for _, w in s.waiting do
			expect(w.q == "d1" or w.q == "w1").toBe(true)
		end
		-- pins: unknown ids dropped, then pins of quests no longer active
		for _, id in s.pins do
			expect(id ~= "gone").toBe(true)
		end
		expect(#s.pins <= 3).toBe(true)
		expect(s.day.id).toBe(DAY_ID)
		expect(s.day.seen.gone).toBe(nil)
	end)

	it("a removed oneTime id re-added later can't be claimed again (done is the ledger)", function()
		local cfg = F.questsConfig()
		local section = oldSection()
		section.done = { once = 1650000000 }
		local _, p, q = K.boot({ quests = cfg, data = K.saveWith(section, { quests = cfg }) })
		expect(q.state(p, "once").status).toBe("claimed")
		q.progress(p, "tutorial")
		expect(select(2, q.claim(p, "once"))).toBe("claimed")
	end)

	it("stays bounded after 60 simulated days", function()
		local cfg = F.questsConfig({ waitingMax = 12 })
		local h, p, q = K.boot({ quests = cfg })
		h:console("events", "event", "testEvent")
		for day = 1, 60 do
			for _, key in { "coin", "crate", "shop", "jump", "day", "talk", "cat", "tutorial" } do
				q.progress(p, key, 50)
			end
			h:tick(1)
			if day % 3 == 0 then
				for _, v in q.active(p) do
					if v.status == "complete" then
						q.claim(p, v.id)
					end
				end
			end
			if day % 7 == 0 then
				q.reroll(p, "daily", 1)
				q.grant(p, "gift")
				q.pin(p, K.ids(q, p, "daily")[1], true)
			end
			h.clock += 86400
			h:tick(1)
		end
		h:removePlayer(p)
		local s = K.section(h, p)
		local size = #HttpService:JSONEncode(s)
		expect(size < 6000).toBe(true)
		expect(#s.waiting <= 12).toBe(true)
		expect(#s.day.slots <= 3).toBe(true)
		local n = 0
		for _ in s.prog do
			n += 1
		end
		expect(n <= 14).toBe(true)
		local seen = 0
		for _ in s.day.seen do
			seen += 1
		end
		expect(seen <= 4).toBe(true)
	end)
end)
