--!nocheck
--[[
	Leaderboards: the pure rules (server/Period.luau, server/Merge.luau).
]]
local Period = require("packages/kits/engagement/Leaderboards/server/Period.luau")
local Merge = require("packages/kits/engagement/Leaderboards/server/Merge.luau")

local DAY = 86400
local HOUR = 3600

describe("Period", function()
	it("daily: the local day index, start and end", function()
		local now = 19000 * DAY + 12 * HOUR
		local p = Period.of("daily", now, 0, "monday")
		expect(p.id).toBe("19000")
		expect(p.startsAt).toBe(19000 * DAY)
		expect(p.endsAt).toBe(19001 * DAY)
		expect(Period.of("daily", 19001 * DAY - 1, 0, "monday").id).toBe("19000")
		expect(Period.of("daily", 19001 * DAY, 0, "monday").id).toBe("19001")
	end)

	it("daily with an offset moves the boundary", function()
		-- UTC+5: local midnight is 19:00 UTC the day before
		local before = 19000 * DAY - 5 * HOUR - 1
		local after = 19000 * DAY - 5 * HOUR
		expect(Period.of("daily", before, 5, "monday").id).toBe("18999")
		expect(Period.of("daily", after, 5, "monday").id).toBe("19000")
		expect(Period.of("daily", after, 5, "monday").startsAt).toBe(after)
		-- UTC-8
		expect(Period.of("daily", 19000 * DAY + 8 * HOUR - 1, -8, "monday").id).toBe("18999")
		expect(Period.of("daily", 19000 * DAY + 8 * HOUR, -8, "monday").id).toBe("19000")
	end)

	it("weekly: Monday and Sunday starts", function()
		-- day 19000 is a Saturday: its Monday is 18995 and its Sunday 18994
		expect(Period.of("weekly", 19000 * DAY, 0, "monday").id).toBe("18995")
		expect(Period.of("weekly", 19000 * DAY, 0, "sunday").id).toBe("18994")
		expect(Period.of("weekly", 19000 * DAY, 0, "monday").endsAt).toBe(19002 * DAY)
		expect(Period.of("weekly", 19002 * DAY - 1, 0, "monday").id).toBe("18995")
		expect(Period.of("weekly", 19002 * DAY, 0, "monday").id).toBe("19002")
		-- the epoch week (1970-01-01 was a Thursday)
		expect(Period.of("weekly", 0, 0, "monday").id).toBe("-3")
		expect(Period.of("weekly", 4 * DAY, 0, "monday").id).toBe("4") -- Monday 1970-01-05
		expect(Period.of("weekly", 3 * DAY, 0, "sunday").id).toBe("3") -- Sunday 1970-01-04
	end)

	it("all-time has no period; previous and fromId agree with of", function()
		expect(Period.of("allTime", 5, 0, "monday")).toBe(nil)
		local now = 19000 * DAY
		for _, kind in { "daily", "weekly" } do
			local current = Period.of(kind, now, 2, "monday")
			local previous = Period.previous(kind, current, 2, "monday")
			expect(previous.endsAt).toBe(current.startsAt)
			expect(Period.fromId(kind, current.id, 2).endsAt).toBe(current.endsAt)
		end
		expect(Period.fromId("daily", "x", 0)).toBe(nil)
		expect(Period.fromId("allTime", "5", 0)).toBe(nil)
	end)

	it("expirySeconds: end + grace, at least 1 s, at most 45 days", function()
		expect(Period.expirySeconds(1000, 24, 400)).toBe(600 + 24 * HOUR)
		expect(Period.expirySeconds(1000, 0, 5000)).toBe(1)
		expect(Period.expirySeconds(1000, 24, 1000 - 100 * DAY)).toBe(3888000)
	end)
end)

describe("Merge", function()
	it("normalize floors finite numbers and refuses everything else", function()
		expect(Merge.normalize(3.9)).toBe(3)
		expect(Merge.normalize(-0.5)).toBe(-1)
		expect(Merge.normalize(0 / 0)).toBe(nil)
		expect(Merge.normalize(math.huge)).toBe(nil)
		expect(Merge.normalize("3")).toBe(nil)
		expect(Merge.normalize(nil)).toBe(nil)
	end)

	it("combine: max is the better by order, set the latest, sum adds", function()
		expect(Merge.combine("max", "desc", 5, 3)).toBe(5)
		expect(Merge.combine("max", "desc", 5, 8)).toBe(8)
		expect(Merge.combine("max", "asc", 5, 3)).toBe(3)
		expect(Merge.combine("max", "asc", nil, 3)).toBe(3)
		expect(Merge.combine("set", "desc", 5, 3)).toBe(3)
		expect(Merge.combine("sum", "desc", 5, 3)).toBe(8)
		expect(Merge.combine("sum", "desc", nil, 3)).toBe(3)
	end)

	it("stored never makes a stored value worse, except set", function()
		expect(Merge.stored("max", "desc", 10, 7)).toBe(10)
		expect(Merge.stored("max", "desc", 10, 12)).toBe(12)
		expect(Merge.stored("max", "asc", 10, 12)).toBe(10)
		expect(Merge.stored("sum", "desc", 10, 10)).toBe(10) -- a re-sent total
		expect(Merge.stored("sum", "desc", 12, 10)).toBe(12)
		expect(Merge.stored("sum", "desc", nil, 10)).toBe(10)
		expect(Merge.stored("set", "desc", 10, 3)).toBe(3)
	end)

	it("beatsCut compares with the last row by order", function()
		expect(Merge.beatsCut("desc", 6, 5)).toBe(true)
		expect(Merge.beatsCut("desc", 5, 5)).toBe(false)
		expect(Merge.beatsCut("asc", 4, 5)).toBe(true)
		expect(Merge.beatsCut("asc", 5, 5)).toBe(false)
	end)

	it("mergeRows: one row per user (the better), best first, ties by user id, cut to topN", function()
		local merged = Merge.mergeRows("desc", 3, {
			{ { u = 1, n = "a", v = 50 }, { u = 4, n = "d", v = 20 } },
			{ { u = 2, n = "b", v = 50 }, { u = 1, n = "a", v = 40 }, { u = 3, n = "c", v = 30 } },
		})
		local ids = {}
		for _, row in merged do
			table.insert(ids, `{row.u}={row.v}`)
		end
		expect(ids).toEqual({ "1=50", "2=50", "3=30" })
		local asc = Merge.mergeRows("asc", 2, { { { u = 1, n = "a", v = 9 }, { u = 2, n = "b", v = 3 } } })
		expect(asc[1].u).toBe(2)
		expect(#asc).toBe(2)
		expect(Merge.indexOf(merged, 3)).toBe(3)
		expect(Merge.indexOf(merged, 9)).toBe(nil)
	end)
end)
