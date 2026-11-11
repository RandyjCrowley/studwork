--!nocheck
-- v1.6.0 (adopting.md §3, "Sources"): the read-only legacy reader's formats, quiet window, busy
-- rules, retries and errors-as-statuses, plus the pure decision table (Data.decideImport).
local Legacy = require(script.Parent.Parent.server.Legacy)
local Data = require(script.Parent.Parent.server.Data)

local NOW = 1_700_000_000

local function reader(store, o)
	local waits = {}
	local r = Legacy.new({
		backend = store,
		now = function()
			return NOW
		end,
		wait = function(s)
			table.insert(waits, s)
		end,
		isStudio = o and o.isStudio,
		log = function() end,
	})
	return r, waits
end

local OLD = NOW - 3600

describe("Legacy reader: datastore", function()
	it("reads the expanded key; a missing key is none", function()
		local store = Legacy.memory()
		store.set("PlayerData", "Player_7", { coins = 5 }, OLD)
		local r = reader(store)
		local status, value, info =
			r.read({ kind = "datastore", name = "PlayerData", key = "Player_{userId}" }, 7)
		expect(status).toBe("found")
		expect(value).toEqual({ coins = 5 })
		expect(info.updatedAt).toBe(OLD)
		expect((r.read({ kind = "datastore", name = "PlayerData", key = "Player_{userId}" }, 8))).toBe("none")
	end)

	it("scope is part of the store", function()
		local store = Legacy.memory({ datastore = { ["Stats@global"] = { ["7"] = 1 } } })
		local r = reader(store)
		expect((r.read({ kind = "datastore", name = "Stats", scope = "global", key = "{userId}" }, 7))).toBe(
			"found"
		)
		expect((r.read({ kind = "datastore", name = "Stats", key = "{userId}" }, 7))).toBe("none")
	end)

	it("quiet window: a value written within QUIET_SECONDS is busy; older is found", function()
		local store = Legacy.memory()
		store.set("S", "k7", 1, NOW - Legacy.QUIET_SECONDS + 1)
		local r = reader(store)
		expect((r.read({ kind = "datastore", name = "S", key = "k{userId}" }, 7))).toBe("busy")
		store.set("S", "k7", 1, NOW - Legacy.QUIET_SECONDS)
		expect((r.read({ kind = "datastore", name = "S", key = "k{userId}" }, 7))).toBe("found")
		store.now = function()
			return NOW
		end
		store.busy("S", "k7")
		expect((r.read({ kind = "datastore", name = "S", key = "k{userId}" }, 7))).toBe("busy")
	end)

	it("retries errors READ_ATTEMPTS times with backoff, then reports error", function()
		local store = Legacy.memory({ datastore = { S = { k1 = 1 } } })
		local r, waits = reader(store)
		store.failNext(Legacy.READ_ATTEMPTS - 1)
		local status, _, info = r.read({ kind = "datastore", name = "S", key = "k{userId}" }, 1)
		expect(status).toBe("found")
		expect(info.attempts).toBe(Legacy.READ_ATTEMPTS)
		expect(waits).toEqual({ 1, 2 })
		store.failNext(Legacy.READ_ATTEMPTS)
		local s2, v2, info2 = r.read({ kind = "datastore", name = "S", key = "k{userId}" }, 1)
		expect(s2).toBe("error")
		expect(v2).toBeNil()
		expect(info2.error).toContain("injected")
	end)

	it("Studio without API access: unavailable (not retried); a live server: error", function()
		local store = {
			get = function()
				error("StudioAccessToApisNotAllowed: Studio access to API services is not enabled", 0)
			end,
			latestOrdered = function() end,
		}
		local r, waits = reader(store, { isStudio = true })
		expect((r.read({ kind = "datastore", name = "S", key = "{userId}" }, 1))).toBe("unavailable")
		expect(#waits).toBe(0)
		local live = reader(store, { isStudio = false })
		expect((live.read({ kind = "datastore", name = "S", key = "{userId}" }, 1))).toBe("error")
	end)
end)

describe("Legacy reader: profileservice / profilestore", function()
	local function profile(meta, data)
		return {
			Data = data,
			MetaData = meta,
			GlobalUpdates = { 0, {} },
			RobloxMetaData = {},
			UserIds = { 7 },
		}
	end

	it("old = profile.Data; no lock is found", function()
		for _, kind in { "profileservice", "profilestore" } do
			local store = Legacy.memory()
			store.set(
				"PlayerStore",
				"Player_7",
				profile({ ProfileCreateTime = 1, SessionLoadCount = 3, LastUpdate = OLD }, { coins = 9 }),
				OLD
			)
			local r = reader(store)
			local status, value = r.read({ kind = kind, name = "PlayerStore", key = "Player_{userId}" }, 7)
			expect(status).toBe("found")
			expect(value).toEqual({ coins = 9 })
		end
	end)

	it("a lock updated within SESSION_STALE_SECONDS is busy; a stale lock is read anyway", function()
		local store = Legacy.memory()
		local src = { kind = "profilestore", name = "P", key = "Player_{userId}" }
		store.set(
			"P",
			"Player_7",
			profile({ ActiveSession = { 1, "job" }, LastUpdate = NOW - 600 }, { coins = 1 }),
			NOW - 600
		)
		local r = reader(store)
		expect((r.read(src, 7))).toBe("busy")
		store.set(
			"P",
			"Player_7",
			profile(
				{ ActiveSession = { 1, "job" }, LastUpdate = NOW - Legacy.SESSION_STALE_SECONDS - 1 },
				{ coins = 1 }
			),
			NOW - 600
		)
		expect((r.read(src, 7))).toBe("found")
	end)

	it("no Data (only GlobalUpdates) is none; a non-table record is an error", function()
		local store = Legacy.memory()
		store.set("P", "Player_7", { GlobalUpdates = { 0, {} } }, OLD)
		store.set("P", "Player_8", "garbage", OLD)
		local r = reader(store)
		local src = { kind = "profileservice", name = "P", key = "Player_{userId}" }
		expect((r.read(src, 7))).toBe("none")
		expect((r.read(src, 8))).toBe("error")
	end)
end)

describe("Legacy reader: datastore2", function()
	it("OrderedBackups: the ordered store's top value is the key of the save in <name>/<userId>", function()
		local store = Legacy.memory()
		store.setOrdered("coins/7", "1", 1)
		store.setOrdered("coins/7", "2", 2)
		store.set("coins/7", "1", 10, OLD)
		store.set("coins/7", "2", 20, OLD)
		local r = reader(store)
		local status, value = r.read({ kind = "datastore2", name = "coins" }, 7)
		expect(status).toBe("found")
		expect(value).toBe(20)
		expect((r.read({ kind = "datastore2", name = "coins" }, 8))).toBe("none")
	end)

	it("combined: a table of just the combined keys", function()
		local store = Legacy.memory()
		store.setOrdered("DATA/7", "1", 1)
		store.set("DATA/7", "1", { coins = 3, inventory = { "a" }, other = true }, OLD)
		local r = reader(store)
		local status, value =
			r.read({ kind = "datastore2", name = "DATA", combined = { "coins", "inventory" } }, 7)
		expect(status).toBe("found")
		expect(value).toEqual({ coins = 3, inventory = { "a" } })
	end)

	it("Standard: GetDataStore(name) keyed by the userId", function()
		local store = Legacy.memory()
		store.set("coins", "7", 44, OLD)
		local r = reader(store)
		local status, value = r.read({ kind = "datastore2", name = "coins", savingMethod = "Standard" }, 7)
		expect(status).toBe("found")
		expect(value).toBe(44)
	end)
end)

describe("Legacy sources: validation and maps", function()
	it("refuses bad kinds, keys and fields", function()
		expect(Legacy.validateSource({ kind = "sql", name = "x", key = "{userId}" })).toContain("source.kind")
		expect(Legacy.validateSource({ kind = "datastore", name = "x", key = "Player" })).toContain(
			"no {userId}"
		)
		expect(Legacy.validateSource({ kind = "datastore", name = "x", key = "{userId}_{slot}" })).toContain(
			"{slot}"
		)
		expect(Legacy.validateSource({ kind = "datastore", name = "x", key = "{userId}", extra = 1 })).toContain(
			"unknown source field"
		)
		expect(Legacy.validateSource({ kind = "datastore2", name = "x", key = "{userId}" })).toContain(
			"no key"
		)
		expect(Legacy.validateSource({ kind = "datastore", name = "x", key = "P_{userId}" })).toBeNil()
	end)

	it("readAll over a map: found when any source is; busy or error wins", function()
		local store = Legacy.memory()
		store.set("Main", "7", { a = 1 }, OLD)
		local r = reader(store)
		local spec = {
			main = { kind = "datastore", name = "Main", key = "{userId}" },
			stats = { kind = "datastore", name = "Stats", key = "{userId}" },
		}
		local status, old, sources = r.readAll(spec, 7)
		expect(status).toBe("found")
		expect(old).toEqual({ main = { a = 1 } })
		expect(sources.main.found).toBe(true)
		expect(sources.stats.found).toBe(false)
		store.set("Stats", "7", 1, NOW)
		expect((r.readAll(spec, 7))).toBe("busy")
		store.failNext(Legacy.READ_ATTEMPTS * 2)
		expect((r.readAll(spec, 7))).toBe("error")
	end)

	it("RECEIPT_KEEP_DAYS matches Data's pruning window", function()
		expect(Data.LEGACY_RECEIPT_KEEP_SECONDS).toBe(Legacy.RECEIPT_KEEP_DAYS * 86400)
	end)
end)

describe("Data.decideImport: the §3 decision table", function()
	local found = { main = { found = true, updatedAt = 100 } }
	local none = { main = { found = false } }
	it("no marker", function()
		expect({ Data.decideImport(nil, 1, "none", none) }).toEqual({ "none", nil, true })
		expect({ Data.decideImport(nil, 1, "found", found) }).toEqual({ "import", nil, true })
	end)
	it("marker found = false", function()
		local m = { v = 1, at = 50, found = false }
		expect({ Data.decideImport(m, 1, "none", none) }).toEqual({ "none", nil, false })
		expect({ Data.decideImport(m, 1, "found", found) }).toEqual({ "import", nil, true })
	end)
	it("marker found = true", function()
		local m = { v = 1, at = 100, found = true }
		expect({ Data.decideImport(m, 1, "found", found) }).toEqual({ "none", nil, false })
		-- within the skew is not a change
		expect({ Data.decideImport(m, 1, "found", { main = { found = true, updatedAt = 105 } }) }).toEqual({
			"none",
			nil,
			false,
		})
		expect({ Data.decideImport(m, 1, "found", { main = { found = true, updatedAt = 106 } }) }).toEqual({
			"merge",
			"changed",
			true,
		})
		expect({ Data.decideImport(m, 2, "found", found) }).toEqual({ "merge", "version", true })
		expect({ Data.decideImport(m, 2, "none", none) }).toEqual({ "none", nil, false })
	end)
end)

describe("Data.pruneLegacyPurchases: by age only", function()
	it("drops entries older than the window, never by count", function()
		local map = {}
		for i = 1, 500 do
			map["p" .. i] = NOW - 10
		end
		map.old = NOW - Data.LEGACY_RECEIPT_KEEP_SECONDS - 1
		local out = Data.pruneLegacyPurchases(map, NOW, Data.LEGACY_RECEIPT_KEEP_SECONDS)
		expect(out.old).toBeNil()
		expect(out.p500).toBe(NOW - 10)
		local n = 0
		for _ in out do
			n += 1
		end
		expect(n).toBe(500)
		expect(map.old ~= nil).toBe(true) -- copy-on-write
		map.old = nil
		expect(Data.pruneLegacyPurchases(map, NOW, Data.LEGACY_RECEIPT_KEEP_SECONDS)).toBeNil()
	end)
end)
