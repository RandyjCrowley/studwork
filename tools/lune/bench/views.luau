--!nocheck
--[[
	Frozen read view benchmark (core-v1.3.0 Phase 2 step 7, design review H2). Not mapped into any
	Rojo project; run with `tools/bench views` (or `lune run tools/lune/bench/views [runs]`).

	Setup: the real kit modules booted with StudWork.test.harness (Items, Rarity, Inventory,
	Economy), 50 players x 100 items, plus a probe module whose own section holds 100 entries (for
	ScopedData.get). Per-call cost, in nanoseconds, of every frozen read the framework hands out:
	  Inventory.get(p, uid), Inventory.list(p), ScopedData.get(p) (ctx.data.get), Items.get(id)
	  cached   = the shipped path: the view is cached per section version, so a read between
	             commits is a lookup (what every caller pays on a live server)
	  uncached = what each read would cost without the version cache: a fresh frozen deep copy of
	             the same data per call (Freeze.freezeCopy)
	  live     = v1.2 live-server behaviour (no freezing at all, a live reference): the raw lookup
	  rebuild  = the cost of the first read after a commit (the view is rebuilt, sharing every
	             unchanged subtree with the last view, Freeze.freezeShared): one entry changed
	Each figure is the median of `runs` runs (default 5); the spread is min-max over the runs.
]]

local process = require("@lune/process")
local Harness = require("../testkit/harness")

local PLAYERS = 50
local ITEMS = 100
local CALLS = 20000
local RUNS = tonumber(process.args[1]) or 5

Harness.mapGame(nil)
local ReplicatedStorage = Harness.game:GetService("ReplicatedStorage")
local StudWork = Harness.require(ReplicatedStorage.Framework)
local Freeze = Harness.require("packages/framework/shared/Freeze.luau")
local Kits = ReplicatedStorage.Kits
local function kit(k, m)
	return Harness.require(Kits[k][m])
end
local Items = kit("Collection", "Items")
local Inventory = kit("Collection", "Inventory")

local probeCtx
local Probe = StudWork.defineModule({
	name = "Probe",
	version = "1.0.0",
	framework = "^1.3.0",
	data = { key = "probe", version = 1, default = { entries = {} } },
})
local probePart = {
	init = function(ctx)
		probeCtx = ctx
	end,
}

local function median(list)
	local s = table.clone(list)
	table.sort(s)
	local n = #s
	return if n % 2 == 1 then s[(n + 1) / 2] else (s[n / 2] + s[n / 2 + 1]) / 2
end

local function boot()
	local items = {}
	for n = 0, 24 do
		table.insert(
			items,
			{ id = "item" .. n, name = "Item " .. n, rarity = "Common", economy = { incomePerSec = 1 } }
		)
	end
	local h = StudWork.test.harness({
		modules = { Items, kit("Collection", "Rarity"), Inventory, kit("Economy", "Economy"), Probe },
		servers = { Probe = probePart },
		items = items,
		config = {
			Economy = { primaryCurrency = "Coins", income = { tickSeconds = 1, source = "owned" } },
			Inventory = { inventory = { cap = ITEMS + 10 } },
		},
	})
	local inv = h:use(Inventory)
	local players, uids = {}, {}
	for i = 1, PLAYERS do
		local p = h:addPlayer({ userId = i })
		for n = 1, ITEMS do
			local inst = inv.add(p, "item" .. (n % 25))
			uids[i] = uids[i] or {}
			table.insert(uids[i], inst.uid)
		end
		probeCtx.data.update(p, function(section)
			for n = 1, ITEMS do
				section.entries["e" .. n] = { n = n, tag = "x" }
			end
		end)
		players[i] = p
	end
	return h, inv, players, uids
end

-- ns per call of fn(i) over CALLS calls, cycling through players
local function perCall(fn)
	local t0 = os.clock()
	for c = 1, CALLS do
		fn(1 + c % PLAYERS, c)
	end
	return (os.clock() - t0) * 1e9 / CALLS
end

local cases = {}
local function case(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local h, inv, players, uids = boot()
local items = h:use(Items)
-- thawed (plain, unfrozen) copies of the same data: the "live" / "uncached" baselines
local thawInv, thawProbe, thawItem = {}, {}, Freeze.deepCopy(items.get("item3"))
for i, p in players do
	thawInv[i] = Freeze.deepCopy(probeCtx.data.isLoaded(p) and inv.list(p))
	thawProbe[i] = Freeze.deepCopy(probeCtx.data.get(p))
end
local thawInvMap = {}
for i in players do
	thawInvMap[i] = {}
	for _, inst in thawInv[i] do
		thawInvMap[i][inst.uid] = inst
	end
end

case("Inventory.get (cached)", function(i, c)
	return inv.get(players[i], uids[i][1 + c % ITEMS])
end)
case("Inventory.get (uncached: freezeCopy per call)", function(i, c)
	return Freeze.freezeCopy(thawInvMap[i][uids[i][1 + c % ITEMS]])
end)
case("Inventory.get (live reference, v1.2)", function(i, c)
	return thawInvMap[i][uids[i][1 + c % ITEMS]]
end)
case("Inventory.list (cached)", function(i)
	return inv.list(players[i])
end)
case("Inventory.list (uncached: freezeCopy per call)", function(i)
	return Freeze.freezeCopy(thawInv[i])
end)
case("ScopedData.get (cached)", function(i)
	return probeCtx.data.get(players[i])
end)
case("ScopedData.get (uncached: freezeCopy per call)", function(i)
	return Freeze.freezeCopy(thawProbe[i])
end)
case("Items.get (frozen at boot)", function()
	return items.get("item3")
end)
case("Items.get (uncached: freezeCopy per call)", function()
	return Freeze.freezeCopy(thawItem)
end)
case("ScopedData.get after a one-entry commit (rebuild, shared)", function(i, c)
	local p = players[i]
	probeCtx.data.update(p, function(section)
		section.entries.e1.n = c
	end)
	return probeCtx.data.get(p)
end)
case("  the commit alone (ctx.data.update, one entry of 100)", function(i, c)
	probeCtx.data.update(players[i], function(section)
		section.entries.e1.n = -c
	end)
end)

-- sanity: views are frozen and correct
assert(
	table.isfrozen(inv.list(players[1])) and table.isfrozen(inv.list(players[1])[1]),
	"views: Inventory.list is not frozen"
)
assert(table.isfrozen(probeCtx.data.get(players[1]).entries.e2), "views: ScopedData.get is not frozen")

local results = {}
for _, cs in cases do
	results[cs.name] = {}
end
for _ = 1, RUNS do
	for _, cs in cases do
		table.insert(results[cs.name], perCall(cs.fn))
	end
end

print(
	string.format(
		"frozen read views: %d players x %d items, %d calls per case, median of %d runs",
		PLAYERS,
		ITEMS,
		CALLS,
		RUNS
	)
)
print("")
print("| read | ns / call (median) | spread (min-max) |")
print("|---|---:|---:|")
for _, cs in cases do
	local r = results[cs.name]
	local s = table.clone(r)
	table.sort(s)
	print(string.format("| %s | %.0f | %.0f-%.0f |", cs.name, median(r), s[1], s[#s]))
end
