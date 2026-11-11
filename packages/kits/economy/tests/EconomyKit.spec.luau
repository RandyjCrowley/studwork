--!nocheck
--[[
	Economy kit (core-v1.3.0 Phase 1): the REAL Economy / Upgrades / Rebirth / Offline modules in
	the multi-server sim (StudWork.test.sim), next to the other real kit modules.
]]

local StudWork = require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"))
local F = StudWork.test.sim

local SANDBOX = "games/_sandbox/default.project.json"

local function loaded(world, server, player): boolean
	return world:advanceUntil(function()
		return server:isLoaded(player)
	end, 30)
end

local function refOf(server, name: string): any
	for _, ref in server.runtime.order do
		if ref.name == name then
			return ref
		end
	end
	return nil
end

local function api(server, name: string): any
	return server.runtime.apis[refOf(server, name)]
end

local function sandbox(userId: number)
	local world = F.world()
	local server = F.gameServer(world, SANDBOX)
	local p = server:join(userId)
	assert(loaded(world, server, p), "load")
	world:advance(1)
	return world, server, p
end

local function record(signal): { any }
	local calls = {}
	signal:Connect(function(...)
		table.insert(calls, table.pack(...))
	end)
	return calls
end

local function income(server, itemId: string): number
	return server.runtime.gameConfigPublic.items.byId(itemId).economy.incomePerSec
end

describe("Economy kit: real modules", function()
	it("are real server parts (built by the kit's own ModuleServers)", function()
		local _, server = sandbox(701)
		local kitServers = server.require("packages/kits/economy/server/ModuleServers.luau")
		for _, name in { "Economy", "Upgrades", "Rebirth", "Offline" } do
			expect(name .. "=" .. tostring(kitServers.isReal(server:ref(name)))).toBe(name .. "=true")
		end
		-- config defaults merged under the game's config
		local configs = server.runtime.configs
		expect(configs.Rebirth.onRebirth.paid).toBe("keep")
		expect(configs.Rebirth.onRebirth.paidCurrency).toBe("wipe")
		expect(configs.Economy.multiplierStacking).toBe("multiply")
		expect(configs.Offline.offline.capSeconds).toBe(8 * 3600)
	end)

	it(
		"income = item.economy.incomePerSec x mutation.economy.incomeMultiplier over displayed copies",
		function()
			local world, server, p = sandbox(702)
			local Economy = api(server, "Economy")
			local Inventory = api(server, "Inventory")
			local Plot = api(server, "Plot")
			local gold = Inventory.add(p, "twig", { source = "drop", mutation = "Gold" })
			local plain = Inventory.add(p, "acorn", { source = "drop" })
			expect(gold ~= nil and plain ~= nil).toBe(true)
			world:advance(0.1)
			expect(Economy.getRate(p)).toBe(0) -- "displayed": nothing on the plot yet
			server.runtime.data.runTx(p, function(tx)
				server.runtime.data.section(tx, "plot").displayed.slot01 = gold.uid
			end)
			Plot.signals.ItemDisplayed:Fire(p, gold.uid, "slot01")
			expect(Economy.getMultiplier(p)).toBe(1)
			expect(Economy.getRate(p)).toBeNear(income(server, "twig") * 2) -- Gold = x2
			server.runtime.data.runTx(p, function(tx)
				server.runtime.data.section(tx, "plot").displayed.slot02 = plain.uid
			end)
			Plot.signals.ItemDisplayed:Fire(p, plain.uid, "slot02")
			expect(Economy.getRate(p)).toBeNear(income(server, "twig") * 2 + income(server, "acorn"))
			-- the rate is paid on the shared ticker and replicated
			local before = Economy.balance(p)
			world:advance(3)
			expect(Economy.balance(p) > before).toBe(true)
			expect(#world:errors()).toBe(0)
		end
	)

	it("an item without an economy table earns nothing (owned source)", function()
		local world = F.world({
			config = {
				items = {
					{ id = "card", name = "Card", rarity = "Common" },
					{ id = "gem", name = "Gem", rarity = "Rare", economy = { incomePerSec = 10 } },
				},
			},
		})
		local server = F.server(world)
		local p = server:join(703)
		assert(loaded(world, server, p), "load")
		expect(server.runtime.gameConfigPublic.items.byId("card").economy).toBeNil()
		server:use("Inventory").add(p, "card", { source = "drop" })
		expect(server:use("Economy").getRate(p)).toBe(0)
		server:use("Inventory").add(p, "gem", { source = "drop" })
		expect(server:use("Economy").getRate(p)).toBe(10)
		expect(#world:errors()).toBe(0)
	end)

	it("Collection works with Economy switched off: boots, rolls, holds items with no economy", function()
		local world = F.world({
			config = {
				modules = { "Items", "Inventory", "Rarity" },
				items = {
					{ id = "card", name = "Card", rarity = "Common" },
					{ id = "badge", name = "Badge", rarity = "Rare" },
				},
				config = {
					Rarity = {
						rarityTables = {
							Pack = {
								entries = {
									{ itemId = "card", weight = 3 },
									{ itemId = "badge", weight = 1 },
								},
							},
						},
					},
				},
			},
		})
		local server = F.server(world)
		expect(server.runtime.state).toBe("running")
		expect(refOf(server, "Economy")).toBeNil()
		local p = server:join(704)
		assert(loaded(world, server, p), "load")
		for _ = 1, 3 do
			local def, info = server:use("Rarity").roll("Pack", p, nil, { grant = true, reason = "test" })
			expect(info.ok).toBe(true)
			expect(def.economy).toBeNil()
		end
		expect(server:use("Inventory").count(p)).toBe(3)
		for _, instance in server:use("Inventory").list(p) do
			expect(server.runtime.gameConfigPublic.items.byId(instance.itemId).economy).toBeNil()
		end
		world:advance(5)
		expect(#world:errors()).toBe(0)
	end)
end)

describe("Economy kit: paid currencies (§14 C3)", function()
	it("api.spend / txApi.spend of a compliance.paidCurrencies currency error", function()
		local world, server, p = sandbox(711)
		local Economy = api(server, "Economy")
		Economy.grant(p, 100, "test")
		local before = Economy.balance(p) -- (+ the day-1 streak reward)
		local ok, err = pcall(Economy.spend, p, 10, "shop")
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("spendForRoll")
		local okTx, errTx = pcall(server.runtime.data.runTx, p, function(tx)
			server.runtime.txApis[refOf(server, "Economy")].spend(tx, 10, "shop")
		end)
		expect(okTx).toBe(false)
		expect(tostring(errTx)).toContain("spendForRoll")
		expect(Economy.balance(p)).toBe(before)
		expect(#world:errors()).toBe(0)
	end)

	it("Economy is the Compliance spender: a Coins-priced roll spends and rolls in one tx", function()
		local world, server, p = sandbox(712)
		local Economy = api(server, "Economy")
		local changed = record(Economy.signals.CurrencyChanged)
		Economy.grant(p, 1000, "test")
		local before = Economy.balance(p)
		local count = api(server, "Inventory").count(p)
		server:remote("RequestRoll", p, "Chest")
		world:advance(0.5)
		expect(Economy.balance(p)).toBe(before - 250)
		expect(api(server, "Inventory").count(p)).toBe(count + 1)
		local spent = false
		for _, c in changed do
			if c[4] == -250 and c[5] == "roll" then
				spent = true
			end
		end
		expect(spent).toBe(true)
		expect(#world:errors()).toBe(0)
	end)
end)

describe("Economy kit: Upgrades and Rebirth", function()
	it("an upgrade priced in a paid currency is bought in one tx and feeds the multiplier", function()
		local world, server, p = sandbox(721)
		local Economy, Upgrades = api(server, "Economy"), api(server, "Upgrades")
		local bought = record(Upgrades.signals.UpgradePurchased)
		local start = Economy.balance(p) -- the day-1 streak reward
		expect(start >= 50 and start < 150).toBe(true)
		expect(Upgrades.cost(p, "IncomeBoost")).toBe(50)
		expect(Upgrades.purchase(p, "IncomeBoost")).toBe(true)
		expect(Upgrades.level(p, "IncomeBoost")).toBe(1)
		expect(Economy.balance(p)).toBe(start - 50)
		expect(Economy.getMultiplier(p)).toBeNear(1.1)
		world:advance(0.1)
		expect(#bought).toBe(1)
		expect(bought[1][2]).toBe("IncomeBoost")
		expect(bought[1][3]).toBe(1)
		local ok, reason = Upgrades.purchase(p, "BiggerBag") -- costs 100
		expect(ok).toBe(false)
		expect(reason).toBe("cannot_afford")
		expect(Upgrades.level(p, "BiggerBag")).toBe(0)
		expect(Economy.balance(p)).toBe(start - 50)
		Economy.grant(p, 1000, "test")
		-- Inventory.cap reads Upgrades.level through the adapter
		local cap = api(server, "Inventory").cap(p)
		expect(Upgrades.purchase(p, "BiggerBag")).toBe(true)
		expect(api(server, "Inventory").cap(p)).toBe(cap + 5)
		expect(Upgrades.purchase(p, "NoSuchUpgrade")).toBe(false)
		expect(#world:errors()).toBe(0)
	end)

	it("rebirth: keeps paid:, wipes paidcur: and earned copies, resets upgrades + plot, x1.5", function()
		local world, server, p = sandbox(722)
		local Economy, Upgrades = api(server, "Economy"), api(server, "Upgrades")
		local Rebirth, Inventory = api(server, "Rebirth"), api(server, "Inventory")
		local rebirthed = record(Rebirth.signals.Rebirthed)
		local heard = server:heard("Rebirth.Rebirthed") -- the sim records every module signal
		Economy.grant(p, 400, "test")
		assert(Upgrades.purchase(p, "IncomeBoost") and Upgrades.purchase(p, "BiggerBag"), "upgrades")
		for _, item in Inventory.list(p) do
			Inventory.remove(p, item.uid, "test") -- start from an empty inventory
		end
		-- Seed the save directly (a copy bought / rolled earlier): the real Inventory refuses a
		-- caller-supplied paid:/paidcur: source outside a purchase or Compliance roll (M5), and the
		-- sandbox's product ids are 0, so the sim can't route a receipt to EggRoll.
		local now = os.time()
		local paid = { uid = "seed-paid", itemId = "crystal", source = "paid:EggRoll", acquiredAt = now }
		local paidcur = { uid = "seed-paidcur", itemId = "acorn", source = "paidcur:Chest", acquiredAt = now }
		local earned = Inventory.add(p, "twig", { source = "drop" })
		server.runtime.data.runTx(p, function(tx)
			local inv = server.runtime.data.section(tx, "inventory").inventory
			inv[paid.uid] = table.clone(paid)
			inv[paidcur.uid] = table.clone(paidcur)
			server.runtime.data.section(tx, "plot").displayed.slot01 = paid.uid
		end)
		expect(Rebirth.canRebirth(p)).toBe(false)
		expect(Rebirth.rebirth(p)).toBe(false)
		Economy.grant(p, 5000, "test")
		expect(Rebirth.cost(p)).toBe(5000)
		expect(Rebirth.canRebirth(p)).toBe(true)
		expect(Rebirth.rebirth(p)).toBe(true)
		world:advance(0.5)
		expect(Inventory.get(p, paid.uid) ~= nil).toBe(true)
		expect(Inventory.get(p, paidcur.uid)).toBeNil()
		expect(Inventory.get(p, earned.uid)).toBeNil()
		expect(Upgrades.level(p, "IncomeBoost")).toBe(0) -- resetsOnRebirth = true
		expect(Upgrades.level(p, "BiggerBag")).toBe(1) -- resetsOnRebirth = false
		expect(Economy.balance(p)).toBe(0) -- Coins reset to startingCurrency
		expect(next(api(server, "Plot").displayed(p))).toBeNil() -- bridged Plot's v1.2 reset step
		expect(Rebirth.multiplier(p)).toBe(1.5)
		expect(Economy.getMultiplier(p)).toBe(1.5)
		expect(#rebirthed).toBe(1)
		expect(rebirthed[1][2]).toBe(1)
		expect(heard:count()).toBe(1) -- fired once for every listener (Plot re-renders on it)
		expect(#world:errors()).toBe(0)
	end)
end)
