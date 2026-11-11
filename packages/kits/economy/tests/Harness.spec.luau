--!nocheck
--[[
	Economy kit modules on the plain StudWork test harness (no Collection): the
	real server parts from ModuleServers, a tiny third-party module that rolls with a paid
	currency through compliance.spendForRoll, and the config guardrails.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Harness = require("packages/framework/test/harness.luau")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local ModuleServers = require("packages/kits/economy/server/ModuleServers.luau")

local Kit = ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Economy")
local Economy = require(Kit:WaitForChild("Economy"))
local Upgrades = require(Kit:WaitForChild("Upgrades"))
local Rebirth = require(Kit:WaitForChild("Rebirth"))
local Offline = require(Kit:WaitForChild("Offline"))

local Box = StudWork.defineModule({
	name = "Box",
	version = "1.0.0",
	framework = "^1.3.0",
	dependsOn = { Economy },
})

local function boxServer()
	local ctx
	return {
		init = function(c)
			ctx = c
			ctx.compliance.registerRandomSource("box", {
				odds = function()
					return { entries = { { itemId = "prize", chance = 1 } }, luck = 1 }
				end,
				sample = function()
					return { itemId = "prize" }
				end,
				luckDisclosed = false,
			})
		end,
		api = {
			buy = function(player)
				local result
				ctx.tx(player, function(tx)
					result = table.pack(ctx.compliance.spendForRoll(tx, "Gems", 10, "box"))
				end)
				return table.unpack(result, 1, result.n)
			end,
		},
	}
end

local function servers()
	local out = { Box = boxServer() }
	for _, name in ModuleServers.names do
		out[name] = ModuleServers.loadServer({ name = name, server = name })
	end
	return out
end

local function boot(extra)
	local opts = {
		modules = { Economy, Upgrades, Rebirth, Offline, Box },
		servers = servers(),
		compliance = { paidCurrencies = { "Gems" } },
		config = {
			Economy = { startingCurrency = { Coins = 0, Gems = 0 } },
			Upgrades = {
				upgrades = {
					Boost = {
						baseCost = 10,
						costGrowth = 2,
						maxLevel = 2,
						effect = "incomeMultiplier",
						perLevel = 0.5,
						currency = "Gems",
					},
				},
			},
		},
	}
	for k, v in extra or {} do
		opts[k] = v
	end
	return Harness.new(opts)
end

describe("Economy kit on the StudWork harness (no bridge)", function()
	it("boots standalone; signals on api.signals; grant / balance / txApi", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		local economy = h:use(Economy)
		local changes = {}
		economy.signals.CurrencyChanged:Connect(function(...)
			table.insert(changes, table.pack(...))
		end)
		expect(economy.primaryCurrency()).toBe("Coins")
		expect(economy.balance(p, "Gems")).toBe(0)
		expect(economy.grant(p, 25, "quest")).toBe(true)
		expect(economy.grant(p, -1, "quest")).toBe(false)
		expect(economy.grant(p, 5, "quest", "Unknown")).toBe(false)
		expect(economy.balance(p)).toBe(25)
		expect(#changes).toBe(1)
		expect(changes[1][2]).toBe("Coins")
		expect(changes[1][4]).toBe(25)
		expect(changes[1][5]).toBe("quest")
		expect(economy.spend(p, 10, "shop")).toBe(true)
		expect(economy.spend(p, 100, "shop")).toBe(false)
		expect(economy.balance(p)).toBe(15)
		-- the section is Economy's own, saved under its data key
		h:removePlayer(p)
		expect(h:saved(p).economy.currency.Coins).toBe(15)
	end)

	it("spend of a paid currency errors; compliance.spendForRoll spends it through Economy", function()
		local h = boot()
		local p = h:addPlayer({ userId = 2 })
		local economy = h:use(Economy)
		economy.grant(p, 15, "test", "Gems")
		local ok, err = pcall(economy.spend, p, 1, "x", "Gems")
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("compliance.spendForRoll")
		expect(economy.balance(p, "Gems")).toBe(15)
		local rolled, outcome = h:use(Box).buy(p)
		expect(rolled).toBe(true)
		expect(outcome.itemId).toBe("prize")
		expect(economy.balance(p, "Gems")).toBe(5)
		local again, _, reason = h:use(Box).buy(p)
		expect(again).toBe(false)
		expect(reason).toBe("insufficient")
		expect(economy.balance(p, "Gems")).toBe(5)
	end)

	it("Upgrades: a non-random sink in a paid currency; the level and the spend commit together", function()
		local h = boot()
		local p = h:addPlayer({ userId = 3 })
		local economy, upgrades = h:use(Economy), h:use(Upgrades)
		economy.grant(p, 30, "test", "Gems")
		economy.addIncomeSource(p, "job", 2)
		expect(economy.getRate(p)).toBe(2)
		expect(upgrades.purchase(p, "Boost")).toBe(true)
		expect(economy.balance(p, "Gems")).toBe(20)
		expect(economy.getRate(p)).toBe(3) -- x1.5
		expect(upgrades.purchase(p, "Boost")).toBe(true) -- costs 20
		expect(economy.balance(p, "Gems")).toBe(0)
		local ok, reason = upgrades.purchase(p, "Boost")
		expect(ok).toBe(false)
		expect(reason).toBe("maxed")
		expect(economy.getRate(p)).toBe(4)
		h:tick(3)
		expect(economy.balance(p)).toBe(12) -- 4/s on the shared ticker
	end)

	it("Rebirth: one tx, resetStep inside it, multiplier through Economy; Upgrades reset", function()
		local h = boot({
			config = {
				Rebirth = {
					rebirth = {
						baseCost = 100,
						costGrowth = 2,
						multiplierPerRebirth = 1,
						keepInventory = false,
					},
				},
				Upgrades = {
					upgrades = {
						Boost = {
							baseCost = 10,
							costGrowth = 1,
							maxLevel = 5,
							effect = "incomeMultiplier",
							perLevel = 1,
						},
					},
				},
			},
		})
		local p = h:addPlayer({ userId = 4 })
		local economy, rebirth, upgrades = h:use(Economy), h:use(Rebirth), h:use(Upgrades)
		local seen = {}
		h.runtime.exts[Rebirth].resetStep("test", function(tx, player)
			table.insert(seen, { player = player, valid = h.runtime.data.isTxHandle(tx) })
		end)
		economy.grant(p, 110, "test")
		expect(upgrades.purchase(p, "Boost")).toBe(true)
		expect(economy.getMultiplier(p)).toBe(2)
		expect(rebirth.canRebirth(p)).toBe(true)
		expect(rebirth.rebirth(p)).toBe(true)
		expect(#seen).toBe(1)
		expect(seen[1].valid).toBe(true)
		expect(economy.balance(p)).toBe(0)
		expect(upgrades.level(p, "Boost")).toBe(0)
		expect(rebirth.multiplier(p)).toBe(2)
		expect(economy.getMultiplier(p)).toBe(2) -- rebirth x2, upgrade reset
		expect(rebirth.cost(p)).toBe(200)
		expect(rebirth.rebirth(p)).toBe(false)
	end)

	it("Offline: defaults are the shipped values; config.Offline overrides them", function()
		local h = boot()
		expect(h.runtime.configs.Offline.offline.capSeconds).toBe(8 * 3600)
		expect(h.runtime.configs.Offline.offline.minSeconds).toBe(60)
		expect(h.runtime.configs.Offline.offline.payoutFraction).toBe(0.5)
		expect(h.runtime.configs.Offline.offline.autoPay).toBe(true)
		local h2 = boot({
			config = { Offline = { offline = { autoPay = false, capSeconds = 600 } } },
		})
		expect(h2.runtime.configs.Offline.offline.autoPay).toBe(false)
		expect(h2.runtime.configs.Offline.offline.capSeconds).toBe(600)
		expect(h2.runtime.configs.Offline.offline.minSeconds).toBe(60)
	end)

	it('config can\'t make Robux copies wipeable on rebirth (onRebirth.paid = "wipe" fails boot)', function()
		local h, err = Harness.boot({
			modules = { Economy, Rebirth },
			servers = servers(),
			config = { Rebirth = { onRebirth = { paid = "wipe" } } },
		})
		expect(h).toBeNil()
		expect(tostring(err)).toContain("onRebirth.paid")
		local ok = Harness.boot({
			modules = { Economy, Rebirth },
			servers = servers(),
			config = { Rebirth = { onRebirth = { paidCurrency = "keep", earned = "keep" } } },
		})
		expect(ok ~= nil).toBe(true)
	end)
end)
