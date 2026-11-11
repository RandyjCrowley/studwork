--!nocheck
--[[
	The override levels (docs/framework/override-levels.md), one case each, through the public
	surfaces only: StudWork.test.harness (real kit modules), the client runtime (StudWork.start on
	the client: the merged theme and GameConfig.client), and the UI kit's pure registries
	(UI.ThemeTokens, UI.HudLayout, UI.Screens: what the UI components and the HUD read).
	  (a) defaults only: the sandbox loop behaves like v1.2 (collect, earn, upgrade, rebirth,
	      paid roll), with the framework-default look and the default HUD
	  (b) a custom 4-tier rarity preset (config.Rarity.tiers only) + a custom theme and sounds
	  (c) the HUD replaced with a custom component, plus a custom screen (registerScreen / open)
	  (d) Collection on, Economy off: items with no income
	  (e) foundation only (no modules)
	  (f) examples/modules/session-leaderboard next to the built-in kits
	Every case also exists as a scratch game generated with tools/new-game (core-v1.3.0 Phase 2,
	P2-C report); the React-mounted HUD / screen path needs the engine and is checked in Studio.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local FrameworkClient = ReplicatedStorage:WaitForChild("FrameworkClient")
local ClientRuntime = require(FrameworkClient:WaitForChild("Runtime"))
local ClientBoot = require(FrameworkClient:WaitForChild("Boot"))
local SharedTheme = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Theme"))
local ThemeTokens = require("packages/ui/ThemeTokens.luau")
local HudLayout = require("packages/ui/HudLayout.luau")
local Screens = require("packages/ui/Screens.luau")

local Kits = ReplicatedStorage:WaitForChild("Kits")
local function kit(k: string, m: string): any
	return require(Kits:WaitForChild(k):WaitForChild(m))
end
local Items = kit("Collection", "Items")
local Rarity = kit("Collection", "Rarity")
local Inventory = kit("Collection", "Inventory")
local Economy = kit("Economy", "Economy")
local Upgrades = kit("Economy", "Upgrades")
local Rebirth = kit("Economy", "Rebirth")

local PRODUCTS = { passes = {}, devProducts = { EggRoll = 4001, CoinPack = 4002 } }

-- the template's items and balance, trimmed to the loop (templates/new-game/src/shared/Config)
local function sandboxItems(withIncome: boolean): { any }
	local function item(id: string, rarity: string, income: number): any
		return {
			id = id,
			name = id,
			rarity = rarity,
			economy = if withIncome then { incomePerSec = income } else nil,
		}
	end
	return {
		item("pebble", "Common", 1),
		item("twig", "Common", 1.5),
		item("acorn", "Uncommon", 3),
		item("crystal", "Rare", 10),
		item("feather", "Epic", 40),
		item("comet", "Legendary", 150),
		item("nebula", "Mythic", 400),
	}
end

local function rarityConfig(): any
	return {
		rarityTables = {
			Block = { entries = { { itemId = "pebble", weight = 50 }, { itemId = "twig", weight = 30 } } },
			Egg = {
				entries = { { itemId = "crystal", weight = 60 }, { itemId = "comet", weight = 40 } },
				paid = true,
			},
		},
		mutations = {},
	}
end

-- The game's own module: the template's EggRoll product (a paid roll inside the receipt tx).
local function gameModule(): (any, any)
	local ref = StudWork.defineModule({
		name = "OverrideGame",
		version = "1.0.0",
		framework = "^1.3.0",
		dependsOn = { Rarity, Inventory },
	})
	local part = {
		init = function(ctx)
			ctx.shop.onProduct("EggRoll", function(tx)
				local def, info = tx.use(Rarity).roll("Egg")
				assert(def and info.ok, info.reason or "roll failed")
			end)
		end,
	}
	return ref, part
end

-- The client side of a GameConfig: StudWork.start on the client (kit client parts are not loaded;
-- only the merged theme and GameConfig.client are read here).
local function startClient(config: any): any
	ClientBoot.attach(nil)
	local rt = ClientRuntime.start(config, nil, {
		loadClient = function()
			return nil
		end,
	})
	return rt
end

local function placed(hudConfig: any, enabled: { [string]: boolean }): any
	local cfg = HudLayout.config(hudConfig)
	local defaults = {
		["Economy.currency"] = {
			slot = "topCenter",
			order = 1,
			module = "Economy",
			component = function() end,
		},
		["Game.nextGoal"] = { slot = "topCenter", order = 2, component = function() end },
		["Social.mailbox"] = { slot = "topCenter", order = 3, module = "Mail", component = function() end },
	}
	return cfg,
		HudLayout.resolve(defaults, {}, cfg.widgets or {}, function(name: string)
			return enabled[name] == true
		end)
end

describe("override levels", function()
	afterEach(function()
		ClientBoot.attach(nil)
	end)

	it("(a) defaults only: the sandbox loop behaves like v1.2", function()
		local ref, part = gameModule()
		local config = {
			Economy = { primaryCurrency = "Coins", income = { tickSeconds = 1, source = "owned" } },
			Rarity = rarityConfig(),
			Upgrades = {
				upgrades = {
					IncomeBoost = {
						name = "Income Boost",
						baseCost = 50,
						costGrowth = 1.6,
						maxLevel = 25,
						effect = "incomeMultiplier",
						perLevel = 0.1,
						resetsOnRebirth = true,
					},
				},
			},
			Rebirth = {
				rebirth = {
					baseCost = 5000,
					costGrowth = 3,
					multiplierPerRebirth = 0.5,
					keepInventory = false,
					resetCurrencies = { "Coins" },
				},
			},
		}
		local modules = { Items, Rarity, Inventory, Economy, Upgrades, Rebirth, ref }
		local h = StudWork.test.harness({
			modules = modules,
			servers = { OverrideGame = part },
			items = sandboxItems(true),
			products = PRODUCTS,
			config = config,
		})
		local p = h:addPlayer({ userId = 1 })
		local econ, inv = h:use(Economy), h:use(Inventory)

		-- collect: the free Block roll grants an item
		local def, info = h:use(Rarity).roll("Block", p, nil, { grant = true, reason = "block" })
		expect(info.ok).toBe(true)
		expect(def.id == "pebble" or def.id == "twig").toBe(true)
		expect(inv.count(p)).toBe(1)

		-- earn: every owned copy earns once per tick (v1.2 RateMath)
		local rate = econ.getRate(p)
		expect(rate).toBe(if def.id == "pebble" then 1 else 1.5)
		h:tick(10)
		expect(econ.balance(p)).toBeNear(rate * 10, 1e-9)

		-- upgrade: v1.2 cost and effect (cost = floor(50 * 1.6^level), +10% per level)
		econ.grant(p, 1000, "test")
		local before = econ.balance(p)
		expect(h:use(Upgrades).purchase(p, "IncomeBoost")).toBe(true)
		expect(econ.balance(p)).toBeNear(before - 50, 1e-9)
		expect(econ.getMultiplier(p)).toBeNear(1.1, 1e-9)

		-- rebirth: x1.5 from now on, Coins and earned items wiped, the upgrade reset
		econ.grant(p, 5000, "test")
		expect(h:use(Rebirth).rebirth(p)).toBe(true)
		expect(h:use(Rebirth).multiplier(p)).toBeNear(1.5, 1e-9)
		expect(econ.balance(p)).toBe(0)
		expect(inv.count(p)).toBe(0)
		expect(h:use(Upgrades).level(p, "IncomeBoost")).toBe(0)

		-- paid roll: the EggRoll receipt grants one paid copy exactly once (re-delivered)
		local decision = h:purchase(p, "EggRoll", { redeliver = true })
		expect(decision).toBe("PurchaseGranted")
		local paid = inv.list(p)
		expect(#paid).toBe(1)
		expect(paid[1].source).toBe("paid:EggRoll")

		-- the look: framework-default theme, 7 standard tiers, the default HUD
		local rt =
			startClient({ gameId = "a", modules = modules, items = sandboxItems(true), config = config })
		local t = ThemeTokens.new(rt.theme)
		expect(t.hex("accent")).toBe(SharedTheme.DEFAULT.colors.accent)
		expect(#rt.theme.rarity.tiers).toBe(7)
		expect(t.sound("coin_tick").id).toBe(SharedTheme.DEFAULT.sounds.coin_tick.id)
		local cfg, slots = placed(nil, { Economy = true })
		expect(cfg.mode).toBe("default")
		expect(slots.topCenter[1].id).toBe("Economy.currency")
	end)

	it("(b) a custom 4-tier rarity preset with a custom theme and sounds", function()
		local tiers = {
			{ id = "Bronze", color = "#CD7F32", soundKey = "tier_bronze" },
			{ id = "Silver", color = "#C0C0C0", soundKey = "tier_silver" },
			{ id = "Gold", color = "#FFD23F", glow = "#FFF2B3", glowStrength = 0.6, soundKey = "tier_gold" },
			{
				id = "Diamond",
				color = "#7DF9FF",
				glow = "#FFFFFF",
				glowStrength = 1,
				soundKey = "tier_diamond",
			},
		}
		local theme = {
			colors = { accent = "#FF5DA2", currency = "#7DF9FF" },
			fonts = { display = "rbxasset://fonts/families/LuckiestGuy.json" },
			metrics = { cornerRadius = 6 },
			sounds = {
				coin_tick = { id = 111, volume = 0.2 },
				tier_bronze = { id = 201 },
				tier_silver = { id = 202 },
				tier_gold = { id = 203, volume = 0.7 },
				tier_diamond = { id = 204, pitch = 1.2 },
			},
		}
		local items = {
			{ id = "coin", name = "Coin", rarity = "Bronze" },
			{ id = "ring", name = "Ring", rarity = "Silver" },
			{ id = "crown", name = "Crown", rarity = "Gold" },
			{ id = "gem", name = "Gem", rarity = "Diamond" },
		}
		local config = {
			Rarity = {
				tiers = tiers, -- tiers only in config.Rarity: the theme hook carries them
				rarityTables = { Chest = { entries = { { itemId = "crown", weight = 1 } } } },
				mutations = {},
			},
		}
		local modules = { Items, Rarity, Inventory }

		-- server: the tiers are the active list, items validate against it, rolls use it
		local h = StudWork.test.harness({ modules = modules, items = items, config = config, theme = theme })
		local p = h:addPlayer({ userId = 2 })
		local ids = {}
		for _, tier in h:use(Rarity).tiers() do
			table.insert(ids, tier.id)
		end
		expect(ids).toEqual({ "Bronze", "Silver", "Gold", "Diamond" })
		local def, info = h:use(Rarity).roll("Chest", p, nil, { grant = true })
		expect(info.ok).toBe(true)
		expect(def.rarity).toBe("Gold")
		-- an item on a tier that isn't in the list is a boot error
		local _, err = StudWork.test.boot({
			modules = modules,
			items = { { id = "x", name = "X", rarity = "Common" } },
			config = config,
		})
		expect(tostring(err)).toContain("Common")

		-- client: theme tokens, the rarity look and the sounds come from the merged theme
		local rt =
			startClient({ gameId = "b", modules = modules, items = items, config = config, theme = theme })
		local t = ThemeTokens.new(rt.theme)
		expect(t.hex("accent")).toBe("#FF5DA2")
		expect(t.hex("currency")).toBe("#7DF9FF")
		expect(t.hex("background")).toBe(SharedTheme.DEFAULT.colors.background) -- untouched token
		expect(t.fontFamily("display")).toBe("rbxasset://fonts/families/LuckiestGuy.json")
		expect(t.metrics.cornerRadius).toBe(6)
		expect(t.tierOrder).toEqual({ Bronze = 1, Silver = 2, Gold = 3, Diamond = 4 })
		expect(t.tier("Gold").color).toBe("#FFD23F")
		expect(t.tier("Gold").glow).toBe("#FFF2B3")
		expect(t.tier("Diamond").glowStrength).toBe(1)
		expect(t.tier("Common")).toBeNil()
		expect(t.sound("coin_tick").id).toBe(111)
		for i, tier in tiers do
			expect(t.sound(t.tier(tier.id).soundKey).id).toBe(200 + i)
		end
		expect(t.sound("tier_gold").volume).toBe(0.7)
	end)

	it("(c) the HUD replaced with a custom component, plus a custom screen", function()
		local function MyHud(_props)
			return nil
		end
		local function MyScoreWidget(_props)
			return nil
		end
		local function QuestsScreen(_props)
			return nil
		end
		local function MyInventory(_props)
			return nil
		end
		local client = {
			hud = {
				layout = MyHud,
				widgets = {
					["Social.mailbox"] = false,
					["Game.score"] = { slot = "topRight", order = 1, component = MyScoreWidget },
				},
			},
		}
		local modules = { Items, Inventory, Economy }
		local items = sandboxItems(true)
		-- the server boots unchanged with a client-only override
		local h = StudWork.test.harness({ modules = modules, items = items, client = client })
		local p = h:addPlayer({ userId = 3 })
		expect(h:use(Economy).balance(p)).toBe(0)

		local rt = startClient({ gameId = "c", modules = modules, items = items, client = client })
		local hud = rt.gameConfig.client.hud
		local cfg, slots = placed(hud, { Economy = true, Mail = true })
		expect(cfg.mode).toBe("custom")
		expect(cfg.layout).toBe(MyHud)
		expect(slots.topRight[1].id).toBe("Game.score")
		expect(slots.topRight[1].spec.component).toBe(MyScoreWidget)
		for _, w in slots.topCenter do
			expect(w.id).never.toBe("Social.mailbox")
		end
		expect(HudLayout.config(false).mode).toBe("off")

		-- screens: register a new one and replace a default one, then open them
		local reg = Screens.new()
		reg:register("Inventory", function() end) -- the UI kit's default
		reg:register("Quests", QuestsScreen)
		reg:register("Inventory", MyInventory)
		expect(reg:names()).toEqual({ "Inventory", "Quests" })
		expect(reg:get("Inventory")).toBe(MyInventory)
		reg:open("Quests", { from = "hud" })
		expect(reg:isOpen("Quests")).toBe(true)
		local open = reg:openList()
		expect(open[1].component).toBe(QuestsScreen)
		expect(open[1].props.from).toBe("hud")
		reg:close("Quests")
		expect(reg:isOpen("Quests")).toBe(false)
		expect(function()
			reg:open("Nope")
		end).toThrow("no screen 'Nope'")
	end)

	it("(d) Collection on, Economy off: items with no income", function()
		local modules = { Items, Rarity, Inventory }
		local h = StudWork.test.harness({
			modules = modules,
			items = sandboxItems(false),
			config = { Rarity = rarityConfig() },
		})
		local p = h:addPlayer({ userId = 4 })
		local def, info = h:use(Rarity).roll("Block", p, nil, { grant = true })
		expect(info.ok).toBe(true)
		expect(h:use(Inventory).count(p)).toBe(1)
		expect(h:use(Inventory).list(p)[1].itemId).toBe(def.id)
		h:tick(30)
		h:removePlayer(p)
		local saved = h:saved(p)
		expect(saved.inventory ~= nil).toBe(true)
		expect(saved.economy).toBeNil() -- no economy section is ever created
		expect(h.runtime.isEnabled(Economy)).toBe(false)
		expect(function()
			h:use(Economy).balance(p) -- never a silent nil (override-levels.md level 4)
		end).toThrow("Economy is not enabled in GameConfig.modules")
		-- an item that still declares income is a boot error naming the field (not a silent no-op)
		local _, err = StudWork.test.boot({
			modules = modules,
			items = sandboxItems(true),
			config = { Rarity = rarityConfig() },
		})
		expect(tostring(err)).toContain("no enabled module declares the item field namespace 'economy'")
		-- the client boots without Economy: no currency widget in the default HUD
		local _, slots = placed(nil, { Items = true, Rarity = true, Inventory = true })
		expect(#slots.topCenter).toBe(1) -- Game.nextGoal only
		expect(slots.topCenter[1].id).toBe("Game.nextGoal")
	end)

	it("(e) foundation only: no modules, the framework alone", function()
		local h = StudWork.test.harness({ modules = {} })
		local p = h:addPlayer({ userId = 6 })
		h:tick(5)
		expect(h.runtime.data.isLoaded(p)).toBe(true)
		h:removePlayer(p)
		local saved = h:saved(p)
		expect(saved._framework.stats.sessions).toBe(1)
		expect(saved._framework.firstJoin ~= nil).toBe(true)
		expect(h.runtime.isEnabled(Economy)).toBe(false)
		local rt = startClient({ gameId = "e", modules = {} })
		expect(ThemeTokens.new(rt.theme).hex("accent")).toBe(SharedTheme.DEFAULT.colors.accent)
	end)

	it("(f) examples/modules/session-leaderboard next to the built-in kits", function()
		local DIR = "examples/modules/session-leaderboard"
		local Leaderboard = require(DIR .. "/module.luau")
		local LeaderboardServer = require(DIR .. "/server/init.luau")
		local modules = { Items, Rarity, Inventory, Economy, Leaderboard }
		local h = StudWork.test.harness({
			modules = modules,
			servers = { SessionLeaderboard = LeaderboardServer },
			items = sandboxItems(true),
			config = {
				Economy = { primaryCurrency = "Coins", income = { tickSeconds = 1, source = "owned" } },
				Rarity = rarityConfig(),
				SessionLeaderboard = { top = 5, tickSeconds = 1 },
			},
		})
		local names = {}
		for _, ref in h.runtime.order do
			table.insert(names, ref.name)
		end
		expect(names).toEqual({ "Items", "Rarity", "Inventory", "Economy", "SessionLeaderboard" })
		local p = h:addPlayer({ userId = 7 })
		local board = h:use(Leaderboard)
		h:use(Inventory).add(p, "crystal")
		h:tick(3)
		-- the real Economy income (10/s from the crystal) reaches the module as points
		expect(board.earned(p)).toBeNear(h:use(Economy).balance(p), 1e-9)
		expect(board.earned(p) > 0).toBe(true)
		h:removePlayer(p)
		expect(h:saved(p).sessionLeaderboard.best > 0).toBe(true)
		-- its theme token reaches the client theme next to the kits' tiers
		local rt = startClient({ gameId = "f", modules = modules, items = sandboxItems(true) })
		expect(#rt.theme.rarity.tiers).toBe(7)
		local tokens = rt.theme.colors
		local found = false
		for k in tokens do
			if string.find(string.lower(k), "leaderboard", 1, true) then
				found = true
			end
		end
		expect(found).toBe(true)
	end)
end)
