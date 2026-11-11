local Escrow = require(script.Parent.Escrow)

describe("Escrow (R1 gift arbiter)", function()
	it("reserve caps the records per recipient and is idempotent per key", function()
		local e = Escrow.new(Escrow.memoryStore())
		expect(e.reserve(7, "a", 100, 2)).toBe("ok")
		expect(e.reserve(7, "a", 100, 2)).toBe("ok") -- retried flush: same slot
		expect(e.reserve(7, "b", 100, 2)).toBe("ok")
		expect(e.reserve(7, "c", 100, 2)).toBe("full")
		expect(e.reserve(8, "c", 100, 2)).toBe("ok") -- another recipient
	end)

	it("exactly one side wins a pending gift", function()
		local e = Escrow.new(Escrow.memoryStore())
		e.reserve(7, "a", 100, 5)
		e.reserve(7, "b", 100, 5)
		expect(e.take(7, "a")).toBe("mine")
		expect(e.reclaim(7, "a")).toBe("claimed")
		expect(e.reclaim(7, "b")).toBe("mine")
		expect(e.reclaim(7, "b")).toBe("mine") -- the sender's retry after a crash
		expect(e.take(7, "b")).toBe("returned")
		expect(e.take(7, "a")).toBe("mine") -- the recipient's redelivery after a crash
		expect(e.take(7, "zzz")).toBe("untracked")
	end)

	it("returned records still count until the recipient drops its copy; release frees them", function()
		local store = Escrow.memoryStore()
		local e = Escrow.new(store)
		e.reserve(7, "a", 100, 1)
		e.reclaim(7, "a")
		expect(e.reserve(7, "b", 100, 1)).toBe("full")
		expect(e.release(7, "a")).toBe(true)
		expect(store.values[Escrow.recordKey(7)]).toBeNil()
		expect(e.reserve(7, "b", 100, 1)).toBe("ok")
	end)

	it(
		"a stale claimed record (failed release) is pruned by a later reserve, a returned one never",
		function()
			local e = Escrow.new(Escrow.memoryStore())
			e.reserve(7, "old-claimed", 10, 2)
			e.take(7, "old-claimed")
			e.reserve(7, "old-returned", 10, 2)
			e.reclaim(7, "old-returned")
			expect(e.reserve(7, "new", 1000, 1, 500)).toBe("full") -- returned one stays
			e.release(7, "old-returned")
			expect(e.reserve(7, "new", 1000, 1, 500)).toBe("ok")
		end
	)

	it('store errors surface as "error" and change nothing', function()
		local store = Escrow.memoryStore(1) -- every update fails
		local e = Escrow.new(store)
		expect(e.reserve(7, "a", 100, 5)).toBe("error")
		expect(e.take(7, "a")).toBe("error")
		expect(e.reclaim(7, "a")).toBe("error")
		expect(e.release(7, "a")).toBe(false)
		expect((next(store.values))).toBeNil()
	end)
end)
