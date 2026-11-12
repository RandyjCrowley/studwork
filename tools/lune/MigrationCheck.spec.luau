--!nocheck
-- tools/lune/MigrationCheck (v1.6.0, adopting.md §3 "tools/test-migration"): the pure checks, and
-- tools/test-migration end to end on the example game in tools/lune/testdata/migration (a passing
-- fixture, and a fixture that loses a field: exit 1 naming it).
local MigrationCheck = require("tools/lune/MigrationCheck.luau")

local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local process = luneRequire("@lune/process")

local FIXTURE = {
	old = {
		coins = 75,
		inventory = { "pebble", "gem" },
		settings = { music = false, volume = 3 },
		lastLogin = 5,
		empty = {},
	},
	expect = {
		coins = "economy.currency.Coins",
		inventory = { items = "inventory.inventory" },
		settings = "game.settings",
		empty = "game.empty",
	},
	dropped = { lastLogin = "the framework keeps lastSeen" },
}

local SAVED = {
	economy = { currency = { Coins = 75 } },
	inventory = { inventory = { u1 = { itemId = "gem" }, u2 = { itemId = "pebble" } } },
	game = { settings = { music = false, volume = 3 }, empty = {} },
	_framework = { imports = { v1 = { found = true } } },
}

describe("MigrationCheck: fixture schema", function()
	it("valid fixture: no errors", function()
		expect(MigrationCheck.validate(FIXTURE)).toEqual({})
	end)
	it("names each problem", function()
		local errs = MigrationCheck.validate({
			expect = { a = 5 },
			dropped = { b = "" },
			sold = { c = "" }, -- (v1.6.0 r2: any non-empty kind is valid; an empty one is not)
			afterMerge = {},
			overCap = { path = "x" },
		})
		local text = table.concat(errs, "\n")
		expect(text).toContain("`old`")
		expect(text).toContain('expect["a"]')
		expect(text).toContain('dropped["b"] needs a reason')
		expect(text).toContain('sold["c"]')
		expect(text).toContain("`afterMerge`")
		expect(text).toContain("`overCap`")
	end)
end)

describe("MigrationCheck: check 1 (nothing lost)", function()
	it("leaves: every leaf, empty tables included, sorted", function()
		local paths = {}
		for _, l in MigrationCheck.leaves(FIXTURE.old) do
			table.insert(paths, l.path)
		end
		expect(paths).toEqual({
			"coins",
			"empty",
			"inventory.1",
			"inventory.2",
			"lastLogin",
			"settings.music",
			"settings.volume",
		})
	end)
	it("a complete mapping passes", function()
		expect(MigrationCheck.compare(FIXTURE.old, SAVED, FIXTURE)).toEqual({})
	end)
	it("an unmapped field fails, by name", function()
		local f = table.clone(FIXTURE)
		f.dropped = {}
		local errs = MigrationCheck.compare(FIXTURE.old, SAVED, f)
		expect(#errs).toBe(1)
		expect(errs[1]).toContain("old field 'lastLogin'")
	end)
	it("a wrong value, a missing item and a missing save fail with the field", function()
		local saved = MigrationCheck.deepCopy(SAVED)
		saved.economy.currency.Coins = 70
		saved.inventory.inventory.u1 = nil
		local errs = table.concat(MigrationCheck.compare(FIXTURE.old, saved, FIXTURE), "\n")
		expect(errs).toContain("'coins' -> 'economy.currency.Coins': old 75, StudWork 70")
		expect(errs).toContain("'inventory' -> 'inventory.inventory': items differ")
		expect(table.concat(MigrationCheck.compare(FIXTURE.old, nil, FIXTURE), "\n")).toContain(
			"no StudWork save"
		)
	end)
	it("get: dotted paths with list indexes", function()
		expect(MigrationCheck.get(FIXTURE.old, "inventory.2")).toBe("gem")
		expect(MigrationCheck.get(FIXTURE.old, "settings.music")).toBe(false)
		expect(MigrationCheck.get(FIXTURE.old, "nope.x")).toBeNil()
	end)
end)

describe("MigrationCheck: checks 2-7 helpers", function()
	it("stable/diff: a rejoin may move lastSeen, not sections or markers", function()
		local a = MigrationCheck.deepCopy(SAVED)
		local b = MigrationCheck.deepCopy(SAVED)
		a._framework.lastSeen = 1
		b._framework.lastSeen = 2
		expect(MigrationCheck.diff(MigrationCheck.stable(a), MigrationCheck.stable(b))).toEqual({})
		b.economy.currency.Coins = 150
		expect(MigrationCheck.diff(MigrationCheck.stable(a), MigrationCheck.stable(b))).toEqual({
			"economy.currency.Coins: 75 -> 150",
		})
	end)
	it("withoutField / inflate", function()
		expect(MigrationCheck.withoutField(FIXTURE.old, "coins").coins).toBeNil()
		expect(FIXTURE.old.coins).toBe(75)
		local big = MigrationCheck.inflate(FIXTURE.old, "inventory", 5)
		expect(big.inventory).toEqual({ "pebble", "gem", "pebble", "gem", "pebble" })
		local _, err = MigrationCheck.inflate(FIXTURE.old, "coins", 5)
		expect(err).toContain("not a non-empty list")
	end)
	it("afterMerge expectations", function()
		expect(MigrationCheck.afterMerge(SAVED, { afterMerge = { ["economy.currency.Coins"] = 75 } })).toEqual({})
		expect(MigrationCheck.afterMerge(SAVED, { afterMerge = { ["economy.currency.Coins"] = 80 } })[1]).toContain(
			"expected 80, got 75"
		)
	end)
	it("check 7: a sold currency must be paid; sold items need itemTag paid", function()
		local f =
			{ expect = { coins = "economy.currency.Coins" }, sold = { coins = "currency", pets = "items" } }
		expect(MigrationCheck.checkSold(f, { "Coins" }, "paid")).toEqual({})
		local errs = table.concat(MigrationCheck.checkSold(f, {}, "free"), "\n")
		expect(errs).toContain("currency 'Coins', which is not in GameConfig.compliance.paidCurrencies")
		expect(errs).toContain('itemTag is "free"')
	end)
	it("seedOps: each source kind's stored format", function()
		local ds = MigrationCheck.seedOps(
			{ kind = "datastore", name = "D", key = "P_{userId}" },
			7,
			{ a = 1 },
			100
		)
		expect(ds).toEqual({ { op = "set", name = "D", key = "P_7", value = { a = 1 }, at = 100 } })
		local ps = MigrationCheck.seedOps(
			{ kind = "profileservice", name = "P", key = "{userId}" },
			7,
			{ a = 1 },
			100
		)
		expect(ps[1].value.Data).toEqual({ a = 1 })
		expect(ps[1].value.MetaData.ActiveSession).toBeNil()
		local ds2 = MigrationCheck.seedOps({ kind = "datastore2", name = "coins" }, 7, 5, 100)
		expect(ds2[1]).toEqual({ op = "setOrdered", name = "coins/7", key = "1", n = 1 })
		expect(ds2[2].name).toBe("coins/7")
		local std = MigrationCheck.seedOps(
			{ kind = "datastore2", name = "coins", savingMethod = "Standard" },
			7,
			5,
			100
		)
		expect(std[1].key).toBe("7")
		local map = MigrationCheck.seedOps({
			main = { kind = "datastore", name = "M", key = "{userId}" },
			stats = { kind = "datastore", name = "S", key = "{userId}" },
		}, 7, { main = 1 }, 100)
		expect(#map).toBe(1)
		expect(map[1].name).toBe("M")
	end)
end)

describe("tools/test-migration end to end (example game)", function()
	local GAME = "tools/lune/testdata/migration/legacy-game"
	it("the example fixture passes every check", function()
		local r = process.exec("lune", { "run", "tools/lune/test-migration", GAME })
		expect(r.code).toBe(0)
		expect(r.stdout).toContain("7 checks passed, 0 failed")
	end)
	it("a fixture that loses a field exits 1 and names it", function()
		local r = process.exec("lune", {
			"run",
			"tools/lune/test-migration",
			GAME,
			"--fixtures",
			"tools/lune/testdata/migration/bad-fixtures",
		})
		expect(r.code).toBe(1)
		expect(r.stdout).toContain("old field 'lastLogin'")
	end)
	it("an import that errors: the reason, the Lua error and the import's print are shown", function()
		local r = process.exec("lune", {
			"run",
			"tools/lune/test-migration",
			"tools/lune/testdata/migration/import-error",
			"--fixtures",
			"tools/lune/testdata/migration/import-error/fixtures",
		})
		expect(r.code).toBe(1)
		expect(r.stdout).toContain("mid-game.json")
		expect(r.stdout).toContain("1-2. nothing lost field by field")
		expect(r.stdout).toContain("LegacyImportFailed reason: import_error")
		expect(r.stdout).toContain("error in the import: ")
		expect(r.stdout).toContain("import-error example: planted failure")
		expect(r.stdout).toContain("[print] import-error example: importing coins")
	end)
	it("no fixtures: exit 1", function()
		local r = process.exec("lune", { "run", "tools/lune/test-migration", "examples/sandbox" })
		expect(r.code).toBe(1)
		expect(r.stderr).toContain("no legacy fixtures found")
	end)
end)

-- (v1.6.0 dogfood round 2) old item lists of { id, uid } tables, receipts compared as id sets,
-- check 4 with no source left, any sold kind
describe("MigrationCheck: round-2 fixture shapes", function()
	local SAVED2 = {
		inventory = { inventory = { u1 = { itemId = "gem" }, u2 = { itemId = "pebble" } } },
		_framework = { legacyPurchases = { ["r-1"] = 1700000000, ["r-2"] = 1700000000 } },
	}

	it("items: entries may be tables with id (as well as itemId) or plain strings", function()
		for _, pets in
			{
				{ { id = "pebble", uid = "old-1" }, { id = "gem", uid = "old-2" } },
				{ { itemId = "pebble" }, "gem" },
			}
		do
			local f = { expect = { pets = { items = "inventory.inventory" } } }
			expect(MigrationCheck.compare({ pets = pets }, SAVED2, f)).toEqual({})
		end
		local f = { expect = { pets = { items = "inventory.inventory" } } }
		local errs = MigrationCheck.compare({ pets = { { id = "gem" } } }, SAVED2, f)
		expect(#errs).toBe(1)
		expect(errs[1]).toContain("items differ")
	end)

	it("_framework.legacyPurchases compares the set of receipt ids, whatever the old values", function()
		local f = { expect = { p = "_framework.legacyPurchases" } }
		expect(MigrationCheck.compare({ p = { ["r-1"] = true, ["r-2"] = true } }, SAVED2, f)).toEqual({})
		expect(MigrationCheck.compare({ p = { ["r-1"] = 5, ["r-2"] = 6 } }, SAVED2, f)).toEqual({})
		expect(MigrationCheck.compare({ p = { "r-1", "r-2" } }, SAVED2, f)).toEqual({})
		local errs = MigrationCheck.compare({ p = { ["r-1"] = true } }, SAVED2, f)
		expect(#errs).toBe(1)
		expect(errs[1]).toContain("receipt ids differ")
		-- any other string target still compares values
		local errs2 = MigrationCheck.compare(
			{ p = { ["r-1"] = true } },
			SAVED2,
			{ expect = { p = "_framework.x" } }
		)
		expect(#errs2).toBe(1)
	end)

	it("sold: any non-empty string is valid; only currency/items are checked, the rest noted", function()
		local f = {
			old = { coins = 1, rebirths = 2 },
			expect = { coins = "economy.currency.Coins", rebirths = "game.rebirths" },
			sold = { coins = "currency", rebirths = "stat" },
		}
		expect(MigrationCheck.validate(f)).toEqual({})
		expect(MigrationCheck.checkSold(f, { "Coins" }, "free")).toEqual({})
		local notes = MigrationCheck.soldUnchecked(f)
		expect(#notes).toBe(1)
		expect(notes[1]).toContain("sold 'rebirths' (stat): not checked")
		f.sold.rebirths = ""
		expect(#MigrationCheck.validate(f)).toBe(1)
		f.sold.rebirths = 3
		expect(#MigrationCheck.validate(f)).toBe(1)
	end)

	it("check 4: a map of sources with none left seeds nothing", function()
		local src = {
			main = { kind = "datastore", name = "M", key = "{userId}" },
			backup = { kind = "datastore", name = "B", key = "{userId}" },
		}
		expect(MigrationCheck.seedsNothing(src, {})).toBe(true)
		expect(MigrationCheck.seedsNothing(src, { main = { a = 1 } })).toBe(false)
		expect(MigrationCheck.seedsNothing({ kind = "datastore", name = "M", key = "k" }, {})).toBe(false)
	end)

	it(
		"end to end: two stores (map of sources), one missing, pets as tables, receipts as true, a sold stat",
		function()
			local r = process.exec("lune", {
				"run",
				"tools/lune/test-migration",
				"tools/lune/testdata/migration/legacy-split",
			})
			expect(r.stdout).toContain("9 checks passed, 0 failed")
			expect(r.stdout).toContain("sold 'main.rebirths' (stat): not checked")
			expect(r.code).toBe(0)
		end
	)
end)
