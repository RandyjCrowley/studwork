--!nocheck
--[[
	Structural sharing (core-v1.3.0 Phase 2 step 7, the benchmark fix): commits keep unchanged
	subtrees' identity (Freeze.share), read views are rebuilt only for replaced tables
	(Freeze.freezeShared), the replicated wire copy reuses the last copy of unchanged subtrees
	(Snapshot.copyShared), and framework writes to committed tables are copy-on-write so views
	never go stale.
]]
local Freeze = require(script.Parent.Parent.shared.Freeze)
local Snapshot = require(script.Parent.Parent.server.Replication.Snapshot)
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

describe("Freeze.share", function()
	it("returns the old table when nothing changed", function()
		local old = { a = { b = 1 }, c = 2 }
		local v, changed = Freeze.share(Freeze.deepCopy(old), old)
		expect(changed).toBe(false)
		expect(v == old).toBe(true)
	end)

	it("keeps unchanged subtrees and reports a changed leaf, an added and a removed key", function()
		local old = { big = { x = 1, y = 2 }, small = { n = 1 }, gone = 1 }
		local new = Freeze.deepCopy(old)
		new.small.n = 2
		local v, changed = Freeze.share(new, old)
		expect(changed).toBe(true)
		expect(v.big == old.big).toBe(true)
		expect(v.small.n).toBe(2)

		local removed = Freeze.deepCopy(old)
		removed.gone = nil
		local _, c2 = Freeze.share(removed, old)
		expect(c2).toBe(true)
		local added = Freeze.deepCopy(old)
		added.big.z = 3
		local v3, c3 = Freeze.share(added, old)
		expect(c3).toBe(true)
		expect(v3.big.z).toBe(3)
	end)

	it("never writes into a frozen table stored in the working copy", function()
		local old = { inner = { deep = { k = 1 } }, n = 1 }
		local frozen = Freeze.freezeCopy({ deep = { k = 1 }, m = 1 }) -- differs: m added
		local new = { inner = frozen, n = 2 }
		local v, changed = Freeze.share(new, old)
		expect(changed).toBe(true)
		expect(v.inner == frozen).toBe(true) -- kept, nothing written into it
		expect(table.isfrozen(v.inner.deep)).toBe(true)
	end)
end)

describe("Freeze.freezeShared", function()
	it("is a frozen deep copy that reuses the last view for every subtree that is the same table", function()
		local src = { a = { b = { c = 1 } }, d = 2, e = { f = 1 } }
		local v1 = Freeze.freezeCopy(src)
		local src2 = table.clone(src)
		src2.d = 3
		src2.e = { f = 2 }
		local v2 = Freeze.freezeShared(src2, src, v1)
		expect(table.isfrozen(v2) and table.isfrozen(v2.e)).toBe(true)
		expect(v2 == v1).toBe(false)
		expect(v2.a == v1.a).toBe(true)
		expect(v2.e.f).toBe(2)
		expect(v2.d).toBe(3)
		expect(v1.e.f).toBe(1)
		expect(Freeze.freezeShared(src, src, v1) == v1).toBe(true)
	end)
end)

describe("Snapshot.copyShared", function()
	it("matches Snapshot.copy and reuses the last copy of an unchanged frozen subtree", function()
		local view = Freeze.freezeCopy({ list = { 1, 2, 3 }, map = { [5] = "x", s = 0 / 0 }, f = print })
		local w1 = Snapshot.copy(view)
		expect(Snapshot.copyShared(view, nil, nil)).toEqual(w1)
		local view2 = table.freeze({ list = view.list, map = view.map, extra = 1 })
		local w2 = Snapshot.copyShared(view2, view, w1)
		expect(w2.list == w1.list).toBe(true)
		expect(w2.map == w1.map).toBe(true)
		expect(w2.extra).toBe(1)
		expect(w2).toEqual(Snapshot.copy(view2))
	end)
end)

describe("Data with structural sharing", function()
	it("a commit keeps untouched subtrees, and the new view shares them with the last view", function()
		local data, p = newData()
		data.runTx(p, function(tx)
			local s = data.section(tx, "bag")
			for i = 1, 50 do
				s.items["i" .. i] = { level = 1 }
			end
		end)
		local v1 = data.view(p, "bag")
		data.runTx(p, function(tx)
			data.section(tx, "bag").coins += 5
		end)
		local v2 = data.view(p, "bag")
		expect(v2 == v1).toBe(false)
		expect(v2.coins).toBe(5)
		expect(v2.items == v1.items).toBe(true)
		data.runTx(p, function(tx)
			data.section(tx, "bag").items.i7.level = 2
		end)
		local v3 = data.view(p, "bag")
		expect(v3.items.i7.level).toBe(2)
		expect(v3.items == v2.items).toBe(false)
		expect(v3.items.i8 == v2.items.i8).toBe(true)
		expect(v1.items.i7.level).toBe(1) -- an old view never changes
	end)

	it("a no-op commit keeps the section version and the view", function()
		local data, p = newData()
		local before = data.sectionVersion(p, "bag")
		local v1 = data.view(p, "bag")
		data.runTx(p, function(tx)
			data.section(tx, "bag").coins += 0
		end)
		expect(data.sectionVersion(p, "bag")).toBe(before)
		expect(data.view(p, "bag") == v1).toBe(true)
	end)

	it("framework writes before a save are copy-on-write: the _framework view stays correct", function()
		local data, p, store = newData()
		local v1 = data.view(p, "_framework")
		data.save(p)
		local v2 = data.view(p, "_framework")
		expect(v2 == v1).toBe(false) -- version moved and a new table was committed
		expect(v2.lastSeen).toBe(1700000000)
		expect(store.load(1).bag.coins).toBe(0)
	end)
end)
