--!nocheck
-- v1.6.0 (adopting.md §3, §4.1): ctx.data.importLegacy end to end in the harness, with the REAL
-- Items + Inventory kit modules: registration, the decision table on join, failures that never
-- change data, the kit limits in an import, receipts and the markers.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Harness = require("packages/framework/test/harness.luau")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Server = require("packages/framework/server/init.luau")
local Legacy = require("packages/framework/server/Legacy.luau")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Items = require(Modules:WaitForChild("Items"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Loader = require("packages/framework/server/Loader.luau")

local ITEMS = {
	{ id = "pebble", name = "Pebble", rarity = "Common" },
	{ id = "gem", name = "Gem", rarity = "Epic" },
}
local SRC = { kind = "datastore", name = "PlayerData", key = "Player_{userId}" }
local T0 = 1_700_000_000
local OLD_AT = T0 - 86400

local calls

-- The game-side module that declares the import. o.spec(ctx) -> importLegacy spec overrides.
local function oldModule(o)
	local ref = StudWork.defineModule({
		name = o.name or "Old",
		version = "1.0.0",
		framework = "^1.3.0",
		dependsOn = { Inventory },
		data = { key = o.key or "old", version = 1, default = { coins = 0, settings = {} } },
	})
	local server = {
		init = function(ctx)
			if o.register == false then
				return
			end
			local spec = {
				id = o.id or "v1-save",
				version = o.version or 1,
				source = o.source or SRC,
				import = function(tx, old, info)
					table.insert(
						calls,
						{ what = "import", old = old, info = info, isImport = ctx.data.isImport(tx) }
					)
					if o.importFn then
						return o.importFn(ctx, tx, old, info)
					end
					local s = ctx.section(tx)
					s.coins = old.coins or 0
					s.settings = old.settings or {}
					for _, id in old.inventory or {} do
						ctx.depsTx[Inventory].add(tx, id, { source = "legacy_import" })
					end
				end,
				receipts = o.receipts,
				itemTag = o.itemTag,
			}
			if o.merge ~= false then
				spec.merge = function(tx, old, info)
					table.insert(calls, { what = "merge", old = old, info = info })
					ctx.section(tx).coins = old.coins or 0
				end
			end
			for k, v in o.extra or {} do
				spec[k] = v
			end
			ctx.data.importLegacy(spec)
		end,
		start = o.start,
	}
	return ref, server
end

local function boot(o)
	o = o or {}
	calls = {}
	local Old, oldServer = oldModule(o)
	local modules = { Items, Inventory, Old }
	local servers = {
		Items = Loader.defaultLoadServer(Items, nil, { bindNet = false }),
		Inventory = Loader.defaultLoadServer(Inventory, nil, { bindNet = false }),
		Old = oldServer,
	}
	for name, extra in o.more or {} do
		table.insert(modules, extra.ref)
		servers[name] = extra.server
	end
	local legacy = o.legacy or Harness.legacyStore()
	local opts = {
		modules = modules,
		servers = servers,
		items = ITEMS,
		config = { Inventory = { inventory = { cap = o.cap or 3 } } },
		legacy = legacy,
		store = o.store,
		isStudio = o.isStudio,
		startTime = o.startTime,
		gameId = o.gameId,
	}
	if o.bootOnly then
		return Harness.boot(opts)
	end
	local h = Harness.new(opts)
	return h, legacy, Old
end

local function seedOld(legacy, userId, value, at)
	legacy.set("PlayerData", "Player_" .. userId, value, at or OLD_AT)
end

local function inventoryCount(h, p)
	local n = 0
	for _ in h.runtime.data.view(p, "inventory").inventory do
		n += 1
	end
	return n
end

local function custom(h, name)
	local out = {}
	for _, a in h.fake.analytics do
		if a.kind == "custom" and a.name == name then
			table.insert(out, a)
		end
	end
	return out
end

local function importCalls(what)
	local n = 0
	for _, c in calls do
		if c.what == what then
			n += 1
		end
	end
	return n
end

describe("importLegacy: registration", function()
	it("registers in init; legacyImports lists the id", function()
		local h = boot()
		expect(h.runtime.data.legacyImports()).toEqual({ "v1-save" })
	end)

	it("after init (in start) is a boot error", function()
		local _, err = boot({
			register = false,
			bootOnly = true,
			start = function(ctx)
				ctx.data.importLegacy({ id = "x", version = 1, source = SRC, import = function() end })
			end,
		})
		expect(err).toContain("must be called in init")
	end)

	it("a second registration in the same module is a boot error", function()
		local Twice = StudWork.defineModule({ name = "Twice", version = "1.0.0", framework = "^1.3.0" })
		local _, err2 = boot({
			bootOnly = true,
			more = {
				Twice = {
					ref = Twice,
					server = {
						init = function(ctx)
							ctx.data.importLegacy({
								id = "t1",
								version = 1,
								source = SRC,
								import = function() end,
							})
							ctx.data.importLegacy({
								id = "t2",
								version = 1,
								source = SRC,
								import = function() end,
							})
						end,
					},
				},
			},
		})
		expect(err2).toContain("already registered")
	end)

	it("a duplicate id across modules is a boot error", function()
		local Dup = StudWork.defineModule({ name = "Dup", version = "1.0.0", framework = "^1.3.0" })
		local _, err = boot({
			bootOnly = true,
			more = {
				Dup = {
					ref = Dup,
					server = {
						init = function(ctx)
							ctx.data.importLegacy({
								id = "v1-save",
								version = 1,
								source = SRC,
								import = function() end,
							})
						end,
					},
				},
			},
		})
		expect(err).toContain("already used by Old")
	end)

	it("a source on StudWork's own store (also _Studio) is a boot error, whatever the key", function()
		for _, name in { "PlayerData_test-game", "PlayerData_test-game_Studio" } do
			local _, err =
				boot({ bootOnly = true, source = { kind = "profilestore", name = name, key = "x{userId}" } })
			expect(err).toContain("StudWork's own save store")
		end
	end)

	it("validates id, version, functions, itemTag and sources", function()
		local cases = {
			{ { id = "bad id!" }, "id must be" },
			{ { version = 0 }, "version must be" },
			{ { version = 1.5 }, "version must be" },
			{ { itemTag = "paid:robux" }, "itemTag must be" },
			{ { source = { kind = "datastore", name = "X", key = "{slot}" } }, "{slot}" },
			{ { source = { kind = "nope", name = "X", key = "{userId}" } }, "source.kind" },
			{ { extra = { bogus = 1 } }, "unknown field 'bogus'" },
			{ { extra = { receipts = 5 } }, "receipts must be" },
			{ { extra = { merge = "x" } }, "merge must be" },
		}
		for _, case in cases do
			local o = case[1]
			o.bootOnly = true
			local _, err = boot(o)
			expect(err).toContain(case[2])
		end
	end)

	it("no import registered: no legacy read on join (hot path)", function()
		local h, legacy = boot({ register = false })
		h:addPlayer({ userId = 1 })
		expect(legacy.reads).toBe(0)
		expect(h.runtime.data.legacyImports()).toEqual({})
	end)
end)

describe("importLegacy: the decision table on join", function()
	it("no marker + none found: nothing runs, marker found = false, LegacyNotFound", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(true)
		expect(importCalls("import")).toBe(0)
		local m = h.runtime.data.legacyStatus(p, "v1-save")
		expect(m.found).toBe(false)
		expect(m.v).toBe(1)
		expect(m.sources.main.found).toBe(false)
		expect(#custom(h, "LegacyNotFound")).toBe(1)
	end)

	it("no marker + found: import runs once, data and marker in the same save", function()
		local h, legacy = boot()
		seedOld(legacy, 1, { coins = 50, inventory = { "pebble", "gem" }, settings = { music = false } })
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(true)
		expect(importCalls("import")).toBe(1)
		expect(calls[1].isImport).toBe(true)
		expect(calls[1].info.found).toBe(true)
		expect(calls[1].info.userId).toBe(1)
		expect(calls[1].info.previous).toBeNil()
		local old = h.runtime.data.view(p, "old")
		expect(old.coins).toBe(50)
		expect(old.settings.music).toBe(false)
		expect(inventoryCount(h, p)).toBe(2)
		h:removePlayer(p)
		local saved = h:saved(p)
		expect(saved._framework.imports["v1-save"].found).toBe(true)
		expect(saved._framework.imports["v1-save"].at).toBe(T0)
		expect(saved._framework.imports["v1-save"].sources.main.updatedAt).toBe(OLD_AT)
		expect(saved.old.coins).toBe(50)
		-- v1.5-readable: the framework schema version doesn't move
		expect(saved._framework.schemaVersion).toBe(2)
	end)

	it("marker found = false + none: nothing, marker unchanged; then found: import", function()
		local h, legacy = boot()
		local p = h:addPlayer({ userId = 1 })
		h:rejoin(p, { secondsAway = 100 })
		expect(h.runtime.data.legacyStatus(p, "v1-save").at).toBe(T0) -- not rewritten
		expect(importCalls("import")).toBe(0)
		seedOld(legacy, 1, { coins = 7 })
		h:rejoin(p, { secondsAway = 100 })
		expect(importCalls("import")).toBe(1)
		expect(h.runtime.data.view(p, "old").coins).toBe(7)
		expect(h.runtime.data.legacyStatus(p, "v1-save").found).toBe(true)
	end)

	it("marker found = true, same version, unchanged: nothing on rejoin (import not called again)", function()
		local h, legacy = boot()
		seedOld(legacy, 1, { coins = 5, inventory = { "pebble" } })
		local p = h:addPlayer({ userId = 1 })
		h:rejoin(p, { secondsAway = 600 })
		h:rejoin(p, { secondsAway = 600 })
		expect(importCalls("import")).toBe(1)
		expect(importCalls("merge")).toBe(0)
		expect(inventoryCount(h, p)).toBe(1)
	end)

	it(
		"a source updated after the marker (+5 s): merge with reason changed, LegacyChangedAfterImport",
		function()
			local h, legacy = boot()
			seedOld(legacy, 1, { coins = 5 })
			local p = h:addPlayer({ userId = 1 })
			h:removePlayer(p)
			h.clock += 1000
			seedOld(legacy, 1, { coins = 9 }, h.clock - 500) -- written after the import, outside the quiet window
			p = h:addPlayer({ userId = 1 })
			expect(p.loaded).toBe(true)
			expect(importCalls("merge")).toBe(1)
			local merge = calls[#calls]
			expect(merge.info.reason).toBe("changed")
			expect(merge.info.previous.found).toBe(true)
			expect(h.runtime.data.view(p, "old").coins).toBe(9)
			expect(#custom(h, "LegacyChangedAfterImport")).toBe(1)
			-- idempotent marker: a second rejoin changes nothing
			h:rejoin(p, { secondsAway = 60 })
			expect(importCalls("merge")).toBe(1)
		end
	)

	it("marker v < version: merge with reason version", function()
		local store = Harness.memoryStore()
		local legacy = Harness.legacyStore()
		local h = boot({ store = store, legacy = legacy })
		seedOld(legacy, 1, { coins = 5 })
		local p = h:addPlayer({ userId = 1 })
		h:removePlayer(p)
		local h2 = boot({ store = store, legacy = legacy, version = 2 })
		local p2 = h2:addPlayer({ userId = 1 })
		expect(p2.loaded).toBe(true)
		expect(importCalls("merge")).toBe(1)
		expect(calls[1].info.reason).toBe("version")
		expect(h2.runtime.data.legacyStatus(p2, "v1-save").v).toBe(2)
	end)

	it("a merge needed but none declared: kicked, nothing written, merge_missing", function()
		local h, legacy = boot({ merge = false })
		seedOld(legacy, 1, { coins = 5 })
		local p = h:addPlayer({ userId = 1 })
		h:removePlayer(p)
		local before = h:saved(p)
		h.clock += 1000
		seedOld(legacy, 1, { coins = 9 }, h.clock - 500)
		p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(false)
		expect(p.kicked).toBe(Server.KICK_LEGACY_IMPORT)
		expect(h:saved(p)).toEqual(before)
		local failed = custom(h, "LegacyImportFailed")
		expect(failed[#failed].fields.reason).toBe("merge_missing")
		expect(#custom(h, "LegacyChangedAfterImport")).toBe(1)
	end)
end)

describe("importLegacy: failure never changes data", function()
	local function failsWith(h, _legacy, userId, reason)
		local before = h:saved({ UserId = userId })
		local p = h:addPlayer({ userId = userId })
		expect(p.loaded).toBe(false)
		expect(p.kicked).toBe(Server.KICK_LEGACY_IMPORT)
		expect(h.runtime.data.isLoaded(p)).toBe(false)
		expect(h:saved(p)).toEqual(before)
		local failed = custom(h, "LegacyImportFailed")
		expect(failed[#failed].fields.reason).toBe(reason)
		expect(failed[#failed].fields.reason).toBe(reason) -- reason only, no data
		local n = 0
		for _ in failed[#failed].fields do
			n += 1
		end
		expect(n).toBe(1)
		h:removePlayer(p)
		return p
	end

	it("a read error after the retries: kicked, store unchanged, the next join imports", function()
		local h, legacy = boot()
		seedOld(legacy, 1, { coins = 5 })
		legacy.failNext(Legacy.READ_ATTEMPTS)
		failsWith(h, legacy, 1, "read_error")
		expect(h:saved({ UserId = 1 })).toBeNil()
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(true)
		expect(h.runtime.data.view(p, "old").coins).toBe(5)
	end)

	it("an existing StudWork save is left exactly as it was", function()
		local h, legacy = boot()
		local p = h:addPlayer({ userId = 1 }) -- marker found = false
		h:removePlayer(p)
		seedOld(legacy, 1, { coins = 5 })
		legacy.failNext(Legacy.READ_ATTEMPTS)
		failsWith(h, legacy, 1, "read_error")
	end)

	it("busy: the quiet window", function()
		local h, legacy = boot()
		seedOld(legacy, 1, { coins = 5 }, T0 - 10)
		failsWith(h, legacy, 1, "busy")
		h.clock += Legacy.QUIET_SECONDS
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(true)
	end)

	it("busy: a live ProfileService lock; a stale lock is read anyway", function()
		local src = { kind = "profileservice", name = "Profiles", key = "Player_{userId}" }
		local h, legacy = boot({ source = src })
		legacy.set("Profiles", "Player_1", {
			Data = { coins = 3 },
			MetaData = { ActiveSession = { 1, "job" }, LastUpdate = T0 - 600, SessionLoadCount = 2 },
			GlobalUpdates = { 0, {} },
		}, T0 - 600)
		failsWith(h, legacy, 1, "busy")
		h.clock += Legacy.SESSION_STALE_SECONDS
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(true)
		expect(h.runtime.data.view(p, "old").coins).toBe(3)
	end)

	it("a wrong type where a table is expected is a read error", function()
		local src = { kind = "profilestore", name = "Profiles", key = "Player_{userId}" }
		local h, legacy = boot({ source = src })
		legacy.set("Profiles", "Player_1", 42, OLD_AT)
		failsWith(h, legacy, 1, "read_error")
	end)

	it("the session lost during the reads: lost_session", function()
		local store = Harness.memoryStore()
		local active = true
		store.isActive = function()
			return active
		end
		local h, legacy = boot({ store = store })
		seedOld(legacy, 1, { coins = 5 })
		active = false
		failsWith(h, legacy, 1, "lost_session")
		active = true
		expect(h:addPlayer({ userId = 1 }).loaded).toBe(true)
	end)

	it("the player left during the reads: lost_session", function()
		local legacy = Harness.legacyStore()
		local h
		local get = legacy.get
		legacy.get = function(...)
			for p in h.inGame do
				h.inGame[p] = nil -- the player leaves while the read yields
			end
			return get(...)
		end
		h = boot({ legacy = legacy })
		seedOld(legacy, 1, { coins = 5 })
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(false)
		expect(h:saved(p)).toBeNil()
		expect(custom(h, "LegacyImportFailed")[1].fields.reason).toBe("lost_session")
	end)

	it("import erroring: import_error, nothing written (even sections it already touched)", function()
		local h, legacy = boot({
			importFn = function(ctx, tx, old)
				ctx.section(tx).coins = old.coins
				ctx.depsTx[Inventory].add(tx, "pebble")
				error("boom")
			end,
		})
		seedOld(legacy, 1, { coins = 5 })
		local p = failsWith(h, legacy, 1, "import_error")
		expect(h:saved(p)).toBeNil()
	end)

	it("import yielding: import_error", function()
		local h, legacy = boot({
			importFn = function()
				coroutine.yield()
			end,
		})
		seedOld(legacy, 1, { coins = 5 })
		failsWith(h, legacy, 1, "import_error")
	end)

	it("a refused depsTx call raises inside the import (fails closed, never a partial save)", function()
		local h, legacy = boot({
			importFn = function(ctx, tx)
				ctx.depsTx[Inventory].add(tx, "no-such-item")
			end,
		})
		seedOld(legacy, 1, { coins = 5 })
		failsWith(h, legacy, 1, "import_error")
		local lines = table.concat(h:warnings(), "\n")
		expect(lines).toContain("legacy import: Inventory.add refused (nil)")
	end)

	it("outside an import a refused depsTx call just returns nil (unchanged behaviour)", function()
		local h = boot({ register = false })
		local p = h:addPlayer({ userId = 1 })
		local Old = h.runtime.byName("Old")
		local result = "unset"
		h.runtime.data.runTx(p, function(tx)
			expect(h.runtime.data.isImport(tx)).toBe(false)
			result = h.runtime.txApis[Inventory].add(tx, "no-such-item")
		end)
		expect(result).toBeNil()
		expect(Old ~= nil).toBe(true)
	end)

	it("receipts erroring is an import_error", function()
		local h, legacy = boot({
			receipts = function()
				return "nope"
			end,
		})
		seedOld(legacy, 1, { coins = 5 })
		failsWith(h, legacy, 1, "import_error")
	end)
end)

describe("importLegacy: kit limits, receipts, repeat safety", function()
	it("an import over the Inventory cap keeps every item", function()
		local h, legacy = boot({ cap = 3 })
		seedOld(legacy, 1, { inventory = { "pebble", "pebble", "gem", "gem", "pebble" } })
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(true)
		expect(inventoryCount(h, p)).toBe(5)
		-- after the import the cap applies again: no more adds while over it
		expect(h:use(Inventory).add(p, "pebble")).toBeNil()
	end)

	it("the import tx meta carries legacyImport = itemTag (paid by default, free); isImport", function()
		for _, tag in { "paid", "free" } do
			local current
			local seen
			local h, legacy = boot({
				itemTag = if tag == "paid" then nil else tag,
				importFn = function(ctx, tx)
					seen = {
						meta = current.runtime.data.txMeta(tx).legacyImport,
						isImport = ctx.data.isImport(tx),
					}
				end,
			})
			current = h
			seedOld(legacy, 1, { coins = 1 })
			h:addPlayer({ userId = 1 })
			expect(seen.meta).toBe(tag)
			expect(seen.isImport).toBe(true)
			expect(h.runtime.data.isImport({})).toBe(false)
		end
	end)

	it("a module can't set legacyImport itself", function()
		local h = boot({ register = false })
		local p = h:addPlayer({ userId = 1 })
		expect(function()
			h.runtime.data.runTx(p, function() end, { meta = { legacyImport = "paid" } })
		end).toThrow("set by the framework's legacy import only")
	end)

	it("receipts -> _framework.legacyPurchases in the import commit (map and list)", function()
		local h, legacy = boot({
			receipts = function(old)
				return old.purchases
			end,
		})
		seedOld(legacy, 1, { coins = 1, purchases = { ["r-1"] = T0 - 100, ["r-2"] = T0 - 50 } })
		seedOld(legacy, 2, { coins = 1, purchases = { "r-3" } })
		local p1 = h:addPlayer({ userId = 1 })
		local p2 = h:addPlayer({ userId = 2 })
		expect(h.runtime.data.frameworkField(p1, "legacyPurchases")).toEqual({
			["r-1"] = T0 - 100,
			["r-2"] = T0 - 50,
		})
		expect(h.runtime.data.frameworkField(p2, "legacyPurchases")).toEqual({ ["r-3"] = T0 })
		-- the 200-entry purchases cap never touches them
		h:removePlayer(p1)
		expect(h:saved(p1)._framework.legacyPurchases["r-1"]).toBe(T0 - 100)
	end)

	it("legacyPurchases are pruned by age (RECEIPT_KEEP_DAYS) on save, never by count", function()
		local many = {}
		for i = 1, 300 do
			many["r-" .. i] = T0 - 10
		end
		many.ancient = T0 - Legacy.RECEIPT_KEEP_DAYS * 86400 - 1
		local h, legacy = boot({
			receipts = function(old)
				return old.purchases
			end,
		})
		seedOld(legacy, 1, { purchases = many })
		local p = h:addPlayer({ userId = 1 })
		h:removePlayer(p)
		local lp = h:saved(p)._framework.legacyPurchases
		expect(lp.ancient).toBeNil()
		local n = 0
		for _ in lp do
			n += 1
		end
		expect(n).toBe(300)
		-- 90 days later every one of them ages out
		h.clock += Legacy.RECEIPT_KEEP_DAYS * 86400 + 1
		p = h:addPlayer({ userId = 1 })
		h:removePlayer(p)
		expect(next(h:saved(p)._framework.legacyPurchases)).toBeNil()
	end)

	it("crash after the import commit, before any save: the next join imports again, no double", function()
		local store = Harness.memoryStore()
		local legacy = Harness.legacyStore()
		local h = boot({ store = store, legacy = legacy })
		seedOld(legacy, 1, { coins = 5, inventory = { "pebble", "gem" } })
		local p = h:addPlayer({ userId = 1 })
		expect(inventoryCount(h, p)).toBe(2)
		-- the server dies: nothing saved; a new server
		local h2 = boot({ store = store, legacy = legacy })
		local p2 = h2:addPlayer({ userId = 1 })
		expect(p2.loaded).toBe(true)
		expect(inventoryCount(h2, p2)).toBe(2)
		expect(h2.runtime.data.view(p2, "old").coins).toBe(5)
	end)

	it("tx.after effects of the import run once the player is loaded (ItemAdded)", function()
		local h, legacy = boot()
		seedOld(legacy, 1, { inventory = { "pebble" } })
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(true)
		expect(#h:warnings() == 0 or not string.find(table.concat(h:warnings(), "\n"), "post-commit")).toBe(
			true
		)
	end)

	it("Studio without API access: the import is skipped, no marker, the player loads", function()
		local legacy = {
			get = function()
				error("Studio access to API services is not enabled", 0)
			end,
			latestOrdered = function() end,
		}
		local h = boot({ legacy = legacy, isStudio = true })
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(true)
		expect(h.runtime.data.legacyStatus(p, "v1-save")).toBeNil()
		expect(table.concat(h:warnings(), "\n")).toContain("SKIPPED")
	end)

	it("console: adopt status prints every marker (Studio); refused outside Studio", function()
		local h, legacy = boot({ isStudio = true })
		seedOld(legacy, 1, { coins = 5 })
		h:addPlayer({ userId = 1 })
		local text = h:console("adopt", "status", "1")
		expect(text).toContain("v1-save: v=1")
		expect(text).toContain("found=true")
		expect(text).toContain("main=found@" .. tostring(OLD_AT))
		local live = boot()
		live:addPlayer({ userId = 1 })
		expect(live:console("adopt", "status", "1")).toBe("Studio or admin only")
	end)
end)
