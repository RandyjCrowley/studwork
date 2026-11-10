local ReadOnlyView = require(script.Parent.ReadOnlyView)

describe("Data.ReadOnlyView (N8)", function()
	local function versions(map)
		return function(section)
			return map[section] or 0
		end
	end

	it("returns a frozen deep copy: writes error, reads match", function()
		local data = { rebirths = 2, currency = { Coins = 5 }, game = { g = { list = { 1, 2 } } } }
		local view = ReadOnlyView.build(ReadOnlyView.new(), data, versions({}))
		expect(view.currency.Coins).toBe(5)
		expect(view.game.g.list[2]).toBe(2)
		expect(view.rebirths).toBe(2)
		expect(table.isfrozen(view)).toBe(true)
		expect(table.isfrozen(view.game.g.list)).toBe(true)
		expect(pcall(function()
			view.currency.Coins = 99
		end)).toBe(false)
		expect(pcall(function()
			view.game.g.x = 1
		end)).toBe(false)
		expect(data.currency.Coins).toBe(5) -- the live data is untouched
	end)

	it("reuses a section copy until its version moves", function()
		local cache = ReadOnlyView.new()
		local v = { currency = 1, inventory = 1 }
		local data = { currency = { Coins = 1 }, inventory = {} }
		local a = ReadOnlyView.build(cache, data, versions(v))
		data.currency = { Coins = 2 }
		v.currency = 2
		local b = ReadOnlyView.build(cache, data, versions(v))
		expect(b.inventory).toBe(a.inventory) -- unchanged section: same frozen copy
		expect(b.currency == a.currency).toBe(false)
		expect(b.currency.Coins).toBe(2)
	end)

	it("copies scalars every time and passes non-tables through", function()
		local cache = ReadOnlyView.new()
		local data = { lastSeen = 1 }
		expect(ReadOnlyView.build(cache, data, versions({})).lastSeen).toBe(1)
		data.lastSeen = 2
		expect(ReadOnlyView.build(cache, data, versions({})).lastSeen).toBe(2)
		expect(ReadOnlyView.build(cache, nil, versions({}))).toBe(nil)
	end)
end)
