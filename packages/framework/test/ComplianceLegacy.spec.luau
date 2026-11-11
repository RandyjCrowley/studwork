--!nocheck
--[[
	v1.6.0 contract 4 (docs/framework/adopting.md): inside a legacy import transaction (Data sets
	txMeta(tx).legacyImport = "paid" | "free"; set directly here through the internal Data API)
	ctx.compliance.roll / spendForRoll / spendPaid error, and tagPaid(tx) returns "paid:legacy" /
	"legacy" whatever the caller passes. Plus the item-disclosure guards on a source without oddsAt.
]]
local StudWork = require(script.Parent.Parent.shared)
local Harness = require(script.Parent.harness)

local Bank = StudWork.defineModule({
	name = "Bank",
	version = "1.0.0",
	framework = "^1.3.0",
	data = { key = "bank", version = 1, default = { Coins = 100 } },
})
local Loot = StudWork.defineModule({
	name = "Loot",
	version = "1.0.0",
	framework = "^1.3.0",
	dependsOn = { Bank },
	data = { key = "loot", version = 1, default = {} },
})

local ctxs = {}
local samples = 0

local function boot()
	ctxs = {}
	samples = 0
	return Harness.new({
		modules = { Bank, Loot },
		compliance = { paidCurrencies = { "Coins" } },
		servers = {
			Bank = {
				init = function(ctx)
					ctxs.Bank = ctx
					ctx.compliance.registerCurrencySpender("Coins", function(tx, amount)
						local s = ctx.section(tx)
						s.Coins -= amount
						return true
					end)
				end,
			},
			Loot = {
				init = function(ctx)
					ctxs.Loot = ctx
					ctx.compliance.registerRandomSource("Box", {
						odds = function()
							return { tableId = "Box", luck = 1, items = { pebble = 1 } }
						end,
						sample = function()
							samples += 1
							return { itemId = "pebble" }
						end,
						luckDisclosed = true,
					})
				end,
			},
		},
	})
end

local function inImport(h, p, kind, fn)
	local c = ctxs.Loot
	return pcall(c.tx, p, function(tx)
		h.runtime.data.txMeta(tx).legacyImport = kind
		return fn(c, tx)
	end)
end

describe("compliance inside a legacy import", function()
	for _, kind in { "paid", "free" } do
		it(`{kind}: roll, spendForRoll and spendPaid error`, function()
			local h = boot()
			local p = h:addPlayer({ userId = 1 })
			local calls = {
				function(c, tx)
					c.compliance.roll(tx, "Box")
				end,
				function(c, tx)
					c.compliance.spendForRoll(tx, "Coins", 10, "Box")
				end,
				function(c, tx)
					c.compliance.spendPaid(tx, "Coins", 10, "hat")
				end,
			}
			for _, fn in calls do
				local ok, err = inImport(h, p, kind, fn)
				expect(ok).toBe(false)
				expect(tostring(err)).toContain("no rolls or paid spends inside a legacy import")
			end
			expect(samples).toBe(0)
			expect(ctxs.Bank.data.get(p).Coins).toBe(100)
		end)
	end

	it("tagPaid: paid:legacy / legacy, never a caller's tag", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		local _, _, paid = inImport(h, p, "paid", function(c, tx)
			return c.compliance.tagPaid(tx, "paid:CoinPack")
		end)
		local _, _, free = inImport(h, p, "free", function(c, tx)
			return c.compliance.tagPaid(tx, "paid:CoinPack")
		end)
		expect(paid).toBe("paid:legacy")
		expect(free).toBe("legacy")
		-- outside an import: unchanged (prefix stripped)
		local _, plain = ctxs.Loot.tx(p, function(tx)
			return ctxs.Loot.compliance.tagPaid(tx, "paid:CoinPack")
		end)
		expect(plain).toBe("CoinPack")
		-- the same tx outside the import meta still rolls (control)
		local _, out = ctxs.Loot.tx(p, function(tx)
			return table.pack(ctxs.Loot.compliance.roll(tx, "Box"))
		end)
		expect(out[1]).toBe(true)
	end)
end)

describe("item disclosures need oddsAt", function()
	it("a source without oddsAt can't disclose an item; bad opts.item errors", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		local ok, err = pcall(ctxs.Loot.compliance.discloseItem, p, "Box", "egg1", 2)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("oddsAt")
		expect(ctxs.Loot.compliance.disclosedItem(p, "Box", "egg1")).toBeNil()
		local ok2, err2 = pcall(ctxs.Loot.tx, p, function(tx)
			ctxs.Loot.compliance.roll(tx, "Box", 1, { item = string.rep("x", 65) })
		end)
		expect(ok2).toBe(false)
		expect(tostring(err2)).toContain("opts.item")
		-- a free roll with an item key is a label only
		local _, out = ctxs.Loot.tx(p, function(tx)
			return table.pack(ctxs.Loot.compliance.roll(tx, "Box", 5, { item = "egg1" }))
		end)
		expect(out[1]).toBe(true)
	end)
end)
