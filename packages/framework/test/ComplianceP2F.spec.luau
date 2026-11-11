--!nocheck
--[[
	Final review findings 4, 5/7 and 8 (core-v1.3.0 Phase 2, P2-F), on the framework Compliance:
	  4  a paid roll (purchase or spendForRoll) needs the source's odds sent to the client, at any
	     luck ("odds_not_disclosed"; inside a purchase tx.retryLater, no grant, no record).
	  5/7 ctx.compliance.spendPaid: any module spends a paid currency on a NON-random good; a roll
	     later in the same tx is a paid roll (policy, luck rule, paidcur tag).
	  8  tagPaid can't return a caller-forged "paid:" / "paidcur:" tag outside a paid tx.
	Fixture: the reviewer's repro (review/repro-compliance.spec.luau) plus a Stranger shop.
]]
local StudWork = require(script.Parent.Parent.shared)
local Harness = require(script.Parent.harness)

local def = StudWork.defineModule

local function mod(name, extra)
	local spec = { name = name, version = "1.0.0", framework = "^1.3.0" }
	for k, v in extra or {} do
		spec[k] = v
	end
	return def(spec)
end

-- A currency module: Coins (paid, sold for Robux) and Gems (free).
local Bank = mod("Bank", { data = { key = "bank", version = 1, default = { Coins = 100, Gems = 0 } } })
-- A random-source module: "Box" (free table) and "Egg"; purchase ops grant / roll.
local Loot = mod("Loot", {
	dependsOn = { Bank },
	data = { key = "loot", version = 1, default = { items = {}, pity = 0 } },
})
-- The game: sells products using both.
local Game = mod(
	"Game",
	{ dependsOn = { Bank, Loot }, data = { key = "game", version = 1, default = { bought = 0 } } }
)
local Stranger = mod("Stranger", { data = { key = "stranger", version = 1, default = {} } })

local ctxs = {}
local nextOutcome = "pebble"
local sampleCalls = 0

local function servers(gameHandlers)
	return {
		Bank = {
			init = function(ctx)
				ctxs.Bank = ctx
				ctx.compliance.registerCurrencySpender("Coins", function(tx, amount)
					local s = ctx.section(tx)
					if s.Coins < amount then
						return false
					end
					s.Coins -= amount
					return true
				end)
			end,
			purchaseOps = {
				grant = function(tx, amount)
					local s = ctxs.Bank.section(tx)
					s.Coins += amount
					return true
				end,
			},
		},
		Loot = {
			init = function(ctx)
				ctxs.Loot = ctx
				for _, id in { "Box", "Egg" } do
					ctx.compliance.registerRandomSource(id, {
						odds = function(player)
							return {
								tableId = id,
								luck = ctx.data.isLoaded(player) and (ctxs.luck or 1) or 1,
								items = { pebble = 1 },
							}
						end,
						sample = function(_player, luck, tx)
							sampleCalls += 1
							local s = ctx.section(tx)
							s.pity += 1
							if nextOutcome == nil then
								return nil -- an empty table / no outcome
							end
							return { itemId = nextOutcome, luck = luck }
						end,
						luckDisclosed = id == "Box",
					})
				end
			end,
			purchaseOps = {
				roll = function(tx, sourceId, luck)
					local c = ctxs.Loot
					local ok, outcome, reason = c.compliance.roll(tx, sourceId, luck)
					if not ok then
						return nil, reason
					end
					local s = c.section(tx)
					table.insert(s.items, { id = outcome.itemId, source = c.compliance.tagPaid(tx, "drop") })
					return outcome
				end,
				addItem = function(tx, itemId)
					local c = ctxs.Loot
					table.insert(
						c.section(tx).items,
						{ id = itemId, source = c.compliance.tagPaid(tx, "drop") }
					)
					return true
				end,
			},
			api = {
				buyBox = function(player)
					local c = ctxs.Loot
					return c.tx(player, function(tx)
						local ok, outcome, reason = c.compliance.spendForRoll(tx, "Coins", 30, "Box")
						if not ok then
							return reason
						end
						table.insert(
							c.section(tx).items,
							{ id = outcome.itemId, source = c.compliance.tagPaid(tx, "drop") }
						)
						return outcome.itemId
					end)
				end,
				freeBox = function(player)
					local c = ctxs.Loot
					return c.tx(player, function(tx)
						local ok, outcome = c.compliance.roll(tx, "Box", 5) -- free: any luck
						table.insert(
							c.section(tx).items,
							{ id = outcome.itemId, source = c.compliance.tagPaid(tx, "reward") }
						)
						return ok
					end)
				end,
			},
		},
		Game = {
			init = function(ctx)
				ctxs.Game = ctx
				for product, fn in gameHandlers or {} do
					ctx.shop.onProduct(product, fn)
				end
			end,
		},
		Stranger = {
			init = function(ctx)
				ctxs.Stranger = ctx
			end,
			api = {
				-- a third-party module with no dependency on Bank: a non-random good priced in
				-- the paid currency Coins
				buyHat = function(player, price)
					local c = ctxs.Stranger
					local result
					local committed = c.tx(player, function(tx)
						local ok, reason = c.compliance.spendPaid(tx, "Coins", price, "hat")
						if not ok then
							result = reason
							return
						end
						c.section(tx).hats = (c.section(tx).hats or 0) + 1
						result = c.compliance.tagPaid(tx, "shop")
					end)
					return committed, result
				end,
			},
		},
	}
end

local PRODUCTS =
	{ passes = { Vip = 77, Soon = 0 }, devProducts = { CoinPack = 11, EggRoll = 22, Broken = 33, Later = 0 } }

local function boot(gameHandlers, extra)
	nextOutcome = "pebble"
	sampleCalls = 0
	ctxs = {}
	local opts = {
		modules = { Bank, Loot, Game, Stranger },
		servers = servers(gameHandlers),
		products = PRODUCTS,
		compliance = { paidCurrencies = { "Coins" } },
	}
	for k, v in extra or {} do
		opts[k] = v
	end
	return Harness.new(opts)
end

local function receipt(pid, product, user)
	return { PlayerId = user or 1, PurchaseId = pid, ProductId = product, CurrencySpent = 49 }
end

local function coins(p)
	return ctxs.Bank.data.get(p).Coins
end

describe("paid rolls need disclosed odds (final review 4)", function()
	it("a purchase roll on a source never disclosed to the client is retried, not granted", function()
		local h = boot({
			EggRoll = function(tx)
				assert(tx.use(Loot).roll("Egg"))
			end,
		})
		local p = h:addPlayer({ userId = 1, sync = false }) -- the client never got its odds
		expect(ctxs.Loot.compliance.disclosed(p, "Egg")).toBeNil()
		local res = h:receipt(receipt("e1", 22))
		expect(res).toBe("NotProcessedYet")
		expect(sampleCalls).toBe(0)
		expect(#ctxs.Loot.data.get(p).items).toBe(0)
	end)

	it("spendForRoll outside a purchase returns odds_not_disclosed and spends nothing", function()
		local h = boot({})
		local p = h:addPlayer({ userId = 1, sync = false })
		local committed, result = ctxs.Loot.tx(p, function(tx)
			return table.pack(ctxs.Loot.compliance.spendForRoll(tx, "Coins", 30, "Box"))
		end)
		expect(committed).toBe(true)
		expect(result[1]).toBe(false)
		expect(result[3]).toBe("odds_not_disclosed")
		expect(coins(p)).toBe(100)
		expect(sampleCalls).toBe(0)
	end)

	it("once the client was sent the odds the same purchase grants (luck 1)", function()
		local h = boot({
			EggRoll = function(tx)
				assert(tx.use(Loot).roll("Egg"))
			end,
		})
		local p = h:addPlayer({ userId = 1 })
		expect(ctxs.Loot.compliance.disclosed(p, "Egg")).never.toBeNil()
		expect(h:receipt(receipt("e2", 22))).toBe("PurchaseGranted")
		expect(#ctxs.Loot.data.get(p).items).toBe(1)
	end)
end)

describe("compliance.spendPaid (final review 5/7)", function()
	it("a third-party module buys a non-random good with a paid currency", function()
		local h = boot({})
		local p = h:addPlayer({ userId = 1 })
		local committed, tag = h:use(Stranger).buyHat(p, 40)
		expect(committed).toBe(true)
		expect(tag).toBe("paidcur:Coins")
		expect(coins(p)).toBe(60)
		expect(ctxs.Stranger.data.get(p).hats).toBe(1)
		local _, reason = h:use(Stranger).buyHat(p, 500)
		expect(reason).toBe("insufficient")
		expect(coins(p)).toBe(60)
	end)

	it("refuses a currency that is not paid, and bad amounts", function()
		local h = boot({})
		local p = h:addPlayer({ userId = 1 })
		local ok, err = pcall(ctxs.Stranger.tx, p, function(tx)
			ctxs.Stranger.compliance.spendPaid(tx, "Gems", 1, "x")
		end)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("not in GameConfig.compliance.paidCurrencies")
		local ok2 = pcall(ctxs.Stranger.tx, p, function(tx)
			ctxs.Stranger.compliance.spendPaid(tx, "Coins", -5, "x")
		end)
		expect(ok2).toBe(false)
		expect(coins(p)).toBe(100)
	end)

	it("spendPaid then roll in one tx is a paid roll: paidcur tag", function()
		local h = boot({})
		local p = h:addPlayer({ userId = 1 })
		local _, out = ctxs.Loot.tx(p, function(tx)
			assert(ctxs.Loot.compliance.spendPaid(tx, "Coins", 10, "ticket"))
			local ok, outcome = ctxs.Loot.compliance.roll(tx, "Box")
			return { ok = ok, outcome = outcome, tag = ctxs.Loot.compliance.tagPaid(tx, "drop") }
		end)
		expect(out.ok).toBe(true)
		expect(out.tag).toBe("paidcur:Box")
		expect(coins(p)).toBe(90)
	end)

	it("spendPaid then roll: a restricted player is refused", function()
		local h = boot({}, { policy = { [1] = true } })
		local p = h:addPlayer({ userId = 1 })
		local _, out = ctxs.Loot.tx(p, function(tx)
			assert(ctxs.Loot.compliance.spendPaid(tx, "Coins", 10, "ticket"))
			return table.pack(ctxs.Loot.compliance.roll(tx, "Box"))
		end)
		expect(out[1]).toBe(false)
		expect(out[3]).toBe("restricted")
		expect(sampleCalls).toBe(0)
		-- control: the same roll without a paid spend is free (no policy gate)
		local _, free = ctxs.Loot.tx(p, function(tx)
			return table.pack(ctxs.Loot.compliance.roll(tx, "Box"))
		end)
		expect(free[1]).toBe(true)
	end)

	it("spendPaid then roll: the luck rule applies (luck 5 on a source without luckDisclosed)", function()
		local h = boot({})
		local p = h:addPlayer({ userId = 1 })
		local ok, err = pcall(ctxs.Loot.tx, p, function(tx)
			assert(ctxs.Loot.compliance.spendPaid(tx, "Coins", 10, "ticket"))
			ctxs.Loot.compliance.roll(tx, "Egg", 5)
		end)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("hard rule 11")
		expect(coins(p)).toBe(100) -- the tx (and its spend) is discarded
	end)
end)

describe("tagPaid can't be forged (final review 8)", function()
	it("strips a caller's paid: / paidcur: prefix outside a paid tx", function()
		local h = boot({})
		local p = h:addPlayer({ userId = 1 })
		local tags = {}
		ctxs.Loot.tx(p, function(tx)
			tags.paid = ctxs.Loot.compliance.tagPaid(tx, "paid:CoinPack")
			tags.paidcur = ctxs.Loot.compliance.tagPaid(tx, "paidcur:Box")
			tags.nested = ctxs.Loot.compliance.tagPaid(tx, "paid:paidcur:x")
			tags.bare = ctxs.Loot.compliance.tagPaid(tx, "paid:")
			tags.plain = ctxs.Loot.compliance.tagPaid(tx, "quest")
		end)
		expect(tags.paid).toBe("CoinPack")
		expect(tags.paidcur).toBe("Box")
		expect(tags.nested).toBe("x")
		expect(tags.bare).toBe("free")
		expect(tags.plain).toBe("quest")
	end)
end)
