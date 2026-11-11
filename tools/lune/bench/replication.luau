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

	Usage: lune run tools/lune/bench/replication [runs]   (default 5 runs; prints a markdown table)
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local Harness = require("../testkit/harness")
local Snapshot = Harness.require("packages/framework/server/Replication/Snapshot.luau")
local SectionCache = Harness.require("packages/kits/compat/SectionCache.luau")
local Transaction = Harness.require("packages/core/server/Data/Transaction.luau")

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

-- MERGED (added by the lead after merging A + D): the tick goes through the REAL Data.update
-- transaction (Data/Transaction.luau: copy-on-read proxy, deep-equal check, per-section
-- versions) and Replication reads the real Transaction.version. Measures both halves together.
local txStates: { [any]: any } = {}
variants.MERGED = function(players)
	local last, caches = {}, {}
	local shared = { activeEvents = Snapshot.copy(SHARED.activeEvents) }
	for i, p in players do
		caches[i] = SectionCache.new()
		txStates[p] = Transaction.newState()
	end
	local function sync(i, p)
		local state = txStates[p]
		local dataCopy = caches[i]:build(p.data, function(s)
			return Transaction.version(state, s)
		end)
		local new = Snapshot.build(p.data, EXTRA, shared, { dataCopy = dataCopy, sanitized = true })
		local d = diff(last[i], new)
		last[i] = new
		return d, new
	end
	return sync
end
local tickFns = {
	MERGED = function(p: FakePlayer, tick: number)
		Transaction.run(txStates[p], p.data, function(d)
			d.currency.Coins += 10 + tick
			d.stats.totalEarned += 10 + tick
		end)
	end,
}

local ORDER = { "BEFORE", "AFTER", "AFTER-STUB", "MERGED" }

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
		local lastPatch = { data = patches[PLAYERS] and patches[PLAYERS].data }
		if patchKeys == nil then
			local keys = {}
			for k in lastPatch.data or {} do
				table.insert(keys, k)
			end
			table.sort(keys)
			patchKeys = table.concat(keys, ",")
		end
	end
	return median(msTicks), median(kbTicks), median(freshTicks), patchKeys
end

local results = {}
for _, name in ORDER do
	results[name] = { ms = {}, kb = {}, fresh = {} }
end
for _ = 1, RUNS do
	for _, name in ORDER do
		local ms, kb, fresh, keys = runOnce(name)
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
print("| variant | ms / tick | new tables / tick | KB allocated / tick | data keys in a tick's patch |")
print("|---|---:|---:|---:|---|")
for _, name in ORDER do
	local r = results[name]
	print(
		string.format(
			"| %s | %.3f | %d | %.1f | %s |",
			name,
			median(r.ms),
			median(r.fresh),
			median(r.kb),
			r.keys or "-"
		)
	)
end
