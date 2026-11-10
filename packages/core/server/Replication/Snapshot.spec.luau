local Snapshot = require(script.Parent.Snapshot)

describe("Replication.Snapshot.copy", function()
	it("deep copies so in-place mutation of the source does not affect the copy", function()
		local src = { currency = { Coins = 5 }, inventory = { u1 = { itemId = "a", level = 1 } } }
		local copy = Snapshot.copy(src)
		src.currency.Coins = 99
		src.inventory.u1.level = 7
		expect(copy.currency.Coins).toBe(5)
		expect(copy.inventory.u1.level).toBe(1)
		expect(copy.currency == src.currency).toBe(false)
	end)
	it("replaces NaN and infinities with 0", function()
		local copy = Snapshot.copy({ a = 0 / 0, b = math.huge, c = -math.huge, d = 3 })
		expect(copy.a).toBe(0)
		expect(copy.b).toBe(0)
		expect(copy.c).toBe(0)
		expect(copy.d).toBe(3)
	end)
	it("keeps dense arrays as arrays", function()
		local copy = Snapshot.copy({ list = { "x", "y", "z" } })
		expect(#copy.list).toBe(3)
		expect(copy.list[2]).toBe("y")
	end)
	it("stringifies numeric keys of sparse and mixed tables", function()
		local copy = Snapshot.copy({ sparse = { [1] = "a", [5] = "b" }, mixed = { "a", k = "v" } })
		expect(copy.sparse["1"]).toBe("a")
		expect(copy.sparse["5"]).toBe("b")
		expect(copy.sparse[1]).toBeNil()
		expect(copy.mixed["1"]).toBe("a")
		expect(copy.mixed.k).toBe("v")
	end)
	it("drops functions and non-string/number keys", function()
		local copy = Snapshot.copy({ f = function() end, [true :: any] = 1, ok = true })
		expect(copy.f).toBeNil()
		expect(copy.ok).toBe(true)
		local n = 0
		for _ in copy do
			n += 1
		end
		expect(n).toBe(1)
	end)
	it("survives cycles via the depth cap", function()
		local t: any = { name = "loop" }
		t.self = t
		local copy = Snapshot.copy(t)
		expect(copy.name).toBe("loop")
		expect(copy.self.name).toBe("loop")
	end)
end)

describe("Replication.Snapshot.build", function()
	it("defaults when nothing is known", function()
		local s = Snapshot.build(nil, nil, nil)
		expect(s.loaded).toBe(false)
		expect(s.data).toBeNil()
		expect(s.ratePerSec).toBe(0)
		expect(s.multiplier).toBe(1)
		expect(s.paidRandomRestricted).toBe(true)
		expect((next(s.activeEvents))).toBeNil()
		expect(s.plotName).toBeNil()
	end)
	it("is loaded with a copied data table and extra keys", function()
		local data = { currency = { Coins = 1 } }
		local s = Snapshot.build(
			data,
			{ ratePerSec = 4, multiplier = 2, paidRandomRestricted = false, plotName = "Plot3" },
			{ activeEvents = { rain = 100 } }
		)
		expect(s.loaded).toBe(true)
		expect(s.data == data).toBe(false)
		expect(s.data.currency.Coins).toBe(1)
		expect(s.ratePerSec).toBe(4)
		expect(s.multiplier).toBe(2)
		expect(s.paidRandomRestricted).toBe(false)
		expect(s.plotName).toBe("Plot3")
		expect(s.activeEvents.rain).toBe(100)
	end)
	it("rejects wrong types and non-finite numbers", function()
		local s = Snapshot.build(
			nil,
			{ ratePerSec = 0 / 0, multiplier = "x", paidRandomRestricted = 1, plotName = 5 },
			nil
		)
		expect(s.ratePerSec).toBe(0)
		expect(s.multiplier).toBe(1)
		expect(s.paidRandomRestricted).toBe(true)
		expect(s.plotName).toBeNil()
	end)
	it("per-player values win over shared ones", function()
		local s = Snapshot.build(nil, { multiplier = 3 }, { multiplier = 2, ratePerSec = 9 })
		expect(s.multiplier).toBe(3)
		expect(s.ratePerSec).toBe(9)
	end)
	it("builds a new table every call (charm-sync diffs by reference)", function()
		local data = { a = 1 }
		expect(Snapshot.build(data) == Snapshot.build(data)).toBe(false)
	end)
end)
