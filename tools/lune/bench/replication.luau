--!nocheck
--[[
	Replication benchmark (M2). Not mapped into any Rojo project; run with `tools/bench`.

	50 players x 100 items x 60 ticks. Each tick does what the Economy tick does: for every player
	one committed Data.update that changes `currency` and `stats` (v1.1 contract: the working copy
	gives touched sections new table identities, untouched sections keep their references).
	Per player per tick we then do what Replication + charm-sync do on flush:
	  BEFORE     = v1.0.0: Snapshot.build with a full Snapshot.copy of PlayerData + charm-sync diff
	  AFTER      = SectionCache (per-section versions, only touched sections move) + diff
	  AFTER-STUB = SectionCache with the Phase 0 sectionVersion stub (one counter for every
	               section, so every section is re-copied) + diff
	The diff is charm-sync 0.4.1's real `patch.luau` (deps/Packages), loaded with its Charm /
	validate requires stubbed (only `Charm.flags.strict` is read; strict = false so validate is
	never called, same as a non-strict server).

	Allocation: Luau cannot stop or force the GC (Lune's collectgarbage only accepts "count"), so
	two numbers are reported:
	  * new tables / tick (exact, deterministic): tables reachable from the new snapshots that were
	    not in the previous snapshots, plus every table in the produced patches (counted outside
	    the timed region by walking identities);
	  * KB allocated / tick: collectgarbage("count") sampled around every player's sync; positive
	    deltas are summed (a negative delta = a GC step ran and is skipped). Lower bound when a GC
	    step overlaps a sync; same method for all variants. Samples cost ~50 calls/tick and are
	    inside the timed region for every variant.

	Usage: lune run tools/lune/bench/replication [runs] [variant...]   (default 5 runs, every
	variant; prints a markdown table with the median and the min-max spread over the runs)
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local Harness = require("../testkit/harness")
local Snapshot = Harness.require("packages/framework/server/Replication/Snapshot.luau")
local SectionCache = Harness.require("tools/lune/bench/SectionCache.luau") -- v1.1 parity cache
local Data = Harness.require("packages/framework/server/Data.luau")
local Store = Harness.require("packages/framework/server/Store.luau")

local PLAYERS = 50
local ITEMS = 100
local TICKS = 60
local RUNS = tonumber(process.args[1]) or 5

--------------------------------------------------------------------------------
-- charm-sync diff (real source)
--------------------------------------------------------------------------------

local PATCH_DIR = "deps/Packages/_Index/littensy_charm-sync@0.4.1/charm-sync/src/"
local function loadPatch()
	local config = luau.load(fs.readFile(PATCH_DIR .. "config.luau"), { debugName = "config" })()
	local stubs = {
		["../Charm"] = { flags = { strict = false } },
		["./config"] = config,
		["./types"] = {},
		["./validate"] = function() end,
	}
	-- patch.luau only uses these globals
	local env = {
		require = function(path)
			local m = stubs[path]
			assert(m ~= nil, "bench: unexpected require " .. tostring(path))
			return m
		end,
		table = table,
		type = type,
		next = next,
		tostring = tostring,
		tonumber = tonumber,
	}
	return luau.load(
		fs.readFile(PATCH_DIR .. "patch.luau"),
		{ debugName = "charm-sync/patch", environment = env }
	)()
end
local patch = loadPatch()
local diff = patch.diff

--------------------------------------------------------------------------------
-- fake PlayerData + fake Data (per-section versions as the contract says)
--------------------------------------------------------------------------------

local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

local function makeData(seed: number)
	local inventory = {}
	for i = 1, ITEMS do
		local uid = string.format("u%d_%03d", seed, i)
		inventory[uid] = {
			uid = uid,
			itemId = "item" .. (i % 25),
			level = 1 + i % 5,
			acquiredAt = 1700000000 + i,
			rarity = RARITIES[1 + i % #RARITIES],
			mutation = if i % 7 == 0 then "Gold" else "None",
		}
	end
	local purchases = {}
	for i = 1, 200 do
		purchases["receipt" .. i] = 1700000000 + i
	end
	local displayed = {}
	for i = 1, 8 do
		displayed["slot" .. i] = string.format("u%d_%03d", seed, i)
	end
	local seen = {}
	for i = 1, 50 do
		seen["mail" .. i] = 1700000000 + i
	end
	return {
		schemaVersion = 3,
		currency = { Coins = 1000, Gems = 5 },
		inventory = inventory,
		displayed = displayed,
		upgrades = { speed = 3, luck = 2, capacity = 1, magnet = 0, offline = 4 },
		rebirths = 2,
		multipliers = { boost = { value = 2, expiresAt = 1700009999, source = "potion" } },
		streak = { day = 3, lastClaim = 1700000000 },
		lastSeen = 1700000000,
		firstJoin = 1690000000,
		purchases = purchases,
		pity = { basic = 3, premium = 7, egg = 1 },
		stats = { totalEarned = 5000, itemsCollected = 100, rolls = 40, rebirths = 2, playtime = 3600 },
		funnel = { Joined = 1690000000, FirstCollect = 1690000100, FirstUpgrade = 1690000200 },
		game = { sandbox = { quests = { q1 = 1, q2 = 0 }, settings = { music = true } } },
		mail = { seen = seen, retries = {}, dead = {} },
	}
end

type FakePlayer = { data: any, versions: { [string]: number }, global: number }

local function newPlayers(): { FakePlayer }
	local players = {}
	for p = 1, PLAYERS do
		players[p] = { data = makeData(p), versions = {}, global = 0 }
	end
	return players
end

-- One committed Economy-tick update: currency + stats change, both get new identities.
local function economyTick(p: FakePlayer, tick: number)
	local d = p.data
	local currency = table.clone(d.currency)
	currency.Coins += 10 + tick
	local stats = table.clone(d.stats)
	stats.totalEarned += 10 + tick
	d.currency = currency
	d.stats = stats
	p.versions.currency = (p.versions.currency or 0) + 1
	p.versions.stats = (p.versions.stats or 0) + 1
	p.global += 1 -- what the Phase 0 stub returns for every section
end

--------------------------------------------------------------------------------
-- variants
--------------------------------------------------------------------------------

local EXTRA = { ratePerSec = 12, multiplier = 2 }
local SHARED = { activeEvents = { rain = 1700001000 } }

local variants = {}

variants.BEFORE = function(_players)
	local last = {}
	local function sync(i, p)
		local new = Snapshot.build(p.data, EXTRA, SHARED)
		local d = diff(last[i], new)
		last[i] = new
		return d, new
	end
	return sync
end

local function cached(stub: boolean)
	return function(players)
		local last, caches = {}, {}
		local shared = { activeEvents = Snapshot.copy(SHARED.activeEvents) }
		for i = 1, #players do
			caches[i] = SectionCache.new()
		end
		local function sync(i, p)
			local versionOf = if stub
				then function(_s)
					return p.global
				end
				else function(s)
					return p.versions[s] or 0
				end
			local dataCopy = caches[i]:build(p.data, versionOf)
			local new = Snapshot.build(p.data, EXTRA, shared, { dataCopy = dataCopy, sanitized = true })
			local d = diff(last[i], new)
			last[i] = new
			return d, new
		end
		return sync
	end
end
variants.AFTER = cached(false)
variants["AFTER-STUB"] = cached(true)

-- MERGED (core-v1.3.0 Phase 2: ported from the deleted v1.2 Data/Transaction.luau to the
-- framework): the tick goes through the REAL framework Data.runTx (per-section working copies,
-- deep-equal check, per-section versions) on a v1.2 save the framework split into sections on
-- load, and the replicated snapshot is built from Data.view (the frozen per-section copy the
-- framework caches per section version). Measures both halves together.
local SECTION_KEYS =
	{ "economy", "inventory", "plot", "upgrades", "rebirth", "streak", "rarity", "mail", "sandbox" }
local function benchModules(): { any }
	local defaults = {
		economy = { currency = {}, multipliers = {} },
		inventory = { inventory = {} },
		plot = { displayed = {} },
		upgrades = { upgrades = {} },
		rebirth = { rebirths = 0 },
		streak = { streak = {} },
		rarity = { pity = {} },
		mail = { mail = {} },
		sandbox = {},
	}
	local out = {}
	for _, key in SECTION_KEYS do
		table.insert(
			out,
			{ name = "Bench_" .. key, data = { key = key, version = 1, default = defaults[key] } }
		)
	end
	return out
end
local runtimes: { [any]: any } = {}
variants.MERGED = function(players)
	local store = Store.memory()
	local data = Data.new({
		store = store,
		modules = benchModules(),
		gameId = "sandbox",
		now = function()
			return 1700000000
		end,
		log = function() end,
	})
	local last = {}
	local shared = { activeEvents = Snapshot.copy(SHARED.activeEvents) }
	for i, p in players do
		local player = { UserId = i, Name = "Bench" .. i }
		store.save(i, p.data) -- a v1.2 flat save: split into sections on load
		assert(data.load(player), "bench: framework Data.load failed")
		runtimes[p] = { data = data, player = player }
	end
	local function sync(i, p, modulesOnly: boolean?)
		local rt = runtimes[p]
		local new = { data = {}, extra = EXTRA, shared = shared }
		for _, key in SECTION_KEYS do
			new.data[key] = rt.data.view(rt.player, key)
		end
		if not modulesOnly then
			new.data._framework = rt.data.view(rt.player, "_framework")
		end
		local d = diff(last[i], new)
		last[i] = new
		return d, new
	end
	return sync
end
local tickFns = {
	MERGED = function(p: FakePlayer, tick: number)
		local rt = runtimes[p]
		rt.data.runTx(rt.player, function(tx)
			rt.data.section(tx, "economy").currency.Coins += 10 + tick
			rt.data.section(tx, "_framework").stats.totalEarned += 10 + tick
		end)
	end,
}

-- MERGED-V13 (core-v1.3.0 Phase 2 step 7): MERGED in the shape v1.3 code actually has. No kit
-- writes `_framework` on the income tick (v1.2's `stats` counter moved into `_framework` next to
-- the 200 purchase receipts, and nothing ticks it), and Replication sends module sections only
-- (never `_framework`). So the tick touches `economy` and the snapshot holds the module sections.
variants["MERGED-V13"] = function(players)
	local sync = variants.MERGED(players)
	return function(i, p)
		local d, new = sync(i, p, true)
		return d, new
	end
end
tickFns["MERGED-V13"] = function(p: FakePlayer, tick: number)
	local rt = runtimes[p]
	rt.data.runTx(rt.player, function(tx)
		rt.data.section(tx, "economy").currency.Coins += 10 + tick
	end)
end

-- KITS (core-v1.3.0 Phase 2 step 7): the whole framework through the REAL kit modules, booted
-- with StudWork.test.harness: Items + Rarity + Inventory + Economy (income.source = "owned", so
-- the rate is summed over Inventory.list's frozen views) + Upgrades + Rebirth + Offline. Each
-- player owns ITEMS items (Inventory.add). One tick = h:tick(1): the shared ticker pays income
-- (one ctx.data.update per player), Replication rebuilds every dirty player's state from the
-- frozen section views; then charm-sync's real diff runs on each player's new state.
local kitHarness: any = nil
variants.KITS = function(players)
	Harness.mapGame(nil)
	local ReplicatedStorage = Harness.game:GetService("ReplicatedStorage")
	local StudWork = Harness.require(ReplicatedStorage.Framework)
	local Modules = ReplicatedStorage.Modules
	local function kit(k, m)
		local _ = k -- kit folder (pre-v1.3.1); modules are found by name
		return Harness.require(Modules[m].module)
	end
	local Inventory = kit("Collection", "Inventory")
	local items = {}
	for n = 0, 24 do
		table.insert(items, {
			id = "item" .. n,
			name = "Item " .. n,
			rarity = RARITIES[1 + n % #RARITIES],
			economy = { incomePerSec = 1 + n },
		})
	end
	local h = StudWork.test.harness({
		modules = {
			kit("Collection", "Items"),
			kit("Collection", "Rarity"),
			Inventory,
			kit("Economy", "Economy"),
			kit("Economy", "Upgrades"),
			kit("Economy", "Rebirth"),
			kit("Economy", "Offline"),
		},
		items = items,
		config = {
			Economy = {
				primaryCurrency = "Coins",
				startingCurrency = { Coins = 0 },
				income = { tickSeconds = 1, source = "owned" },
			},
			Inventory = { inventory = { cap = ITEMS + 10 } },
		},
	})
	kitHarness = h
	local inv = h:use(Inventory)
	for i, p in players do
		local player = h:addPlayer({ userId = i })
		for n = 1, ITEMS do
			assert(inv.add(player, "item" .. (n % 25)), "bench: Inventory.add failed")
		end
		h:fire(player, "StateInit") -- the client asked for its state: Replication sends to it
		runtimes[p] = { player = player }
	end
	h:tick(1) -- settle: rates computed, first states built
	local last = {}
	return function(i, p)
		local new = h.fake.synced[runtimes[p].player]
		local d = diff(last[i], new)
		last[i] = new
		return d, new
	end
end
-- the framework tick runs once for all players (first player of the tick only)
tickFns.KITS = function(p: FakePlayer, _tick: number)
	if runtimes[p].player.UserId == 1 then
		kitHarness:tick(1)
	end
end

local ORDER = { "BEFORE", "AFTER", "AFTER-STUB", "MERGED", "MERGED-V13", "KITS" }

local function median(list: { number }): number
	local s = table.clone(list)
	table.sort(s)
	local n = #s
	return if n % 2 == 1 then s[(n + 1) / 2] else (s[n / 2] + s[n / 2 + 1]) / 2
end

local function collectTables(root: any, into: { [any]: boolean })
	if type(root) ~= "table" or into[root] then
		return
	end
	into[root] = true
	for _, v in root do
		collectTables(v, into)
	end
end

local function countFresh(prev: { [any]: boolean }, root: any, counted: { [any]: boolean }): number
	if type(root) ~= "table" or prev[root] or counted[root] then
		return 0
	end
	counted[root] = true
	local n = 1
	for _, v in root do
		n += countFresh(prev, v, counted)
	end
	return n
end

local function runOnce(name: string)
	local players = newPlayers()
	local sync = variants[name](players)
	local tickFn = tickFns[name] or economyTick
	-- warm-up: first sync builds the "init" state (not counted)
	local prevSnaps = {}
	for i, p in players do
		local _, snap = sync(i, p)
		prevSnaps[i] = snap
	end
	local msTicks, kbTicks, freshTicks = {}, {}, {}
	local patchKeys = nil
	local patches, snaps = table.create(PLAYERS), table.create(PLAYERS)
	for tick = 1, TICKS do
		local kbTick = 0
		local t0 = os.clock()
		for i, p in players do
			local kb0 = collectgarbage("count")
			tickFn(p, tick)
			patches[i], snaps[i] = sync(i, p)
			local delta = collectgarbage("count") - kb0
			if delta > 0 then
				kbTick += delta
			end
		end
		local t1 = os.clock()
		table.insert(msTicks, (t1 - t0) * 1000)
		table.insert(kbTicks, kbTick)
		-- exact fresh-table count (outside the timed region)
		local prev = {}
		for i = 1, PLAYERS do
			collectTables(prevSnaps[i], prev)
		end
		local counted, fresh = {}, 0
		for i = 1, PLAYERS do
			fresh += countFresh(prev, snaps[i], counted) + countFresh(prev, patches[i], counted)
			prevSnaps[i] = snaps[i]
		end
		table.insert(freshTicks, fresh)
		local lp = patches[PLAYERS]
		local lastPatch = { data = lp and (lp.data or lp.modules) }
		if patchKeys == nil then
			local keys = {}
			for k in lastPatch.data or {} do
				table.insert(keys, k)
			end
			table.sort(keys)
			patchKeys = table.concat(keys, ",")
		end
	end
	local total = 0
	for _, ms in msTicks do
		total += ms
	end
	return median(msTicks), median(kbTicks), median(freshTicks), patchKeys, total / #msTicks
end

local wanted = {}
for i = 2, #process.args do
	wanted[process.args[i]] = true
end
if next(wanted) ~= nil then
	local filtered = {}
	for _, name in ORDER do
		if wanted[name] then
			table.insert(filtered, name)
		end
	end
	ORDER = filtered
end

local results = {}
for _, name in ORDER do
	results[name] = { ms = {}, kb = {}, fresh = {} }
end
for _ = 1, RUNS do
	for _, name in ORDER do
		local ms, kb, fresh, keys, mean = runOnce(name)
		results[name].mean = results[name].mean or {}
		table.insert(results[name].mean, mean)
		table.insert(results[name].ms, ms)
		table.insert(results[name].kb, kb)
		table.insert(results[name].fresh, fresh)
		results[name].keys = keys
	end
end

print(
	string.format(
		"replication bench: %d players x %d items x %d ticks, median of %d runs (per-run value = median tick)",
		PLAYERS,
		ITEMS,
		TICKS,
		RUNS
	)
)
print("")
print(
	"| variant | ms / tick (median) | spread (min-max of runs) | ms / tick (mean, incl. GC steps) | new tables / tick | KB allocated / tick | data keys in a tick's patch |"
)
print("|---|---:|---:|---:|---:|---:|---|")
for _, name in ORDER do
	local r = results[name]
	local sorted = table.clone(r.ms)
	table.sort(sorted)
	print(
		string.format(
			"| %s | %.3f | %.3f-%.3f | %.3f | %d | %.1f | %s |",
			name,
			median(r.ms),
			sorted[1],
			sorted[#sorted],
			median(r.mean),
			median(r.fresh),
			median(r.kb),
			r.keys or "-"
		)
	)
end
