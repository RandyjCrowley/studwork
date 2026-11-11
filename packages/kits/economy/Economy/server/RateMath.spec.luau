local RateMath = require(script.Parent.RateMath)

describe("RateMath.combine", function()
	it("multiplies by default and returns 1 for no factors", function()
		expect(RateMath.combine({})).toBe(1)
		expect(RateMath.combine({ 2, 1.5 })).toBeNear(3)
		expect(RateMath.combine({ 2, 1.5 }, "multiply")).toBeNear(3)
	end)
	it("adds as 1 + sum(f - 1)", function()
		expect(RateMath.combine({ 2, 1.5 }, "add")).toBeNear(2.5)
		expect(RateMath.combine({}, "add")).toBe(1)
	end)
end)

describe("RateMath.activeBoosts / pruneExpired", function()
	it("ignores expired entries and reports the earliest future expiry", function()
		local out = {}
		local nextExpiry = RateMath.activeBoosts(out, {
			a = { mult = 2, expiresAt = 100 },
			b = { mult = 3, expiresAt = 50 },
			c = { mult = 1.5 },
			old = { mult = 10, expiresAt = 10 },
			bad = { mult = 0 / 0 },
		}, 20)
		table.sort(out)
		expect(out).toEqual({ 1.5, 2, 3 })
		expect(nextExpiry).toBe(50)
	end)
	it("treats expiresAt == now as expired", function()
		local out = {}
		expect(RateMath.activeBoosts(out, { a = { mult = 2, expiresAt = 5 } }, 5)).toBeNil()
		expect(#out).toBe(0)
	end)
	it("prunes in place", function()
		local entries = { a = { mult = 2, expiresAt = 5 }, b = { mult = 2 }, c = { mult = 2, expiresAt = 9 } }
		expect(RateMath.pruneExpired(entries, 6)).toBe(1)
		expect(entries.a).toBeNil()
		expect(entries.b).toBeTruthy()
		expect(entries.c).toBeTruthy()
	end)
	it("stacks rebirth, upgrade and boosts", function()
		local factors = { 1.5, RateMath.upgradeFactor(3, 0.1) }
		RateMath.activeBoosts(factors, { coplay = { mult = 1.1 } }, 0)
		expect(RateMath.combine(factors)).toBeNear(1.5 * 1.3 * 1.1)
		expect(RateMath.combine(factors, "add")).toBeNear(1 + 0.5 + 0.3 + 0.1)
	end)
end)

describe("RateMath.sumItems", function()
	local inventory = {
		u1 = { income = 2 },
		u2 = { income = 5 },
		u3 = { income = 0 / 0 },
	}
	local function incomeOf(i)
		return i.income
	end
	it("sums displayed items only, skipping missing uids and bad values", function()
		expect(RateMath.sumItems({ s1 = "u1", s2 = "missing", s3 = "u3" }, inventory, "displayed", incomeOf)).toBe(
			2
		)
	end)
	it("sums every owned item", function()
		expect(RateMath.sumItems({}, inventory, "owned", incomeOf)).toBe(7)
	end)
	it("handles 100 items", function()
		local inv, shown = {}, {}
		for i = 1, 100 do
			inv["u" .. i] = { income = 1 }
			shown["s" .. i] = "u" .. i
		end
		expect(RateMath.sumItems(shown, inv, "displayed", incomeOf)).toBe(100)
	end)
end)

describe("RateMath grant/spend validation", function()
	it("accepts finite positive amounts only", function()
		expect(RateMath.isPositiveAmount(1)).toBe(true)
		expect(RateMath.isPositiveAmount(0)).toBe(false)
		expect(RateMath.isPositiveAmount(-1)).toBe(false)
		expect(RateMath.isPositiveAmount(0 / 0)).toBe(false)
		expect(RateMath.isPositiveAmount(math.huge)).toBe(false)
		expect(RateMath.isPositiveAmount("5")).toBe(false)
	end)
	it("knows primary, starting and held currencies", function()
		expect(RateMath.isKnownCurrency("Coins", "Coins", nil, nil)).toBe(true)
		expect(RateMath.isKnownCurrency("Gems", "Coins", { Gems = 0 }, nil)).toBe(true)
		expect(RateMath.isKnownCurrency("Tix", "Coins", nil, { Tix = 3 })).toBe(true)
		expect(RateMath.isKnownCurrency("Nope", "Coins", { Gems = 0 }, { Coins = 1 })).toBe(false)
		expect(RateMath.isKnownCurrency(5, "Coins", nil, nil)).toBe(false)
	end)
	it("grants and refuses overflow", function()
		local b = { Coins = 10 }
		expect(RateMath.applyGrant(b, "Coins", 5)).toBe(true)
		expect(b.Coins).toBe(15)
		expect(RateMath.applyGrant(b, "Coins", -5)).toBe(false)
		b.Coins = 1.7e308
		expect(RateMath.applyGrant(b, "Coins", 1.7e308)).toBe(false)
		expect(b.Coins).toBe(1.7e308)
	end)
	it("never spends below zero", function()
		local b = { Coins = 10 }
		local ok, nb = RateMath.applySpend(b, "Coins", 11)
		expect(ok).toBe(false)
		expect(nb).toBe(10)
		ok, nb = RateMath.applySpend(b, "Coins", 10)
		expect(ok).toBe(true)
		expect(nb).toBe(0)
		expect(RateMath.applySpend(b, "Gems", 1)).toBe(false)
		expect(RateMath.applySpend(b, "Coins", 0 / 0)).toBe(false)
	end)
	it("splits analytics reasons", function()
		local kind, sku = RateMath.splitReason("upgrade:IncomeBoost")
		expect(kind).toBe("upgrade")
		expect(sku).toBe("IncomeBoost")
		kind, sku = RateMath.splitReason("offline")
		expect(kind).toBe("offline")
		expect(sku).toBeNil()
	end)
end)
