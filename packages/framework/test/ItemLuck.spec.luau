--!nocheck
--[[
	v1.6.0 (docs/framework/adopting.md §6): Rarity odds preview at any luck, and luck on a single
	item (an egg in an incubator) with that item's odds disclosed through Compliance. Real kit
	modules (Items, Rarity, Inventory, Economy) through StudWork.test.harness, at luck 1, 2.8, 8.
	  - getOddsDetail(tableId, player, luck) equals RollMath at that luck and never changes getLuck
	  - a free item roll works at any luck, disclosed or not
	  - a paid item roll (purchase; spendForRoll on a paid currency; a paid = true table) is refused
	    before discloseItem, refused at another luck, allowed at the disclosed luck; restricted and
	    policy-unknown players are refused; luckDisclosed = false + luck ~= 1 is the hard-rule-11
	    error even when disclosed; the per-player cap refuses (never evicts); clearItem refuses again
	  - the player's table luck is unchanged throughout
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local Modules = ReplicatedStorage:WaitForChild("Modules")
local function kit(m: string): any
	return require(Modules:WaitForChild(m):WaitForChild("module"))
end
local Items = kit("Items")
local Rarity = kit("Rarity")
local Inventory = kit("Inventory")
local Economy = kit("Economy")
local RollMath = require("packages/kits/collection/Rarity/server/RollMath.luau")

local LUCKS = { 1, 2.8, 8 }
local PRODUCTS = { passes = {}, devProducts = { Hatch = 5001 } }

local ITEMS = {
	{ id = "pebble", name = "pebble", rarity = "Common" },
	{ id = "acorn", name = "acorn", rarity = "Uncommon" },
	{ id = "crystal", name = "crystal", rarity = "Rare" },
	{ id = "comet", name = "comet", rarity = "Legendary" },
}
local ENTRIES = {
	{ itemId = "pebble", weight = 50 },
	{ itemId = "acorn", weight = 25 },
	{ itemId = "crystal", weight = 20 },
	{ itemId = "comet", weight = 5 },
}

-- what the game's Hatch product / spend will roll next
local plan = { tableId = "NestEgg", luck = 1, item = "egg1" }
local inc: any = {}

local function gameModule(): (any, any)
	local ref = StudWork.defineModule({
		name = "Incubator",
		version = "1.0.0",
		framework = "^1.3.0",
		dependsOn = { Rarity, Inventory, Economy },
	})
	local part = {
		init = function(ctx)
			inc.ctx = ctx
			ctx.shop.onProduct("Hatch", function(tx)
				local def, info = tx.use(Rarity).roll(plan.tableId, plan.luck, { item = plan.item })
				inc.last = info
				if not (def and info.ok) then
					error("hatch refused: " .. tostring(info.reason), 0)
				end
			end)
		end,
		api = {
			-- a Gems hatch: the spend and the roll commit together (compliance.spendForRoll)
			gemHatch = function(player, tableId, luck, item)
				local c = inc.ctx
				local out
				c.tx(player, function(tx)
					out =
						table.pack(c.compliance.spendForRoll(tx, "Gems", 10, tableId, luck, { item = item }))
				end)
				return out[1], out[3]
			end,
		},
	}
	inc.ref = ref
	return ref, part
end

local function boot(extra: any?): any
	local ref, part = gameModule()
	local opts = {
		modules = { Items, Rarity, Inventory, Economy, ref },
		servers = { Incubator = part },
		items = ITEMS,
		products = PRODUCTS,
		compliance = { paidCurrencies = { "Gems" } },
		config = {
			Economy = {
				primaryCurrency = "Coins",
				currencies = { "Gems" },
				startingCurrency = { Gems = 10000 },
				income = { tickSeconds = 1 },
			},
			Rarity = {
				rarityTables = {
					NestEgg = { entries = ENTRIES, luckDisclosed = true },
					PlainEgg = { entries = ENTRIES }, -- luckDisclosed = false
					GoldEgg = { entries = ENTRIES, paid = true, luckDisclosed = true },
				},
				mutations = {},
			},
		},
	}
	for k, v in extra or {} do
		opts[k] = v
	end
	return StudWork.test.harness(opts)
end

local function join(h, userId)
	local p = h:addPlayer({ userId = userId or 1 })
	return p
end

local function sync(h, p)
	h:state(p) -- one replication step: the client is sent what was queued
end

local function invCount(h, p)
	return h:use(Inventory).count(p)
end

local function expectedOdds(luck)
	local tierOf = function(id)
		for _, d in ITEMS do
			if d.id == id then
				return d.rarity
			end
		end
		return nil
	end
	return RollMath.odds(RollMath.buildWeights(ENTRIES, tierOf, luck, nil))
end

describe("Rarity.getOddsDetail at any luck (pure preview)", function()
	it("equals RollMath at luck 1, 2.8 and 8 and never changes the player's luck", function()
		local h = boot()
		local p = join(h)
		local R = h:use(Rarity)
		local before = h:state(p)
		for _, luck in LUCKS do
			local d = R.getOddsDetail("NestEgg", p, luck)
			expect(d.luck).toBe(luck)
			local want = expectedOdds(luck)
			for id, prob in want do
				expect(d.items[id]).toBeNear(prob, 1e-12)
			end
			expect(R.getLuck(p, "NestEgg")).toBe(1)
		end
		-- sanitized like any luck; no luck: unchanged behaviour (the player's luck)
		expect(R.getOddsDetail("NestEgg", p, 1e9).luck).toBe(RollMath.MAX_LUCK)
		expect(R.getOddsDetail("NestEgg", p, -3).luck).toBe(1)
		expect(R.getOddsDetail("NestEgg", p).luck).toBe(1)
		-- pure: nothing replicated, nothing disclosed
		local after = h:state(p)
		expect(after.framework.itemOdds).toBeNil()
		expect(after.modules.Rarity.extra.odds.NestEgg.luck).toBe(
			before.modules.Rarity.extra.odds.NestEgg.luck
		)
	end)
end)

describe("item luck: free rolls", function()
	it("a free item roll works at every luck, disclosed or not, and ignores session luck", function()
		local h = boot()
		local p = join(h)
		local R = h:use(Rarity)
		R.setLuck(p, 50, "NestEgg") -- session luck must not leak into an item roll
		for i, luck in LUCKS do
			local def, info = R.roll("NestEgg", p, luck, { item = "egg" .. i, grant = true })
			expect(info.ok).toBe(true)
			expect(def).never.toBeNil()
			local def2, info2 = R.roll("PlainEgg", p, luck, { item = "plain" .. i })
			expect(info2.ok).toBe(true)
			expect(def2).never.toBeNil()
		end
		expect(invCount(h, p)).toBe(3)
		expect(R.getLuck(p, "NestEgg")).toBe(50)
	end)
end)

describe("item luck: paid rolls inside a purchase", function()
	for _, luck in LUCKS do
		it(
			`luck {luck}: refused before discloseItem, refused at another luck, granted at the disclosed luck`,
			function()
				local h = boot()
				local p = join(h)
				local R = h:use(Rarity)
				plan = { tableId = "NestEgg", luck = luck, item = "egg1" }

				expect(h:purchase(p, "Hatch")).toBe("NotProcessedYet")
				expect(invCount(h, p)).toBe(0)

				local other = if luck == 8 then 2.8 else 8
				expect(R.discloseItem(p, "NestEgg", "egg1", other)).toBe(true)
				sync(h, p)
				expect(h:purchase(p, "Hatch")).toBe("NotProcessedYet")
				expect(invCount(h, p)).toBe(0)

				expect(R.discloseItem(p, "NestEgg", "egg1", luck)).toBe(true)
				-- queued but not yet sent to the client: still refused
				expect(h:purchase(p, "Hatch")).toBe("NotProcessedYet")
				sync(h, p)
				local shown = h:state(p).framework.itemOdds.NestEgg.egg1
				expect(shown.luck).toBe(luck)
				expect(shown.item).toBe("egg1")
				expect(h:purchase(p, "Hatch")).toBe("PurchaseGranted")
				expect(invCount(h, p)).toBe(1)
				expect(h:use(Inventory).list(p)[1].source).toBe("paid:Hatch")
				expect(R.getLuck(p, "NestEgg")).toBe(1)
				expect(R.getLuck(p)).toBe(1)
			end
		)
	end

	it("a restricted player is refused; an unknown policy retries", function()
		local h = boot({ policy = { [1] = true, [2] = "fail" } })
		local p = join(h, 1)
		local R = h:use(Rarity)
		plan = { tableId = "NestEgg", luck = 2.8, item = "egg1" }
		expect(R.discloseItem(p, "NestEgg", "egg1", 2.8)).toBe(true)
		sync(h, p)
		h:purchase(p, "Hatch")
		expect(inc.last.reason).toBe("restricted")
		expect(invCount(h, p)).toBe(0)

		local q = join(h, 2)
		expect(R.discloseItem(q, "NestEgg", "egg1", 2.8)).toBe(true)
		sync(h, q)
		inc.last = nil
		expect(h:purchase(q, "Hatch")).toBe("NotProcessedYet")
		-- the Shop may retry before the handler runs; if it ran, Compliance said policy_unknown
		expect(inc.last == nil or inc.last.reason == "policy_unknown").toBe(true)
		-- and directly: a paid item roll for an unknown policy
		local out
		inc.ctx.tx(q, function(tx)
			h.runtime.data.txMeta(tx).paidSpent = "Gems"
			out = table.pack(inc.ctx.compliance.roll(tx, "NestEgg", 2.8, { item = "egg1" }))
		end)
		expect(out[1]).toBe(false)
		expect(out[3]).toBe("policy_unknown")
		expect(invCount(h, q)).toBe(0)
	end)

	it("luckDisclosed = false + luck 2.8: the hard-rule-11 refusal even when disclosed", function()
		local h = boot()
		local p = join(h)
		local R = h:use(Rarity)
		plan = { tableId = "PlainEgg", luck = 2.8, item = "egg1" }
		expect(R.discloseItem(p, "PlainEgg", "egg1", 2.8)).toBe(true)
		sync(h, p)
		local ok, err = pcall(function()
			inc.ctx.tx(p, function(tx)
				h.runtime.data.txMeta(tx).paidSpent = "Gems" -- a paid tx without a product
				inc.ctx.compliance.roll(tx, "PlainEgg", 2.8, { item = "egg1" })
			end)
		end)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("hard rule 11")
		expect(h:purchase(p, "Hatch")).never.toBe("PurchaseGranted")
		expect(invCount(h, p)).toBe(0)
		-- luck 1 on the same table, disclosed at 1: allowed
		plan = { tableId = "PlainEgg", luck = 1, item = "egg2" }
		expect(R.discloseItem(p, "PlainEgg", "egg2", 1)).toBe(true)
		sync(h, p)
		expect(h:purchase(p, "Hatch")).toBe("PurchaseGranted")
	end)

	it("clearItem then a paid roll: refused", function()
		local h = boot()
		local p = join(h)
		local R = h:use(Rarity)
		plan = { tableId = "NestEgg", luck = 2.8, item = "egg1" }
		R.discloseItem(p, "NestEgg", "egg1", 2.8)
		sync(h, p)
		R.clearItem(p, "NestEgg", "egg1")
		sync(h, p)
		expect(h:state(p).framework.itemOdds.NestEgg).toBeNil()
		expect(h:purchase(p, "Hatch")).toBe("NotProcessedYet")
		expect(invCount(h, p)).toBe(0)
	end)
end)

describe("item luck: spendForRoll on a paid currency", function()
	for _, luck in LUCKS do
		it(`luck {luck}: refused before, refused at another luck, allowed at the disclosed luck`, function()
			local h = boot()
			local p = join(h)
			local R = h:use(Rarity)
			local gems = h:use(Economy).balance(p, "Gems")
			local incubator = h:use(inc.ref)
			local ok, reason = incubator.gemHatch(p, "NestEgg", luck, "egg1")
			expect(ok).toBe(false)
			expect(reason).toBe("odds_not_disclosed")
			R.discloseItem(p, "NestEgg", "egg1", if luck == 1 then 2.8 else 1)
			sync(h, p)
			ok, reason = incubator.gemHatch(p, "NestEgg", luck, "egg1")
			expect(ok).toBe(false)
			expect(reason).toBe("odds_not_disclosed")
			expect(h:use(Economy).balance(p, "Gems")).toBe(gems)
			R.discloseItem(p, "NestEgg", "egg1", luck)
			sync(h, p)
			ok, reason = incubator.gemHatch(p, "NestEgg", luck, "egg1")
			expect(reason).toBeNil()
			expect(ok).toBe(true)
			expect(h:use(Economy).balance(p, "Gems")).toBe(gems - 10)
			expect(R.getLuck(p, "NestEgg")).toBe(1)
		end)
	end
end)

describe("item luck: a paid = true table outside a purchase", function()
	it("refused until disclosed at exactly that luck; restricted refused", function()
		local h = boot()
		local p = join(h)
		local R = h:use(Rarity)
		local _, info = R.roll("GoldEgg", p, 2.8, { item = "egg1", grant = true })
		expect(info.ok).toBe(false)
		expect(info.reason).toBe("odds_not_disclosed")
		R.discloseItem(p, "GoldEgg", "egg1", 8)
		sync(h, p)
		_, info = R.roll("GoldEgg", p, 2.8, { item = "egg1", grant = true })
		expect(info.reason).toBe("odds_not_disclosed")
		R.discloseItem(p, "GoldEgg", "egg1", 2.8)
		sync(h, p)
		_, info = R.roll("GoldEgg", p, 2.8, { item = "egg1", grant = true })
		expect(info.ok).toBe(true)
		expect(R.getLuck(p, "GoldEgg")).toBe(1)

		local h2 = boot({ policy = { [1] = true } })
		local q = join(h2)
		h2:use(Rarity).discloseItem(q, "GoldEgg", "egg1", 2.8)
		sync(h2, q)
		local _, info2 = h2:use(Rarity).roll("GoldEgg", q, 2.8, { item = "egg1" })
		expect(info2.reason).toBe("restricted")
	end)
end)

describe("item disclosures are bounded", function()
	it("past MAX_ITEM_DISCLOSURES discloseItem returns false and evicts nothing", function()
		local h = boot()
		local p = join(h)
		local R = h:use(Rarity)
		for i = 1, 64 do
			expect(R.discloseItem(p, if i % 2 == 0 then "NestEgg" else "PlainEgg", "e" .. i, 1)).toBe(true)
		end
		expect(R.discloseItem(p, "NestEgg", "e65", 1)).toBe(false)
		-- re-disclosing an existing key (a new luck) is not a new entry
		expect(R.discloseItem(p, "NestEgg", "e2", 2.8)).toBe(true)
		sync(h, p)
		local all = h:state(p).framework.itemOdds
		expect(all.NestEgg.e65).toBeNil()
		expect(all.PlainEgg.e1).never.toBeNil()
		expect(all.NestEgg.e2.luck).toBe(2.8)
		R.clearItem(p, "PlainEgg", "e1")
		expect(R.discloseItem(p, "NestEgg", "e65", 1)).toBe(true)
		-- unknown table: false; bad item key: error
		expect(R.discloseItem(p, "Nope", "x", 1)).toBe(false)
		expect(pcall(R.discloseItem, p, "NestEgg", string.rep("x", 65), 1)).toBe(false)
	end)

	it("cleared when the player leaves", function()
		local h = boot()
		local p = join(h)
		local R = h:use(Rarity)
		for i = 1, 64 do
			R.discloseItem(p, "NestEgg", "e" .. i, 1)
		end
		h:removePlayer(p)
		local q = join(h, 1)
		expect(R.discloseItem(q, "NestEgg", "fresh", 1)).toBe(true)
		sync(h, q)
		expect(h:state(q).framework.itemOdds.NestEgg.e1).toBeNil()
	end)
end)
