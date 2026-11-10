local InventoryRules = require(script.Parent.InventoryRules)

local function input(overrides: { [string]: any }?): any
	local t: { [string]: any } = {
		fromLoaded = true,
		toLoaded = true,
		samePlayer = false,
		owned = true,
		source = "roll",
		fromRestricted = false,
		toRestricted = false,
		toCount = 3,
		toCap = 10,
	}
	for k, v in (overrides or {}) :: { [string]: any } do
		t[k] = v
	end
	return t
end

describe("InventoryRules.transferCheck", function()
	it("allows a normal transfer", function()
		local ok, why = InventoryRules.transferCheck(input())
		expect(ok).toBe(true)
		expect(why).toBeNil()
	end)

	it("returns one reason per failing rule", function()
		expect(select(2, InventoryRules.transferCheck(input({ fromLoaded = false })))).toBe("not_loaded")
		expect(select(2, InventoryRules.transferCheck(input({ toLoaded = false })))).toBe("not_loaded")
		expect(select(2, InventoryRules.transferCheck(input({ samePlayer = true })))).toBe("same_player")
		expect(select(2, InventoryRules.transferCheck(input({ owned = false })))).toBe("not_owned")
		expect(select(2, InventoryRules.transferCheck(input({ toCount = 10 })))).toBe("inventory_full")
		expect(select(2, InventoryRules.transferCheck(input({ toCount = 11 })))).toBe("inventory_full")
	end)

	it("blocks paid-random items when either side is restricted", function()
		local paid = { source = "paid:Egg" }
		expect(select(2, InventoryRules.transferCheck(input({ source = "paid:Egg", fromRestricted = true })))).toBe(
			"restricted"
		)
		expect(select(2, InventoryRules.transferCheck(input({ source = "paid:Egg", toRestricted = true })))).toBe(
			"restricted"
		)
		expect((InventoryRules.transferCheck(input(paid)))).toBe(true)
		-- non-paid items trade freely even for restricted players
		expect((InventoryRules.transferCheck(input({ fromRestricted = true, toRestricted = true })))).toBe(
			true
		)
		expect((InventoryRules.transferCheck(input({ source = nil, toRestricted = true })))).toBe(true)
		expect((InventoryRules.transferCheck(input({ source = "xpaid:Egg", toRestricted = true })))).toBe(
			true
		)
	end)

	it("checks in the documented order", function()
		local _, why = InventoryRules.transferCheck(input({
			owned = false,
			samePlayer = true,
			toCount = 99,
			source = "paid:Egg",
			toRestricted = true,
		}))
		expect(why).toBe("same_player")
		_, why =
			InventoryRules.transferCheck(input({ source = "paid:Egg", toRestricted = true, toCount = 99 }))
		expect(why).toBe("restricted")
	end)
end)

describe("InventoryRules.validateMeta", function()
	it("accepts nil and small tables", function()
		expect((InventoryRules.validateMeta(nil))).toBe(true)
		expect((InventoryRules.validateMeta({ level = 3, shiny = true, label = "hi" }))).toBe(true)
	end)

	it("rejects wrong types, non-finite numbers and nested tables", function()
		expect((InventoryRules.validateMeta("x"))).toBe(false)
		expect((InventoryRules.validateMeta({ [1] = "x" }))).toBe(false)
		expect((InventoryRules.validateMeta({ a = 0 / 0 }))).toBe(false)
		expect((InventoryRules.validateMeta({ a = math.huge }))).toBe(false)
		expect((InventoryRules.validateMeta({ a = {} }))).toBe(false)
		expect((InventoryRules.validateMeta({ [""] = 1 }))).toBe(false)
	end)

	it("enforces key count, key length, string length and total size", function()
		local many = {}
		for i = 1, InventoryRules.MAX_META_KEYS + 1 do
			many["k" .. i] = i
		end
		expect((InventoryRules.validateMeta(many))).toBe(false)
		expect(
			(InventoryRules.validateMeta({ [string.rep("k", InventoryRules.MAX_META_KEY_LENGTH + 1)] = 1 }))
		).toBe(false)
		expect(
			(InventoryRules.validateMeta({ s = string.rep("x", InventoryRules.MAX_META_STRING_LENGTH + 1) }))
		).toBe(false)
		local big = {}
		for i = 1, 5 do
			big["key" .. i] = string.rep("x", InventoryRules.MAX_META_STRING_LENGTH) -- 5 * 68 > 256
		end
		local ok, err = InventoryRules.validateMeta(big)
		expect(ok).toBe(false)
		expect(err).toContain("too large")
	end)
end)

describe("InventoryRules.capacity", function()
	local UPGRADES: any = {
		BiggerBag = { effect = "inventoryCap", perLevel = 5 },
		Pockets = { effect = "inventoryCap", perLevel = 2 },
		IncomeBoost = { effect = "incomeMultiplier", perLevel = 0.1 },
	}
	local levels = { BiggerBag = 3, Pockets = 1, IncomeBoost = 10 }
	local function levelOf(id: string): number
		return (levels :: any)[id] or 0
	end

	it("adds level * perLevel for inventoryCap upgrades only", function()
		expect(InventoryRules.capacity(50, UPGRADES, levelOf)).toBe(50 + 15 + 2)
		expect(InventoryRules.capacity(50, nil, levelOf)).toBe(50)
	end)

	it("ignores bad levels and never goes below 0", function()
		expect(InventoryRules.capacity(50, UPGRADES, function()
			return 0 / 0
		end)).toBe(50)
		expect(InventoryRules.capacity(-5, nil, levelOf)).toBe(0)
	end)
end)

describe("InventoryRules misc", function()
	it("detects paid sources", function()
		expect(InventoryRules.isPaidSource("paid:Egg")).toBe(true)
		expect(InventoryRules.isPaidSource("paidcur:Chest")).toBe(true) -- paid-currency roll (N5)
		expect(InventoryRules.isPaidSource("roll")).toBe(false)
		expect(InventoryRules.isPaidSource(nil)).toBe(false)
	end)

	it("validates gift targets", function()
		expect(InventoryRules.validGiftTarget(1, 2)).toBe(true)
		expect(InventoryRules.validGiftTarget(1, 1)).toBe(false)
		expect(InventoryRules.validGiftTarget(1, 2.5)).toBe(false)
		expect(InventoryRules.validGiftTarget(1, 0 / 0)).toBe(false)
		expect(InventoryRules.validGiftTarget(1, -4)).toBe(false)
		expect(InventoryRules.validGiftTarget(1, "2")).toBe(false)
	end)
end)

describe("InventoryRules.giftCheck (sendGift)", function()
	local function gift(overrides: { [string]: any }?): any
		local t: { [string]: any } = {
			mailEnabled = true,
			fromLoaded = true,
			fromUserId = 1,
			toUserId = 2,
			owned = true,
			source = "roll",
		}
		if overrides then
			for k, v in overrides do
				t[k] = v
			end
		end
		return t
	end
	local function reason(o)
		return select(2, InventoryRules.giftCheck(gift(o)))
	end

	it("passes a valid gift", function()
		expect(InventoryRules.giftCheck(gift())).toBe(true)
		expect(InventoryRules.giftCheck(gift({ source = nil }))).toBe(true)
	end)

	it("each reason, and the documented order wins when several fail", function()
		expect(reason({ mailEnabled = false, fromLoaded = false, toUserId = 0 })).toBe("mail_off")
		expect(reason({ fromLoaded = false, toUserId = 0 })).toBe("not_loaded")
		expect(reason({ toUserId = 0, owned = false })).toBe("bad_target")
		expect(reason({ toUserId = -3 })).toBe("bad_target")
		expect(reason({ toUserId = 1.5 })).toBe("bad_target")
		expect(reason({ toUserId = 0 / 0 })).toBe("bad_target")
		expect(reason({ toUserId = math.huge })).toBe("bad_target")
		expect(reason({ toUserId = "2" })).toBe("bad_target")
		expect(reason({ toUserId = 1, owned = false })).toBe("same_player")
		expect(reason({ owned = false, source = "paid:x" })).toBe("not_owned")
		expect(reason({ source = "paid:egg" })).toBe("restricted_source")
		expect(reason({ source = "paidcur:gems" })).toBe("restricted_source")
	end)
end)
