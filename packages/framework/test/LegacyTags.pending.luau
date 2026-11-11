--!nocheck
--[[
	PENDING (v1.6.0 contract 4 + §4.1): runs only once agent E's Compliance (tagPaid / roll in an
	import tx) and agent D's Shop (legacyPurchases as recorded receipts) are merged; the lead
	renames it to LegacyTags.spec.luau then. On branch C alone, tools/test-sim --pending runs it and
	it fails on those stubs.

	  - items added in an import tx get the source "paid:legacy" (itemTag "paid", the default) or
	    "legacy" (itemTag "free"), whatever source the caller passes
	  - ctx.compliance.roll / spendPaid inside an import tx error (the import fails closed)
	  - a receipt id imported through importLegacy.receipts is a duplicate when Roblox re-delivers it
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Harness = require("packages/framework/test/harness.luau")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Server = require("packages/framework/server/init.luau")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Items = require(Modules:WaitForChild("Items"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Loader = require("packages/framework/server/Loader.luau")

local SRC = { kind = "datastore", name = "PlayerData", key = "Player_{userId}" }
local OLD_AT = 1_700_000_000 - 86400

local function boot(o)
	local Old = StudWork.defineModule({
		name = "Old",
		version = "1.0.0",
		framework = "^1.3.0",
		dependsOn = { Inventory },
		data = { key = "old", version = 1, default = { granted = 0 } },
	})
	local legacy = Harness.legacyStore()
	local h = Harness.new({
		modules = { Items, Inventory, Old },
		servers = {
			Items = Loader.defaultLoadServer(Items, nil, { bindNet = false }),
			Inventory = Loader.defaultLoadServer(Inventory, nil, { bindNet = false }),
			Old = {
				init = function(ctx)
					ctx.data.importLegacy({
						id = "v1-save",
						version = 1,
						source = SRC,
						itemTag = o.itemTag,
						receipts = function(old)
							return old.purchases
						end,
						import = function(tx, old)
							if o.importFn then
								return o.importFn(ctx, tx, old)
							end
							for _, id in old.inventory or {} do
								ctx.depsTx[Inventory].add(tx, id, { source = "paid:forged" })
							end
						end,
					})
					ctx.shop.onProduct("CoinPack", function(tx)
						ctx.section(tx).granted += 1
					end)
				end,
			},
		},
		items = { { id = "pebble", name = "Pebble", rarity = "Common" } },
		config = { Inventory = { inventory = { cap = 10 } } },
		products = { passes = {}, devProducts = { CoinPack = 11 } },
		legacy = legacy,
	})
	return h, legacy
end

local function sources(h, p)
	local out = {}
	for _, inst in h.runtime.data.view(p, "inventory").inventory do
		table.insert(out, inst.source)
	end
	return out
end

describe("legacy import tags (pending E/D)", function()
	it('itemTag "paid" (default): imported items are paid:legacy', function()
		local h, legacy = boot({})
		legacy.set("PlayerData", "Player_1", { inventory = { "pebble" } }, OLD_AT)
		local p = h:addPlayer({ userId = 1 })
		expect(sources(h, p)).toEqual({ "paid:legacy" })
	end)

	it('itemTag "free": imported items are legacy', function()
		local h, legacy = boot({ itemTag = "free" })
		legacy.set("PlayerData", "Player_1", { inventory = { "pebble" } }, OLD_AT)
		local p = h:addPlayer({ userId = 1 })
		expect(sources(h, p)).toEqual({ "legacy" })
	end)

	it("a roll inside an import errors: the import fails closed", function()
		local h, legacy = boot({
			importFn = function(ctx, tx)
				ctx.compliance.roll(tx, "anything")
			end,
		})
		legacy.set("PlayerData", "Player_1", { coins = 1 }, OLD_AT)
		local p = h:addPlayer({ userId = 1 })
		expect(p.kicked).toBe(Server.KICK_LEGACY_IMPORT)
		expect(table.concat(h:warnings(), "\n")).toContain("no rolls or paid spends inside a legacy import")
	end)

	it("an imported receipt id is a duplicate on re-delivery (handler not run)", function()
		local h, legacy = boot({})
		legacy.set("PlayerData", "Player_1", { purchases = { "old-receipt-1" } }, OLD_AT)
		local p = h:addPlayer({ userId = 1 })
		local decision = h:purchase(p, "CoinPack", { purchaseId = "old-receipt-1" })
		expect(decision).toBe("PurchaseGranted")
		expect(h.runtime.data.view(p, "old").granted).toBe(0)
		h:purchase(p, "CoinPack", { purchaseId = "new-receipt" })
		expect(h.runtime.data.view(p, "old").granted).toBe(1)
	end)
end)
