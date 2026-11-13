--!nocheck
--[[
	Quests rotation (docs/framework/kits/quests.md, "Periods, the deal and rerolls", "Failure
	behaviour: Reset while playing"): the tick after the boundary deals new sets to rotatePerTick
	players per tick, Rotated fires once per player and kind, claim/pin deal first, the boundary in
	utcOffsetHours, weekly sets on monday and sunday, pins of ended quests dropped at the deal.
]]
local K = require("packages/kits/quests/tests/QuestsKit.luau")
local F = K.F

local DAY = 86400
-- day 19675 (the harness's default start) is a Tuesday: monday weeks start on 19674, sunday weeks on 19673

local function cfg(extra)
	local c = {
		daily = { count = 2, rerollsPerSlot = 0 },
		weekly = { count = 1, rerollsPerSlot = 0 },
		quests = {
			d1 = F.quest("daily", { F.counter("coin", 2) }),
			d2 = F.quest("daily", { F.counter("gem", 1) }),
			w1 = F.quest("weekly", { F.counter("coin", 20) }),
		},
	}
	for k, v in extra or {} do
		c[k] = v
	end
	return c
end

local function rotations(q)
	local log = {}
	q.signals.Rotated:Connect(function(player, kind, periodId)
		table.insert(log, `{player.UserId}:{kind}:{periodId}`)
	end)
	return log
end

describe("Quests rotation", function()
	it("deals new sets to rotatePerTick players per tick after the boundary", function()
		local h = K.harness({ quests = cfg({ rotatePerTick = 2 }), startTime = 19676 * DAY - 5 })
		local q = h:use(K.Quests)
		local ps = {}
		for i = 1, 5 do
			ps[i] = h:addPlayer({ userId = i })
		end
		local log = rotations(q)
		h:tick(5) -- the clock reaches midnight on the last of these ticks
		expect(#log).toBe(2)
		h:tick(1)
		expect(#log).toBe(4)
		h:tick(1)
		expect(#log).toBe(5)
		h:tick(5)
		expect(#log).toBe(5) -- once per player
		for _, line in log do
			expect(string.find(line, ":daily:19676", 1, true) ~= nil).toBe(true)
		end
		for _, p in ps do
			expect(q.active(p)[1].periodId).toBe(19676)
		end
	end)

	it("claim deals first for a player not rotated yet; yesterday's complete quest is in waiting", function()
		local h, p, q = K.boot({ quests = cfg() })
		local log = rotations(q)
		q.progress(p, "coin", 2)
		h:tick(1)
		h.clock += DAY -- no tick: the rotation hasn't reached this player
		expect(q.claim(p, "d1")).toBe(true)
		expect(log).toEqual({ "1:daily:19676" })
		expect(q.state(p, "d1").status).toBe("active") -- today's d1
		expect(q.state(p, "d1").periodId).toBe(19676)
		expect(select(2, q.claim(p, "d1"))).toBe("not_complete")
	end)

	it("pin deals first and drops pins of quests that ended", function()
		local h, p, q = K.boot({ quests = cfg() })
		expect(q.pin(p, "d2", true)).toBe(true)
		expect(q.pin(p, "w1", true)).toBe(true)
		expect(q.active(p)[2].pinned).toBe(true)
		q.progress(p, "gem")
		h:tick(1)
		expect(q.claim(p, "d2")).toBe(true)
		h.clock += DAY
		h:tick(1)
		local pinned = {}
		for _, v in q.active(p) do
			if v.pinned then
				table.insert(pinned, v.id)
			end
		end
		table.sort(pinned)
		expect(pinned).toEqual({ "d2", "w1" }) -- today's d2 is dealt again; the pin follows the id
		h:removePlayer(p)
		expect(K.section(h, p).pins).toEqual({ "d2", "w1" })
	end)

	for _, case in { { offset = -5, at = 5 * 3600 }, { offset = 0, at = 0 }, { offset = 9, at = -9 * 3600 } } do
		it(`resets at local midnight with utcOffsetHours {case.offset}`, function()
			local reset = 19676 * DAY + case.at
			local h = K.harness({ quests = cfg({ utcOffsetHours = case.offset }), startTime = reset - 3 })
			local q = h:use(K.Quests)
			local p = h:addPlayer({ userId = 1 })
			local first = q.active(p)[1].periodId
			expect(first).toBe(19675)
			expect(q.active(p)[1].endsAt).toBe(reset)
			h:tick(2)
			expect(q.active(p)[1].periodId).toBe(19675)
			h:tick(2)
			expect(q.active(p)[1].periodId).toBe(19676)
		end)
	end

	it("deals weekly sets on monday or sunday weeks", function()
		for _, case in { { starts = "monday", boundary = 19681 }, { starts = "sunday", boundary = 19680 } } do
			local h = K.harness({ quests = cfg({ weekStartsOn = case.starts }), startTime = 19680 * DAY - 3 })
			local q = h:use(K.Quests)
			h:addPlayer({ userId = 1 })
			local log = rotations(q)
			h:tick(5)
			local weekly = {}
			for _, line in log do
				if string.find(line, "weekly", 1, true) then
					table.insert(weekly, line)
				end
			end
			if case.starts == "sunday" then
				expect(weekly).toEqual({ "1:weekly:" .. case.boundary })
			else
				expect(weekly).toEqual({})
				h.clock = 19681 * DAY - 2
				h:tick(3)
				local after = {}
				for _, line in log do
					if string.find(line, "weekly", 1, true) then
						table.insert(after, line)
					end
				end
				expect(after).toEqual({ "1:weekly:" .. case.boundary })
			end
		end
	end)

	it("deals nothing and writes nothing with no quests (an empty pool)", function()
		local h, p, q = K.boot({ quests = {} })
		local log = rotations(q)
		h.clock += 3 * DAY
		h:tick(2)
		expect(#q.active(p)).toBe(0)
		expect(#log).toBe(0)
		h:removePlayer(p)
		local s = K.section(h, p)
		expect(s.day.id).toBe(-1)
		expect(s.week.id).toBe(-1)
	end)
end)
