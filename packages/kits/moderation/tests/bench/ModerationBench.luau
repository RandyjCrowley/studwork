--!nocheck
--[[
	Tick-cost benchmark for the moderation kit (Lune; not synced by Rojo, not a spec). The shared
	bench (tools/bench -> tools/lune/bench/replication.luau) has a fixed variant list, so the kit's
	variant lives here and boots the same way as its KITS-ALL variant: 50 players x 100 items x 60
	ticks through the REAL kit modules in StudWork.test.harness, one Leaderboards submit per player
	per tick, h:tick(1), then charm-sync's real diff of every player's replicated state.

	  KITS-ALL       the shared bench's KITS-ALL modules and config (reproduced here)
	  KITS-ALL+MOD   the same plus Admin, Moderation and Reports (defaults, 3 staff players among
	                 the 50: owner, moderator, helper through ServerConfig.Admin.users), the kit's
	                 engine fakes, one channel in the fake TextChatService with every player in it,
	                 two muted players (mute expiry checks run every tick)

	Run from the repo root (budget: KITS-ALL+MOD <= 0.94 ms/tick and <= 1.2 x KITS-ALL):
	  lune run packages/kits/moderation/tests/bench/ModerationBench.luau [runs]
	Prints a markdown table: median ms/tick (per-run value = median tick) and the min-max spread.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local Harness = require("../../../../../tools/lune/testkit/harness")
local Fakes = require("../Fakes")

local PLAYERS = 50
local ITEMS = 100
local TICKS = 60
local RUNS = tonumber(process.args[1]) or 5
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }
local STAFF = { [1] = "owner", [2] = "moderator", [3] = "helper" }

-- charm-sync 0.4.1's real diff (as tools/lune/bench/replication.luau loads it)
local PATCH_DIR = "deps/Packages/_Index/littensy_charm-sync@0.4.1/charm-sync/src/"
local function loadPatch()
	local config = luau.load(fs.readFile(PATCH_DIR .. "config.luau"), { debugName = "config" })()
	local stubs = {
		["../Charm"] = { flags = { strict = false } },
		["./config"] = config,
		["./types"] = {},
		["./validate"] = function() end,
	}
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
local diff = loadPatch().diff

local function boot(withModeration: boolean): (any, any, { any })
	Harness.mapGame(nil)
	local ReplicatedStorage = Harness.game:GetService("ReplicatedStorage")
	local StudWork = Harness.require(ReplicatedStorage.Framework)
	local Modules = ReplicatedStorage.Modules
	local function kit(m)
		return Harness.require(Modules[m].module)
	end
	local Inventory = kit("Inventory")
	local items = {}
	for n = 0, 24 do
		table.insert(items, {
			id = "item" .. n,
			name = "Item " .. n,
			rarity = RARITIES[1 + n % #RARITIES],
			economy = { incomePerSec = 1 + n },
		})
	end
	local modules = {
		kit("Items"),
		kit("Rarity"),
		Inventory,
		kit("Economy"),
		kit("Upgrades"),
		kit("Rebirth"),
		kit("Offline"),
		kit("Streak"),
		kit("Leaderboards"),
		kit("Badges"),
		kit("Notifications"),
		kit("TextFilter"),
	}
	-- KITS-ALL's config (tools/lune/bench/replication.luau bootKits(all = true))
	local config: any = {
		Economy = {
			primaryCurrency = "Coins",
			startingCurrency = { Coins = 0 },
			income = { tickSeconds = 1, source = "owned" },
		},
		Inventory = { inventory = { cap = ITEMS + 10 } },
		Streak = {
			streak = {
				graceHours = 6,
				loopAfter = 7,
				rewards = { { day = 1, amount = 100 }, { day = 3, amount = 500 } },
			},
		},
		Leaderboards = {
			boards = {
				coins = { period = "allTime", source = { kind = "currency" }, topN = 50 },
				dailyTouches = { period = "daily", source = { kind = "submit" }, mode = "sum", topN = 25 },
			},
		},
		Badges = {
			badges = {
				firstCollect = { id = 0, trigger = { kind = "manual" }, toast = true },
				streakThree = { id = 0, trigger = { kind = "streak", atLeast = 3 }, toast = true },
			},
		},
		Notifications = {
			optIn = { minSessionSeconds = 30, minSessions = 0 },
			templates = {
				eggReady = { messageId = "", params = {}, category = "egg" },
				streakEnding = { messageId = "", hoursBefore = 4, minStreak = 3 },
			},
		},
		TextFilter = {},
	}
	local services: any = {
		BadgeService = StudWork.test.fakes.badgeService(),
		TextService = StudWork.test.fakes.textService({}),
		UserService = StudWork.test.fakes.userService(),
	}
	local serverConfig: any = nil
	local tcs: any = nil
	if withModeration then
		for _, m in { "Admin", "Moderation", "Reports" } do
			table.insert(modules, kit(m))
		end
		tcs = Fakes.textChatService()
		services.Players = Fakes.players()
		services.GroupService = Fakes.groupService()
		services.TextChatService = tcs
		serverConfig = { Admin = { users = STAFF } }
	end
	local h = StudWork.test.harness({
		modules = modules,
		items = items,
		config = config,
		serverConfig = serverConfig,
		services = services,
		openCloud = StudWork.test.fakes.openCloud(),
		flags = {
			leaderboardButton = { default = true, description = "the HUD Leaderboards button" },
			newShop = {
				default = false,
				studio = true,
				test = true,
				description = "the redesigned shop screen",
			},
			debugPanel = {
				default = false,
				studio = true,
				test = true,
				testOnly = true,
				description = "developer overlay",
			},
		},
		strings = {
			["ui.close"] = "Done",
			["game.welcome"] = "Welcome back, {name}!",
			["game.leaderboards"] = "Leaderboards",
			["game.debug"] = "debug: {env}",
		},
	})
	local inv = h:use(Inventory)
	local players = {}
	local channel = if tcs then tcs.addChannel("RBXGeneral") else nil
	for i = 1, PLAYERS do
		local player = h:addPlayer({ userId = i })
		for n = 1, ITEMS do
			assert(inv.add(player, "item" .. (n % 25)), "bench: Inventory.add failed")
		end
		if channel then
			channel:AddUserAsync(i)
		end
		h:fire(player, "StateInit")
		players[i] = player
	end
	if withModeration then
		services.Players.setOnline(players)
		local mod = h:use(kit("Moderation"))
		for _, i in { 10, 11 } do
			local ok, status = mod.mute(players[i], { by = "server", seconds = 3600 })
			assert(ok, status)
		end
	end
	local lb = h:use(kit("Leaderboards"))
	h:tick(1) -- settle
	if withModeration then
		local staff = h.fake.synced[players[1]].modules.Admin
		assert(staff and staff.extra.staff.role == "owner", "bench: the owner's staff state is replicated")
		assert(h.fake.synced[players[20]].modules.Admin == nil, "bench: no staff state for players")
	end
	return h, lb, players
end

local function median(list: { number }): number
	local s = table.clone(list)
	table.sort(s)
	local n = #s
	return if n % 2 == 1 then s[(n + 1) / 2] else (s[n / 2] + s[n / 2 + 1]) / 2
end

local function runOnce(withModeration: boolean): number
	local h, lb, players = boot(withModeration)
	local last = {}
	for i, p in players do
		local new = h.fake.synced[p]
		diff(last[i], new)
		last[i] = new
	end
	local ms = {}
	for _ = 1, TICKS do
		local t0 = os.clock()
		for i, p in players do
			lb.submit(p, "dailyTouches", 1)
			if i == 1 then
				h:tick(1)
			end
			local new = h.fake.synced[p]
			diff(last[i], new)
			last[i] = new
		end
		table.insert(ms, (os.clock() - t0) * 1000)
	end
	return median(ms)
end

local VARIANTS = { { "KITS-ALL", false }, { "KITS-ALL+MOD", true } }
local results = {}
for _, v in VARIANTS do
	results[v[1]] = {}
end
for _ = 1, RUNS do
	for _, v in VARIANTS do
		table.insert(results[v[1]], runOnce(v[2]))
	end
end

print(
	string.format(
		"moderation bench: %d players x %d items x %d ticks, median of %d runs (per-run value = median tick)",
		PLAYERS,
		ITEMS,
		TICKS,
		RUNS
	)
)
print("")
print("| variant | ms / tick (median) | spread (min-max of runs) |")
print("|---|---:|---:|")
for _, v in VARIANTS do
	local r = results[v[1]]
	local sorted = table.clone(r)
	table.sort(sorted)
	print(string.format("| %s | %.3f | %.3f-%.3f |", v[1], median(r), sorted[1], sorted[#sorted]))
end
local base, withMod = median(results["KITS-ALL"]), median(results["KITS-ALL+MOD"])
print("")
print(string.format("KITS-ALL+MOD / KITS-ALL = %.2f (budget <= 1.20; absolute <= 0.94 ms)", withMod / base))
