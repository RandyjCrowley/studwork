--!nocheck
--[[
	StoreBudget (module-api.md §23.5): the per-type ordered budget, this server's MemoryStore unit
	cap, the memory quota estimate and module shares, and the usage hand-off to the census.
]]
local Server = script.Parent.Parent.server
local StoreBudget = (require :: any)(Server.StoreBudget)

local function budget(config, players)
	local t = { now = 3600 * 1000, players = players or 0, reading = nil }
	t.b = StoreBudget.new({
		config = config,
		now = function()
			return t.now
		end,
		players = function()
			return t.players
		end,
	})
	t.b.attachCensus({
		get = function()
			return t.reading
		end,
	})
	return t
end

describe("StoreBudget: ordered request types", function()
	it("uses Roblox's per-server limits for the player count", function()
		local t = budget(nil, 3)
		expect(t.b.orderedLimit("list")).toBe(5 + 2 * 3)
		expect(t.b.orderedLimit("read")).toBe(60 + 40 * 3)
		expect(t.b.orderedLimit("write")).toBe(30 + 5 * 3)
		expect(t.b.orderedLimit("remove")).toBe(30 + 5 * 3)
	end)

	it("refuses at or below orderedReserve x limit, per type, and refills after a minute", function()
		local t = budget({ orderedReserve = 0.5 }, 0)
		local n = 0
		while t.b.allowOrdered("M", "remove") do
			n += 1
		end
		expect(n).toBe(15) -- 30 - 15 <= 15
		expect(t.b.allowOrdered("M", "get")).toBe(true) -- another type
		t.now += 61
		expect(t.b.allowOrdered("M", "remove")).toBe(true)
	end)

	it("an update needs both a read and a write", function()
		local t = budget({ orderedReserve = 0 }, 0)
		for _ = 1, 30 do
			assert(t.b.allowOrdered("M", "set"))
		end
		expect(t.b.allowOrdered("M", "update")).toBe(false) -- writes used up
		expect(t.b.allowOrdered("M", "get")).toBe(true)
	end)

	it("the platform's remaining budget counts when it is lower", function()
		local t = budget({ orderedReserve = 0.25 }, 0)
		expect(t.b.allowOrdered("M", "top", 1)).toBe(false) -- 1 <= 0.25 x 5
		expect(t.b.allowOrdered("M", "top", 2)).toBe(true)
		expect(pcall(t.b.allowOrdered, "M", "scan")).toBe(false)
	end)
end)

describe("StoreBudget: MemoryStore request units", function()
	it(
		"caps this server's modules at base + perPlayer x players a minute; the framework is never refused",
		function()
			local t = budget({ memoryUnits = { base = 4, perPlayer = 2 } }, 1)
			expect(t.b.chargeUnits("A", 3)).toBe(true)
			expect(t.b.chargeUnits("B", 3)).toBe(true)
			expect(t.b.chargeUnits("A", 1)).toBe(false)
			expect(t.b.chargeUnits(StoreBudget.FRAMEWORK, 50)).toBe(true)
			expect(t.b.unitsUsed()).toBe(6)
			expect(t.b.frameworkUnitsUsed()).toBe(50)
			t.b.recordUnits("A", 5) -- a range's rows, after the fact
			expect(t.b.unitsUsed()).toBe(11)
			t.now += 60
			expect(t.b.unitsUsed()).toBe(0)
		end
	)
end)

describe("StoreBudget: memory", function()
	it(
		"estimates the quota as 64 KB + 1.2 KB x peakPlayers (the census; before it, this server's players)",
		function()
			local t = budget(nil, 10)
			expect(t.b.quota()).toBe(65536 + 1228.8 * 10)
			t.reading = { servers = 4, players = 40, peakPlayers = 100, at = 0 }
			expect(t.b.quota()).toBe(65536 + 1228.8 * 100)
		end
	)

	it("refuses past share x quota per module and (1 - reserve) x quota together", function()
		local t = budget({ memory = { reserve = 0.5, defaultShare = 0.3, shares = { Big = 0.45 } } }, 0)
		local q = t.b.quota()
		local exp = t.now + 3600
		expect(t.b.chargeMemory("A", math.floor(0.3 * q), exp)).toBe(true)
		expect(t.b.chargeMemory("A", 10, exp)).toBe(false)
		expect(t.b.chargeMemory("Big", math.floor(0.25 * q), exp)).toBe(false) -- 0.3 + 0.25 > 0.5
		expect(t.b.chargeMemory("Big", math.floor(0.19 * q), exp)).toBe(true)
		expect(t.b.chargeMemory("A", 0, exp)).toBe(true) -- not growing: never refused
		t.b.releaseMemory("A", math.floor(0.3 * q), exp)
		expect(t.b.moduleBytes("A")).toBe(0)
		expect(t.b.chargeMemory("Big", math.floor(0.25 * q), exp)).toBe(true)
	end)

	it("buckets charges by the hour their items expire; a past hour no longer counts", function()
		local t = budget(nil, 0)
		t.b.chargeMemory("A", 100, t.now + 30)
		t.b.chargeMemory("A", 50, t.now + 7200)
		expect(t.b.moduleBytes("A")).toBe(150)
		t.now += 3600
		expect(t.b.moduleBytes("A")).toBe(50)
	end)

	it("hands unreported charges to the census and learns the experience totals back", function()
		local t = budget(nil, 0)
		local exp = t.now + 60
		local h = StoreBudget.hourKey(exp)
		t.b.chargeMemory("A", 100, exp)
		local usage = t.b.takeUsage()
		expect(usage).toEqual({ A = { [h] = 100 } })
		expect(t.b.moduleBytes("A")).toBe(100) -- still counted while the report is in flight
		expect(t.b.takeUsage()).toEqual({})
		t.b.restoreUsage("A", usage.A) -- the report failed
		expect(t.b.moduleBytes("A")).toBe(100)
		usage = t.b.takeUsage()
		t.b.setKnown("A", { [h] = 900 }, 5) -- the usage item's total (version 5), every server's charges
		expect(t.b.moduleBytes("A")).toBe(900)
		t.b.mergeKnown("A", { [h] = 1400 }, 4) -- an older version: ignored
		expect(t.b.moduleBytes("A")).toBe(900)
		t.b.mergeKnown("A", { [h] = 400 }, 6) -- newer, after a remove: replaces
		expect(t.b.moduleBytes("A")).toBe(400)
		t.b.mergeKnown("B", { [h] = 300 }, 1)
		expect(t.b.totalBytes()).toBe(700)
		expect(t.b.known()).toEqual({ A = { v = 6, h = { [h] = 400 } }, B = { v = 1, h = { [h] = 300 } } })
	end)
end)
