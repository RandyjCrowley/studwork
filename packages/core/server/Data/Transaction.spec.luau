local Transaction = require(script.Parent.Transaction)

local function root(): any
	return {
		currency = { coins = 10 },
		stats = { sessions = 1 },
		inventory = { u1 = { uid = "u1", itemId = "a", acquiredAt = 1, meta = { x = 1 } } },
		multipliers = {},
		displayed = {},
		rebirths = 0,
		lastSeen = 5,
	}
end

describe("Data.Transaction.run", function()
	it("commits writes and keeps the root identity", function()
		local s, r = Transaction.newState(), root()
		local before = r
		Transaction.run(s, r, function(d)
			d.currency.coins += 5
			d.rebirths = 2
		end)
		expect(r).toBe(before)
		expect(r.currency.coins).toBe(15)
		expect(r.rebirths).toBe(2)
	end)

	it("error -> nothing changed, error re-raised with traceback", function()
		local s, r = Transaction.newState(), root()
		local currency, inv = r.currency, r.inventory
		local ok, err = pcall(Transaction.run, s, r, function(d)
			d.currency.coins = 999
			d.inventory.u1.meta.x = 2
			d.rebirths = 9
			d.newKey = true
			error("boom")
		end)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("boom")
		expect(tostring(err)).toContain("traceback")
		expect(r.currency).toBe(currency)
		expect(r.currency.coins).toBe(10)
		expect(r.inventory).toBe(inv)
		expect(r.inventory.u1.meta.x).toBe(1)
		expect(r.rebirths).toBe(0)
		expect(r.newKey).toBeNil()
		expect(Transaction.version(s, "currency")).toBe(0)
		expect(s.running).toBe(false)
	end)

	it("table errors are re-raised as-is (sentinels survive)", function()
		local s, r = Transaction.newState(), root()
		local sentinel = { tag = true }
		local ok, err = pcall(Transaction.run, s, r, function()
			error(sentinel)
		end)
		expect(ok).toBe(false)
		expect(err).toBe(sentinel)
	end)

	it("yield -> nothing changed and errors", function()
		local s, r = Transaction.newState(), root()
		local ok, err = pcall(Transaction.run, s, r, function(d)
			d.currency.coins = 999
			coroutine.yield()
		end)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("must not yield")
		expect(r.currency.coins).toBe(10)
		expect(s.running).toBe(false)
		-- the state is usable again afterwards
		Transaction.run(s, r, function(d)
			d.currency.coins = 11
		end)
		expect(r.currency.coins).toBe(11)
	end)

	it("nested run on the same state errors with 'nested Data.update', outer discarded", function()
		local s, r = Transaction.newState(), root()
		local innerErr: any = nil
		local ok, err = pcall(Transaction.run, s, r, function(d)
			d.currency.coins = 1
			local iok, ierr = pcall(Transaction.run, s, r, function(d2)
				d2.rebirths = 5
			end)
			expect(iok).toBe(false)
			innerErr = ierr
			error(ierr)
		end)
		expect(ok).toBe(false)
		expect(tostring(innerErr)).toContain("nested Data.update")
		expect(tostring(err)).toContain("nested Data.update")
		expect(r.currency.coins).toBe(10)
		expect(r.rebirths).toBe(0)
		-- a different player's state is independent
		local s2, r2 = Transaction.newState(), root()
		Transaction.run(s, r, function()
			Transaction.run(s2, r2, function(d)
				d.rebirths = 3
			end)
		end)
		expect(r2.rebirths).toBe(3)
	end)

	it("only touched sections change identity; reads alone keep it", function()
		local s, r = Transaction.newState(), root()
		local stats, inv, mult = r.stats, r.inventory, r.multipliers
		Transaction.run(s, r, function(d)
			d.currency.coins += 1
			local _ = d.inventory.u1.itemId -- read only
		end)
		expect(r.stats).toBe(stats)
		expect(r.inventory).toBe(inv)
		expect(r.multipliers).toBe(mult)
	end)

	it("versions move only for changed sections and always increase", function()
		local s, r = Transaction.newState(), root()
		Transaction.run(s, r, function(d)
			d.currency.coins += 1
			d.stats.totalEarned = 1
			local _ = d.inventory
		end)
		local c1 = Transaction.version(s, "currency")
		expect(c1).toBeGreaterThan(0)
		expect(Transaction.version(s, "stats")).toBeGreaterThan(0)
		expect(Transaction.version(s, "inventory")).toBe(0)
		expect(Transaction.version(s, "multipliers")).toBe(0)
		Transaction.run(s, r, function(d)
			d.currency.coins += 1
		end)
		expect(Transaction.version(s, "currency")).toBeGreaterThan(c1)
		-- no-op write (same value) does not bump
		local c2 = Transaction.version(s, "currency")
		Transaction.run(s, r, function(d)
			d.rebirths = 0
			d.currency.coins = d.currency.coins
		end)
		expect(Transaction.version(s, "currency")).toBe(c2)
		expect(Transaction.version(s, "rebirths")).toBe(0)
	end)

	it("generalized iteration over the proxy sees root and new keys, not deleted ones", function()
		local s, r = Transaction.newState(), root()
		local seen = {}
		Transaction.run(s, r, function(d)
			d.extra = 1
			d.lastSeen = nil
			for k, v in d do
				seen[k] = v
			end
		end)
		expect(seen.currency).toBeTruthy()
		expect(seen.extra).toBe(1)
		expect(seen.lastSeen).toBeNil()
		expect(seen.rebirths).toBe(0)
		expect(r.lastSeen).toBeNil()
		expect(r.extra).toBe(1)
	end)

	it("Rebirth-style whole-section replacement works", function()
		local s, r = Transaction.newState(), root()
		Transaction.run(s, r, function(d)
			d.inventory = {}
			d.currency = { coins = 0 }
		end)
		local firstKey = next(r.inventory)
		expect(firstKey).toBeNil()
		expect(r.currency.coins).toBe(0)
		expect(Transaction.version(s, "inventory")).toBeGreaterThan(0)
	end)

	it("writes to nested tables are committed", function()
		local s, r = Transaction.newState(), root()
		Transaction.run(s, r, function(d)
			d.inventory.u1.meta.x = 42
			d.inventory.u2 = { uid = "u2", itemId = "b", acquiredAt = 2 }
		end)
		expect(r.inventory.u1.meta.x).toBe(42)
		expect(r.inventory.u2.itemId).toBe("b")
	end)

	it("reads inside fn see fn's own earlier writes", function()
		local s, r = Transaction.newState(), root()
		Transaction.run(s, r, function(d)
			d.currency.coins = 3
			expect(d.currency.coins).toBe(3)
			d.purchases = d.purchases or {}
			d.purchases.p1 = 1
			expect(d.purchases.p1).toBe(1)
		end)
		expect(r.purchases.p1).toBe(1)
	end)

	it("bump/bumpAll move versions for Data's own writes", function()
		local s, r = Transaction.newState(), root()
		Transaction.bump(s, "lastSeen")
		expect(Transaction.version(s, "lastSeen")).toBeGreaterThan(0)
		Transaction.bumpAll(s, r)
		expect(Transaction.version(s, "inventory")).toBeGreaterThan(0)
	end)
end)
