--!nocheck
--[[
	Final review finding 3 (core-v1.3.0 Phase 2, P2-F): a reference kept from ctx.section(tx)
	(or any table reached through it) must not change committed data after the tx ends. Committed
	section tables are frozen (they also back the read views), so a late write raises an error and
	the save, the read view and the section version stay consistent.
]]
local Data = require(script.Parent.Parent.server.Data)
local Store = require(script.Parent.Parent.server.Store)

local function newData()
	local store = Store.memory()
	local data = Data.new({
		store = store,
		modules = {
			{ name = "Bag", data = { key = "bag", version = 1, default = { items = {}, coins = 0 } } },
		},
		gameId = "g",
		now = function()
			return 1700000000
		end,
		log = function() end,
	})
	local p = { UserId = 1, Name = "P1" }
	assert(data.load(p))
	return data, p, store
end

describe("writes after commit (final review 3)", function()
	it("a leaked working copy can't change the committed section", function()
		local data, p, store = newData()
		local leaked
		data.runTx(p, function(tx)
			leaked = data.section(tx, "bag")
			leaked.coins = 1
		end)
		local ver = data.sectionVersion(p, "bag")
		local wrote = pcall(function()
			leaked.coins = 999999
		end)
		local wroteNested = pcall(function()
			leaked.items.x = { level = 9 }
		end)
		expect(wrote).toBe(false)
		expect(wroteNested).toBe(false)
		expect(data.view(p, "bag").coins).toBe(1)
		expect(data.sectionVersion(p, "bag")).toBe(ver)
		data.save(p)
		expect(store.load(1).bag.coins).toBe(1)
		expect(store.load(1).bag.items.x).toBeNil()
	end)

	it("a leaked unchanged subtree (shared with committed data) can't change the save", function()
		local data, p, store = newData()
		data.runTx(p, function(tx)
			data.section(tx, "bag").items.a = { n = 1 }
		end)
		local leakedA
		data.runTx(p, function(tx)
			local s = data.section(tx, "bag")
			leakedA = s.items -- unchanged subtree: aliases the committed table after commit
			s.coins += 1
		end)
		local ok = pcall(function()
			leakedA.a.n = 1e9
		end)
		expect(ok).toBe(false)
		data.save(p)
		expect(store.load(1).bag.items.a.n).toBe(1)
		expect(data.view(p, "bag").items.a.n).toBe(1)
	end)

	it("a leaked reference from a tx that changed nothing can't reach committed data", function()
		local data, p, store = newData()
		local leaked
		data.runTx(p, function(tx)
			leaked = data.section(tx, "bag").items -- first tx after load, nothing changed
		end)
		pcall(function()
			leaked.y = 5
		end)
		data.save(p)
		expect(store.load(1).bag.items.y).toBeNil()
	end)

	it("later transactions still write normally", function()
		local data, p, store = newData()
		data.runTx(p, function(tx)
			data.section(tx, "bag").items.a = { n = 1 }
		end)
		data.runTx(p, function(tx)
			local s = data.section(tx, "bag")
			s.items.a.n += 1
			s.items.b = { n = 5 }
		end)
		data.save(p)
		expect(store.load(1).bag.items.a.n).toBe(2)
		expect(store.load(1).bag.items.b.n).toBe(5)
	end)
end)
