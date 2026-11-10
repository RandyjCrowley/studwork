local SectionCache = require(script.Parent.SectionCache)

local function sample()
	return {
		schemaVersion = 3,
		rebirths = 1,
		currency = { Coins = 10 },
		stats = { totalEarned = 5 },
		inventory = { u1 = { uid = "u1", itemId = "a", level = 1 } },
		displayed = { slot1 = "u1" },
		purchases = { p1 = 100 },
		pity = { basic = 2 },
		funnel = { Joined = 1 },
		mail = { seen = {} },
	}
end

-- per-section versions as the contract says: only touched sections move
local function versions()
	local v: { [string]: number } = {}
	return v, function(section: string): number
		return v[section] or 0
	end
end

describe("Replication.SectionCache", function()
	it("never includes server-only sections", function()
		local cache = SectionCache.new()
		local _, versionOf = versions()
		local out = cache:build(sample(), versionOf)
		expect(out.purchases).toBeNil()
		expect(out.pity).toBeNil()
		expect(out.funnel).toBeNil()
		expect(out.mail).toBeNil()
		expect(out.currency.Coins).toBe(10)
		expect(out.rebirths).toBe(1)
	end)
	it("first build copies (no shared references with the source)", function()
		local cache = SectionCache.new()
		local data = sample()
		local _, versionOf = versions()
		local out = cache:build(data, versionOf)
		expect(out.inventory == data.inventory).toBe(false)
		expect(out.inventory.u1 == data.inventory.u1).toBe(false)
	end)
	it("unchanged sections keep identity, changed ones are fresh copies", function()
		local cache = SectionCache.new()
		local data = sample()
		local v, versionOf = versions()
		local first = cache:build(data, versionOf)
		-- Economy tick: currency + stats change (new tables, versions move)
		data.currency = { Coins = 20 }
		data.stats = { totalEarned = 15 }
		v.currency = 1
		v.stats = 1
		local second = cache:build(data, versionOf)
		expect(second == first).toBe(false)
		expect(second.inventory == first.inventory).toBe(true)
		expect(second.displayed == first.displayed).toBe(true)
		expect(second.currency == first.currency).toBe(false)
		expect(second.stats == first.stats).toBe(false)
		expect(second.currency.Coins).toBe(20)
		expect(first.currency.Coins).toBe(10) -- old copy untouched (charm-sync's last synced)
	end)
	it("re-copies a section whose version moved even when mutated in place", function()
		local cache = SectionCache.new()
		local data = sample()
		local v, versionOf = versions()
		local first = cache:build(data, versionOf)
		data.inventory.u1.level = 2
		v.inventory = 1
		local second = cache:build(data, versionOf)
		expect(second.inventory == first.inventory).toBe(false)
		expect(second.inventory.u1.level).toBe(2)
	end)
	it("re-copies when the source table reference changes (reload) with the same version", function()
		local cache = SectionCache.new()
		local data = sample()
		local _, versionOf = versions()
		local first = cache:build(data, versionOf)
		local reloaded = sample()
		reloaded.currency.Coins = 77
		local second = cache:build(reloaded, versionOf)
		expect(second.currency == first.currency).toBe(false)
		expect(second.currency.Coins).toBe(77)
	end)
	it("a stub that bumps every section copies everything (correct, no reuse)", function()
		local cache = SectionCache.new()
		local data = sample()
		local n = 0
		local function bumpAll(_s: string): number
			return n
		end
		local first = cache:build(data, bumpAll)
		n += 1
		local second = cache:build(data, bumpAll)
		expect(second.inventory == first.inventory).toBe(false)
		expect(cache.copies).toBe(8) -- 4 replicated table sections x 2 builds
	end)
	it("drops sections that disappeared and handles nil data", function()
		local cache = SectionCache.new()
		local data = sample()
		local _, versionOf = versions()
		cache:build(data, versionOf)
		data.displayed = nil :: any
		local out = cache:build(data, versionOf)
		expect(out.displayed).toBeNil()
		expect(cache.entries.displayed).toBeNil()
		expect(cache:build(nil, versionOf)).toBeNil()
	end)
	it("sanitises like Snapshot.copy (NaN -> 0)", function()
		local cache = SectionCache.new()
		local _, versionOf = versions()
		local out = cache:build({ currency = { Coins = 0 / 0 }, lastSeen = math.huge }, versionOf)
		expect(out.currency.Coins).toBe(0)
		expect(out.lastSeen).toBe(0)
	end)
end)
