--!nocheck
-- core-v1.3.0 Phase 1 (agent A): the REAL Collection kit modules (Items, Inventory, Rarity) on the
-- module API, booted through the framework harness with only their own parts plus small fake
-- Mail / Economy parts where a test needs one.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Harness = require("packages/framework/test/harness.luau")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local Kits = ReplicatedStorage:WaitForChild("Kits")
local Collection = Kits:WaitForChild("Collection")
local Items = require(Collection:WaitForChild("Items"))
local Inventory = require(Collection:WaitForChild("Inventory"))
local Rarity = require(Collection:WaitForChild("Rarity"))
local Tiers = require(Collection:WaitForChild("Tiers"))
local Mail = require(Kits:WaitForChild("Social"):WaitForChild("Mail"))
local Economy = require(Kits:WaitForChild("Economy"):WaitForChild("Economy"))
local ModuleServers =
	require(ServerScriptService:WaitForChild("Kits"):WaitForChild("Collection"):WaitForChild("ModuleServers"))

local ITEMS = {
	{ id = "pebble", name = "Pebble", rarity = "Common", tags = { "Rock" } },
	{ id = "egg", name = "Egg", rarity = "Rare" },
	{ id = "gem", name = "Gem", rarity = "Epic", tags = { "Rock", "Shiny" } },
}

local function rarityConfig(extra)
	local cfg = {
		rarityTables = {
			Box = { entries = { { itemId = "pebble", weight = 1 } } },
			Robux = { entries = { { itemId = "gem", weight = 1 } }, paid = true },
			-- threshold 2: the 2nd roll after a miss is forced to Epic
			Pity = {
				entries = { { itemId = "pebble", weight = 1e9 }, { itemId = "gem", weight = 1e-9 } },
				pity = { threshold = 2, minTier = "Epic" },
			},
		},
		mutations = { { id = "Gold", name = "Gold", multiplier = 2, weight = 1 } },
	}
	for k, v in extra or {} do
		cfg[k] = v
	end
	return cfg
end

local function parts(extra)
	local s = {
		Items = ModuleServers.loadServer(Items),
		Inventory = ModuleServers.loadServer(Inventory),
		Rarity = ModuleServers.loadServer(Rarity),
	}
	for k, v in extra or {} do
		s[k] = v
	end
	return s
end

local function opts(o)
	local base = {
		modules = { Items, Rarity, Inventory },
		items = ITEMS,
		config = { Inventory = { inventory = { cap = 3 } }, Rarity = rarityConfig() },
	}
	for k, v in o or {} do
		base[k] = v
	end
	base.servers = parts(base.servers)
	return base
end

local function boot(o)
	return Harness.new(opts(o))
end

local function refOf(h, ref)
	return h.runtime.txApis[ref]
end

local function inTx(h, player, fn)
	return h.runtime.data.runTx(player, fn)
end

local function section(h, player, key)
	return h.runtime.data.view(player, key)
end

local function warned(h, needle)
	for _, w in h:warnings() do
		if string.find(w, needle, 1, true) then
			return true
		end
	end
	return false
end

local function bootError(o): string
	local h, err = Harness.boot(opts(o))
	assert(h == nil, "expected a boot error")
	return tostring(err)
end

-- A module that hooks Inventory from the outside (inverted extension, §8) with its own section.
local function shelfModule()
	return StudWork.defineModule({
		name = "Shelf",
		version = "1.0.0",
		framework = "^1.3.0",
		dependsOn = { Inventory },
		data = { key = "shelf", version = 1, default = { removed = {} } },
	})
end

local function shelfPart(state)
	return {
		init = function(ctx)
			state.ctx = ctx
			ctx.depsExt[Inventory].onItemRemoved(function(tx, _player, instance)
				table.insert(ctx.section(tx).removed, instance.uid)
				if instance.itemId == "egg" then
					error("shelf refuses eggs")
				end
			end)
			if state.bonus then
				ctx.depsExt[Inventory].capBonus("bag", function()
					return state.bonus
				end)
			end
		end,
	}
end

-- A game module selling products (purchaseOps of Inventory / Rarity).
local function shopModule()
	return StudWork.defineModule({
		name = "Store",
		version = "1.0.0",
		framework = "^1.3.0",
		dependsOn = { Inventory, Rarity },
	})
end

local PRODUCTS = { devProducts = { GemPack = 5, RobuxRoll = 6 } }

local function receipt(pid, product, user)
	return { PlayerId = user or 1, PurchaseId = pid, ProductId = product, CurrencySpent = 49 }
end

local function storePart()
	return {
		init = function(ctx)
			ctx.shop.onProduct("GemPack", function(tx)
				assert(tx.use(Inventory).addItem("gem", { source = "paid:Forged" }), "inventory full")
			end)
			ctx.shop.onProduct("RobuxRoll", function(tx)
				local def, info = tx.use(Rarity).roll("Robux")
				assert(def and info.ok, info.reason)
			end)
		end,
	}
end

describe("Rarity tiers from config", function()
	it("standard7 by default: tiers() and the theme.rarity contribution", function()
		local h = boot()
		local tiers = h:use(Rarity).tiers()
		expect(#tiers).toBe(7)
		expect(tiers[1].id).toBe("Common")
		expect(tiers[7].id).toBe("Secret")
		expect(table.isfrozen(tiers)).toBe(true)
		expect(h.runtime.theme.rarity.tiers[3].id).toBe("Rare")
		expect(warned(h, "theme.rarity.tiers")).toBe(false)
	end)

	it("a game with 4 custom tiers: rarities, luck and pity follow the list order", function()
		local custom = {
			{ id = "Low", color = "#111111" },
			{ id = "Mid" },
			{ id = "High", soundKey = "r_high" },
			{ id = "Top", glow = "#FFFFFF", glowStrength = 1 },
		}
		local items = {
			{ id = "dust", name = "Dust", rarity = "Low" },
			{ id = "coin", name = "Coin", rarity = "Mid" },
			{ id = "ring", name = "Ring", rarity = "High" },
			{ id = "crown", name = "Crown", rarity = "Top" },
		}
		local h = boot({
			items = items,
			theme = { rarity = { tiers = custom } },
			config = {
				Inventory = { inventory = { cap = 10 } },
				Rarity = {
					tiers = custom,
					rarityTables = {
						Bag = {
							entries = {
								{ itemId = "dust", weight = 1 },
								{ itemId = "coin", weight = 1 },
								{ itemId = "ring", weight = 1 },
								{ itemId = "crown", weight = 1 },
							},
							pity = { threshold = 1, minTier = "Top" }, -- every roll forced to Top
						},
					},
				},
			},
		})
		local rarity = h:use(Rarity)
		local ids = {}
		for _, t in rarity.tiers() do
			table.insert(ids, t.id)
		end
		expect(table.concat(ids, ",")).toBe("Low,Mid,High,Top")
		expect(rarity.tiers()[3].soundKey).toBe("r_high")
		-- default luckMinTier of a custom list = its 3rd tier: luck 3 boosts High and Top only
		local odds = rarity.getOdds("Bag", 3)
		expect(odds.dust).toBeNear(1 / 8, 6)
		expect(odds.crown).toBeNear(3 / 8, 6)
		local p = h:addPlayer({ userId = 1 })
		local def, info = rarity.roll("Bag", p, nil, { grant = true, reason = "test" })
		expect(info.ok).toBe(true)
		expect(info.pity).toBe(true)
		expect(def.id).toBe("crown")
		expect(h:use(Inventory).count(p)).toBe(1)
		expect(rarity.getOddsDetail("Bag").pity.minTier).toBe("Top")
		expect(warned(h, "theme.rarity.tiers")).toBe(false)
	end)

	it("tier names Bronze / Silver / Gold: items are validated against the active list", function()
		local metal = { { id = "Bronze" }, { id = "Silver" }, { id = "Gold" } }
		local items = {
			{ id = "nail", name = "Nail", rarity = "Bronze" },
			{ id = "spoon", name = "Spoon", rarity = "Silver" },
			{ id = "bar", name = "Bar", rarity = "Gold" },
		}
		local config = {
			Rarity = {
				tiers = metal,
				rarityTables = {
					Mine = {
						entries = { { itemId = "nail", weight = 5 }, { itemId = "bar", weight = 1 } },
						luckMinTier = "Gold",
						pity = { threshold = 3, minTier = "Gold" },
					},
				},
			},
		}
		local h = boot({ items = items, config = config })
		expect(h:use(Rarity).tiers()[2].id).toBe("Silver")
		expect(h:use(Rarity).getOdds("Mine", 2).bar).toBeNear(2 / 7, 6)
		expect(h:use(Rarity).getOddsDetail("Mine").pity.items.bar).toBe(1)
		-- config only, no GameConfig.theme: Rarity's theme(config) contributes the list (Phase 2;
		-- this used to warn "theme.rarity.tiers differs" and ask the game to repeat the list)
		expect(warned(h, "theme.rarity.tiers")).toBe(false)
		expect(#h.runtime.theme.rarity.tiers).toBe(3)
		expect(h.runtime.theme.rarity.tiers[1].id).toBe("Bronze")
		expect(h.runtime.theme.rarity.tiers[3].id).toBe("Gold")
		-- an item with a standard7 rarity in a Bronze/Silver/Gold game is a boot error
		local bad = table.clone(items)
		table.insert(bad, { id = "rock", name = "Rock", rarity = "Common" })
		local err = bootError({ items = bad, config = config })
		expect(err).toContain(
			"'rock': rarity 'Common' is not a tier of config.Rarity.tiers (Bronze, Silver, Gold)"
		)
		-- and a table's luckMinTier / a standard7 default game still checks too
		local err2 = bootError({ items = { { id = "x", name = "X", rarity = "Bronze" } } })
		expect(err2).toContain("rarity 'Bronze' is not a tier")
	end)

	it("an invalid tier config is a boot error listing every problem", function()
		expect(bootError({ config = { Rarity = rarityConfig({ tiers = "nope" }) } })).toContain(
			"unknown preset 'nope'"
		)
		local err = bootError({
			items = { { id = "a", name = "A", rarity = "A" } },
			config = {
				Rarity = { tiers = { { id = "A" }, { id = "A", color = "red" }, { id = "B", foo = 1 } } },
			},
		})
		expect(err).toContain("duplicate 'A'")
		expect(err).toContain("color must be '#RRGGBB'")
		expect(err).toContain("foo: unknown field")
		expect(Tiers.resolve(nil)).toBe(Tiers.PRESETS.standard7)
	end)
end)

describe("Items", function()
	it("frozen defs from GameConfig.items, byTag, mutations; no registration after boot", function()
		local h = boot()
		local items = h:use(Items)
		local gem = items.get("gem")
		expect(gem.name).toBe("Gem")
		expect(table.isfrozen(gem)).toBe(true)
		expect(table.isfrozen(gem.tags)).toBe(true)
		expect(items.get("nope")).toBeNil()
		expect(#items.all()).toBe(3)
		expect(items.all()[1].id).toBe("pebble")
		expect(#items.byTag("Rock")).toBe(2)
		expect(#items.byTag("Shiny")).toBe(1)
		expect(#items.byTag("None")).toBe(0)
		local gold = items.mutation("Gold")
		expect(gold.multiplier).toBe(2)
		expect(gold.economy.incomeMultiplier).toBe(2)
		expect(table.isfrozen(gold.economy)).toBe(true)
		expect(#items.mutations()).toBe(1)
		expect(items.incomeOf).toBeNil() -- moved to Economy (Breaking)
		local ok, err = pcall(items.register, { { id = "late", name = "Late" } })
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("items must be declared in GameConfig.items")
	end)

	it("the base ItemDef has no incomePerSec: a top-level one is a boot error", function()
		local items = table.clone(ITEMS)
		table.insert(items, { id = "old", name = "Old", rarity = "Common", incomePerSec = 1 })
		expect(bootError({ items = items })).toContain("incomePerSec")
	end)
end)

describe("Inventory", function()
	it("get / list / count are frozen views cached by section version (N8)", function()
		local h = boot()
		local inv = h:use(Inventory)
		local p = h:addPlayer({ userId = 1 })
		local a = inv.add(p, "pebble", { source = "drop", meta = { note = "hi" } })
		expect(table.isfrozen(a)).toBe(true)
		local got = inv.get(p, a.uid)
		expect(got.meta.note).toBe("hi")
		expect(table.isfrozen(got)).toBe(true)
		expect(table.isfrozen(got.meta)).toBe(true)
		expect(pcall(function()
			got.itemId = "gem"
		end)).toBe(false)
		local l1, l2 = inv.list(p), inv.list(p)
		expect(l1 == l2).toBe(true) -- no copy per read
		expect(table.isfrozen(l1)).toBe(true)
		expect(pcall(table.insert, l1, {})).toBe(false)
		inv.add(p, "egg")
		local l3 = inv.list(p)
		expect(l3 == l1).toBe(false)
		expect(#l3).toBe(2)
		expect(inv.count(p)).toBe(2)
		expect(inv.get(p, "nope")).toBeNil()
		expect(inv.get(h.players[1], a.uid).itemId).toBe("pebble")
	end)

	it("txApi add / remove / list / count inside the caller's tx; cap from config", function()
		local h = boot()
		local tx = refOf(h, Inventory)
		local p = h:addPlayer({ userId = 1 })
		local n, list, added
		expect(inTx(h, p, function(t)
			added = tx.add(t, "pebble", { mutation = "Gold" })
			tx.add(t, "egg")
			n = tx.count(t)
			list = tx.list(t)
			expect(tx.add(t, "gem")).never.toBeNil()
			expect(tx.add(t, "gem")).toBeNil() -- cap 3
			expect(tx.add(t, "nope")).toBeNil()
			expect(tx.remove(t, added.uid, "test")).toBe(true)
			expect(tx.remove(t, added.uid, "test")).toBe(false)
		end)).toBe(true)
		expect(n).toBe(2)
		expect(#list).toBe(2)
		expect(table.isfrozen(list[1])).toBe(true)
		expect(added.mutation).toBe("Gold")
		expect(h:use(Inventory).count(p)).toBe(2)
		expect(h:use(Inventory).cap(p)).toBe(3)
		expect(h:use(Inventory).add(p, "pebble", { mutation = "Nope" })).toBeNil()
	end)

	it("onItemRemoved runs inside the removing tx; a failing hook discards the removal", function()
		local state = {}
		local Shelf = shelfModule()
		local h =
			boot({ modules = { Items, Rarity, Inventory, Shelf }, servers = { Shelf = shelfPart(state) } })
		local inv = h:use(Inventory)
		local removedSignal = {}
		inv.signals.ItemRemoved:Connect(function(_player, instance)
			table.insert(removedSignal, instance.uid)
		end)
		local p = h:addPlayer({ userId = 1 })
		local a = inv.add(p, "pebble")
		local removed = inv.remove(p, a.uid, "test")
		expect(removed.uid).toBe(a.uid)
		expect(section(h, p, "shelf").removed[1]).toBe(a.uid) -- committed with the removal
		expect(removedSignal[1]).toBe(a.uid)
		local egg = inv.add(p, "egg")
		local ok, err = pcall(inv.remove, p, egg.uid, "test")
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("shelf refuses eggs")
		expect(inv.get(p, egg.uid)).never.toBeNil() -- rolled back
		expect(#section(h, p, "shelf").removed).toBe(1)
		expect(#removedSignal).toBe(1)
		-- transfer and txApi.remove run the hooks too
		local b = h:addPlayer({ userId = 2 })
		local c = inv.add(p, "pebble")
		expect(inv.transfer(p, b, c.uid, "gift")).toBe(true)
		expect(section(h, p, "shelf").removed[2]).toBe(c.uid)
		expect(inv.get(b, c.uid).uid).toBe(c.uid)
	end)

	it("capBonus adds to the cap", function()
		local state = { bonus = 2 }
		local h = boot({
			modules = { Items, Rarity, Inventory, shelfModule() },
			servers = { Shelf = shelfPart(state) },
		})
		local inv = h:use(Inventory)
		local p = h:addPlayer({ userId = 1 })
		expect(inv.cap(p)).toBe(5)
		for _ = 1, 5 do
			expect(inv.add(p, "pebble")).never.toBeNil()
		end
		expect(inv.add(p, "pebble")).toBeNil()
		state.bonus = 0 / 0 -- a bad bonus counts as 0
		expect(inv.cap(p)).toBe(3)
	end)

	it("M5: the paid tag is derived from the tx; a caller can't forge one", function()
		local Store = shopModule()
		local h = boot({
			modules = { Items, Rarity, Inventory, Store },
			servers = { Store = storePart() },
			products = PRODUCTS,
		})
		local inv = h:use(Inventory)
		local p = h:addPlayer({ userId = 1 })
		expect(inv.add(p, "pebble", { source = "paid:Fake" })).toBeNil()
		expect(inv.add(p, "pebble", { source = "paidcur:Fake" })).toBeNil()
		expect(warned(h, "paid tags are derived")).toBe(true)
		expect(inv.add(p, "pebble", { source = "drop" }).source).toBe("drop")
		expect(h:receipt(receipt("g1", 5))).toBe("PurchaseGranted")
		local paid
		for _, item in inv.list(p) do
			if item.itemId == "gem" then
				paid = item
			end
		end
		expect(paid.source).toBe("paid:GemPack") -- not the handler's "paid:Forged"
		-- the Robux roll grants with the purchase tag too
		expect(h:receipt(receipt("r1", 6))).toBe("PurchaseGranted")
		expect(inv.count(p)).toBe(3)
	end)

	it("starter items on the first session only", function()
		local h = boot({
			config = {
				Inventory = { inventory = { cap = 3 }, starterItems = { "pebble" } },
				Rarity = rarityConfig(),
			},
		})
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Inventory).count(p)).toBe(1)
		expect(h:use(Inventory).list(p)[1].source).toBe("starter")
		h:rejoin(p)
		expect(h:use(Inventory).count(p)).toBe(1)
		expect(bootError({ config = { Inventory = { starterItems = { "nope" } } } })).toContain(
			"unknown item 'nope'"
		)
	end)

	it("a v1.2 save split by FrameworkSection.V12_MAP loads into the sections unchanged", function()
		local h = boot()
		local v12 = {
			schemaVersion = 7,
			firstJoin = 100,
			lastSeen = 200,
			stats = { sessions = 3 },
			currency = { Coins = 5 },
			inventory = {
				u1 = { uid = "u1", itemId = "gem", acquiredAt = 5, source = "paid:Egg", mutation = "Gold" },
				u2 = { uid = "u2", itemId = "retired", acquiredAt = 6, meta = { note = "kept" } },
				bad = "not an instance",
			},
			pity = { Pity = 1, Box = -2 },
		}
		local p = h:addPlayer({ userId = 1, data = v12 })
		local inv = h:use(Inventory)
		local u1 = inv.get(p, "u1")
		expect(u1.itemId).toBe("gem")
		expect(u1.source).toBe("paid:Egg")
		expect(u1.mutation).toBe("Gold")
		expect(u1.acquiredAt).toBe(5)
		expect(inv.get(p, "u2").meta.note).toBe("kept") -- an item no longer in config is kept
		expect(inv.get(p, "bad")).toBeNil() -- sanitize drops malformed entries
		expect(section(h, p, "rarity").pity.Pity).toBe(1)
		expect(section(h, p, "rarity").pity.Box).toBeNil()
		-- the migrated pity counter is live: the next Pity roll is forced (count 1 = threshold - 1)
		local def, info = h:use(Rarity).roll("Pity", p, nil, { grant = true })
		expect(info.pity).toBe(true)
		expect(def.id).toBe("gem")
		h:removePlayer(p)
		local saved = h:saved(p)
		expect(saved.inventory.inventory.u1.source).toBe("paid:Egg")
		expect(saved._versions.inventory).toBe(1)
		expect(saved._versions.rarity).toBe(1)
		expect(saved.rarity.pity.Pity).toBe(0)
	end)
end)

describe("Inventory gifts and trades", function()
	local function fakeMail(sent, kinds)
		return {
			txApi = {
				send = function(_tx, to, kind, payload, key)
					table.insert(sent, { to = to, kind = kind, payload = payload, key = key })
					return true
				end,
			},
			extensions = {
				registerKind = function(kind, fn)
					kinds[kind] = fn
				end,
			},
		}
	end

	it("sendGift: one tx removes the copy and queues core_gift; no paid copies by mail", function()
		local sent, kinds = {}, {}
		local Store = shopModule()
		local h = boot({
			modules = { Items, Rarity, Inventory, Mail, Store },
			servers = { Mail = fakeMail(sent, kinds), Store = storePart() },
			products = PRODUCTS,
		})
		expect(type(kinds.core_gift)).toBe("function")
		local inv = h:use(Inventory)
		local a = h:addPlayer({ userId = 1 })
		local item = inv.add(a, "pebble", { source = "drop", meta = { note = "for you" } })
		expect(inv.sendGift(a, 99, item.uid, "gift")).toBe(true)
		expect(inv.get(a, item.uid)).toBeNil()
		expect(#sent).toBe(1)
		expect(sent[1].kind).toBe("core_gift")
		expect(sent[1].to).toBe(99)
		expect(sent[1].payload.item.uid).toBe(item.uid)
		expect(string.sub(sent[1].key, 1, 2)).toBe("g-")
		-- paid copies never leave by mail
		h:receipt(receipt("g1", 5))
		local paid = inv.list(a)[1]
		local ok, why = inv.sendGift(a, 99, paid.uid, "gift")
		expect(ok).toBe(false)
		expect(why).toBe("restricted_source")
		expect(select(2, inv.sendGift(a, 1, paid.uid))).toBe("same_player")
		expect(select(2, inv.sendGift(a, -3, paid.uid))).toBe("bad_target")
		expect(select(2, inv.sendGift(a, 99, "nope"))).toBe("not_owned")
		-- the receiver's claim: the same instance, idempotent by uid, full -> held (false)
		local b = h:addPlayer({ userId = 2 })
		local claim = kinds.core_gift
		local result
		inTx(h, b, function(tx)
			result = claim(tx, b, sent[1].payload, { id = "m1", kind = "core_gift" })
		end)
		expect(result).toBe(true)
		local got = inv.get(b, item.uid)
		expect(got.meta.note).toBe("for you")
		expect(got.source).toBe("drop")
		inTx(h, b, function(tx)
			result = claim(tx, b, sent[1].payload, { id = "m1", kind = "core_gift" })
		end)
		expect(result).toBe(true)
		expect(inv.count(b)).toBe(1)
		inv.add(b, "pebble")
		inv.add(b, "pebble")
		local other = { item = { uid = "zz", itemId = "egg", acquiredAt = 1 }, from = 1 }
		inTx(h, b, function(tx)
			result = claim(tx, b, other, { id = "m2", kind = "core_gift" })
		end)
		expect(result).toBe(false)
		expect(inv.get(b, "zz")).toBeNil()
	end)

	it("without Mail: sendGift is mail_off; transfer refuses paid copies for restricted players", function()
		local Store = shopModule()
		local h = boot({
			modules = { Items, Rarity, Inventory, Store },
			servers = { Store = storePart() },
			products = PRODUCTS,
			policy = { [2] = true },
		})
		local inv = h:use(Inventory)
		local a, b = h:addPlayer({ userId = 1 }), h:addPlayer({ userId = 2 })
		local free = inv.add(a, "pebble", { source = "drop" })
		expect(select(2, inv.sendGift(a, 2, free.uid))).toBe("mail_off")
		h:receipt(receipt("g1", 5))
		local paid
		for _, item in inv.list(a) do
			if item.itemId == "gem" then
				paid = item
			end
		end
		local ok, why = inv.transfer(a, b, paid.uid, "gift")
		expect(ok).toBe(false)
		expect(why).toBe("restricted")
		expect(inv.transfer(a, b, free.uid, "gift")).toBe(true)
		expect(inv.get(b, free.uid).source).toBe("drop")
		expect(select(2, inv.transfer(a, b, free.uid, "gift"))).toBe("not_owned")
		expect(select(2, inv.transfer(a, a, paid.uid, "gift"))).toBe("same_player")
	end)
end)

describe("Rarity rolls through Compliance", function()
	it("roll grants with pity kept in the rarity section; full inventory fails before rolling", function()
		local h = boot()
		local rarity, inv = h:use(Rarity), h:use(Inventory)
		local p = h:addPlayer({ userId = 1 })
		local d1, i1 = rarity.roll("Pity", p, nil, { grant = true, reason = "block" })
		expect(i1.ok).toBe(true)
		expect(i1.pity).toBe(false)
		expect(d1.id).toBe("pebble")
		expect(i1.instance.source).toBe("block")
		expect(section(h, p, "rarity").pity.Pity).toBe(1)
		local d2, i2 = rarity.roll("Pity", p, nil, { grant = true })
		expect(i2.pity).toBe(true)
		expect(d2.id).toBe("gem")
		expect(section(h, p, "rarity").pity.Pity).toBe(0)
		local fed = false
		for _, e in h.fake.serverEvents do
			if e.event == "Feedback" and e.args[1].Kind == "item" and e.args[1].Rarity == "Common" then
				fed = true
			end
		end
		expect(fed).toBe(true)
		-- no grant: nothing added
		local _, i3 = rarity.roll("Box", p)
		expect(i3.ok).toBe(true)
		expect(inv.count(p)).toBe(2)
		inv.add(p, "egg")
		local _, full = rarity.roll("Pity", p, nil, { grant = true })
		expect(full.ok).toBe(false)
		expect(full.reason).toBe("inventory_full")
		expect(select(2, rarity.roll("Nope", p)).reason).toBe("unknown_table")
		expect(#h.runtime.compliance.sources()).toBe(3)
	end)

	it("hard rule 11: a paid table rolled with an undisclosed luck errors", function()
		local h = boot()
		local rarity = h:use(Rarity)
		local p = h:addPlayer({ userId = 1 })
		rarity.setLuck(p, 2) -- an all-table boost never reaches a paid table without luckDisclosed
		local _, ok = rarity.roll("Robux", p, nil, { grant = true })
		expect(ok.ok).toBe(true)
		rarity.setLuck(p, 2, "Robux")
		local okCall, err = pcall(rarity.roll, "Robux", p, nil, { grant = true })
		expect(okCall).toBe(false)
		expect(tostring(err)).toContain("hard rule 11")
		expect(rarity.getLuck(p, "Robux")).toBe(2)
	end)

	it("RequestRoll: a paid currency spends + rolls in one tx (paidcur tag); a free one too", function()
		local spent = {}
		local econCtx
		local fakeEconomy = {
			init = function(ctx)
				econCtx = ctx
				ctx.compliance.registerCurrencySpender("Gems", function(tx, amount)
					local s = ctx.section(tx)
					if (s.currency.Gems or 0) < amount then
						return false
					end
					s.currency.Gems -= amount
					return true
				end)
			end,
			txApi = {
				spend = function(tx, amount, reason, currency)
					local s = econCtx.section(tx)
					if (s.currency[currency] or 0) < amount then
						return false
					end
					s.currency[currency] -= amount
					table.insert(spent, reason)
					return true
				end,
			},
		}
		local tables = rarityConfig().rarityTables
		tables.Chest =
			{ entries = { { itemId = "egg", weight = 1 } }, cost = { currency = "Gems", amount = 10 } }
		tables.Crate =
			{ entries = { { itemId = "pebble", weight = 1 } }, cost = { currency = "Coins", amount = 3 } }
		local h = boot({
			modules = { Items, Rarity, Inventory, Economy },
			servers = { Economy = fakeEconomy },
			compliance = { paidCurrencies = { "Gems" } },
			config = {
				Inventory = { inventory = { cap = 3 } },
				Rarity = rarityConfig({ rarityTables = tables }),
			},
		})
		local inv = h:use(Inventory)
		local p = h:addPlayer({ userId = 1 })
		inTx(h, p, function(tx)
			local s = econCtx.section(tx)
			s.currency.Gems = 15
			s.currency.Coins = 4
		end)
		h:fire(p, "RequestRoll", "Chest")
		expect(inv.count(p)).toBe(1)
		expect(inv.list(p)[1].source).toBe("paidcur:Chest")
		expect(section(h, p, "economy").currency.Gems).toBe(5)
		h:fire(p, "RequestRoll", "Chest") -- insufficient: nothing spent, nothing granted
		expect(inv.count(p)).toBe(1)
		expect(section(h, p, "economy").currency.Gems).toBe(5)
		h:fire(p, "RequestRoll", "Crate")
		expect(inv.count(p)).toBe(2)
		expect(section(h, p, "economy").currency.Coins).toBe(1)
		expect(spent[1]).toBe("roll:Crate")
		expect(inv.list(p)[1].source == "roll" or inv.list(p)[2].source == "roll").toBe(true)
		-- full inventory: nothing is spent
		inTx(h, p, function(tx)
			econCtx.section(tx).currency.Coins = 10
		end)
		inv.add(p, "pebble")
		h:fire(p, "RequestRoll", "Crate")
		expect(section(h, p, "economy").currency.Coins).toBe(10)
		h:fire(p, "RequestRoll", "Robux") -- Robux tables are never client-rollable
		expect(inv.count(p)).toBe(3)
	end)

	it("replicates extra.odds for disclosed tables and the tier list", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		h:fire(p, "StateInit")
		local state = h:state(p)
		local extra = state.modules.Rarity.extra
		expect(extra.odds.Robux.paid).toBe(true)
		expect(extra.odds.Robux.items.gem).toBe(1)
		expect(extra.odds.Box).toBeNil() -- free, no cost, no luck disclosure
		expect(extra.tiers[1].id).toBe("Common")
		expect(state.framework.odds.Box ~= nil).toBe(true) -- Compliance discloses every source
		expect(state.modules.Inventory.data.inventory ~= nil).toBe(true)
	end)
end)

-- core-v1.3.0 Phase 2: was the v1.2 adapter test (the deleted Collection adapter).
-- The same behaviours on the real modules: item income = item.economy x mutation.economy (read by
-- the real Economy), and paid copies tagged "paid:<product>" by Inventory's purchase ops.
describe("Collection with the real Economy and purchases", function()
	it("item income comes from item.economy x mutation.economy; purchases tag paid:<product>", function()
		local items = {
			{ id = "pebble", name = "Pebble", rarity = "Common", economy = { incomePerSec = 3 } },
			{ id = "egg", name = "Egg", rarity = "Rare" },
		}
		local Shop = StudWork.defineModule({
			name = "ItemShop",
			version = "1.0.0",
			framework = "^1.3.0",
			dependsOn = { Inventory },
		})
		local h = StudWork.test.harness({
			modules = { Items, Rarity, Inventory, Economy, Shop },
			items = items,
			config = {
				Inventory = { inventory = { cap = 5 } },
				Rarity = rarityConfig(),
				Economy = { income = { tickSeconds = 1, source = "owned" } },
			},
			products = { passes = {}, devProducts = { Egg = 2001, Pack = 2002 } },
			servers = {
				ItemShop = {
					init = function(ctx)
						ctx.shop.onProduct("Egg", function(tx)
							tx.use(Inventory).addItem("egg")
						end)
						ctx.shop.onProduct("Pack", function(tx)
							tx.use(Inventory).addItem("pebble")
						end)
					end,
				},
			},
		})
		local inv, econ = h:use(Inventory), h:use(Economy)
		expect(h:use(Items).get("egg").name).toBe("Egg")
		local p = h:addPlayer({ userId = 1 })
		local fired = {}
		inv.signals.ItemAdded:Connect(function(_p, instance)
			table.insert(fired, instance.uid)
		end)
		-- income: pebble 3/s, a Gold pebble 3 x 2, an egg (no economy table) 0, unknown items 0
		expect(econ.getRate(p)).toBe(0)
		local plain = inv.add(p, "pebble", { source = "drop" })
		expect(econ.getRate(p)).toBe(3)
		inv.add(p, "pebble", { source = "drop", mutation = "Gold" })
		expect(econ.getRate(p)).toBe(3 + 6)
		expect(h:purchase(p, "Egg")).toBe("PurchaseGranted")
		expect(econ.getRate(p)).toBe(3 + 6)
		-- the purchase's copy carries the paid tag the framework derives from the purchase
		local paid
		for _, instance in inv.list(p) do
			if instance.itemId == "egg" then
				paid = instance
			end
		end
		expect(paid.source).toBe("paid:Egg")
		expect(fired[#fired]).toBe(paid.uid) -- ItemAdded fired for it
		expect(h:purchase(p, "Pack")).toBe("PurchaseGranted")
		local packed
		for _, instance in inv.list(p) do
			if instance.source == "paid:Pack" then
				packed = instance
			end
		end
		expect(packed.source).toBe("paid:Pack")
		expect(inv.get(p, packed.uid).itemId).toBe("pebble")
		expect(inv.count(p)).toBe(4)
		expect(#fired).toBe(4)
		expect(inv.get(p, plain.uid).source).toBe("drop")
	end)
end)
