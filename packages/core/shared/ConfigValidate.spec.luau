local ConfigValidate = require(script.Parent.ConfigValidate)

local function baseConfig()
	return {
		gameId = "test",
		modules = {
			"Items",
			"Inventory",
			"Rarity",
			"Economy",
			"Rebirth",
			"Offline",
			"Streak",
			"Friends",
			"Plot",
		},
		items = {
			{ id = "a", name = "A", rarity = "Common", incomePerSec = 1 },
			{ id = "b", name = "B", rarity = "Rare", incomePerSec = 5 },
		},
		balance = {
			primaryCurrency = "Coins",
			income = { tickSeconds = 1, source = "displayed" },
			inventory = { cap = 10 },
			rarityTables = {
				T = { entries = { { itemId = "a", weight = 1 }, { itemId = "b", weight = 1 } } },
			},
			rebirth = { baseCost = 100, costGrowth = 2, multiplierPerRebirth = 0.5, keepInventory = false },
			offline = { capSeconds = 3600, minSeconds = 60, payoutFraction = 0.5, autoPay = true },
			streak = { graceHours = 6 },
			friends = { checkIntervalSec = 30 },
		},
		products = { passes = {}, devProducts = {} },
		events = {},
	}
end

describe("ConfigValidate", function()
	it("accepts a minimal valid config", function()
		expect(#ConfigValidate.validate(baseConfig())).toBe(0)
	end)

	it("v1.2: validates mail tuning and luckDisclosed", function()
		local c = baseConfig()
		c.mail = { maxAttempts = 10, backoff = { base = 30, factor = 2, max = 900 }, mailboxCap = 100 }
		c.balance.rarityTables.T.luckDisclosed = true
		expect(#ConfigValidate.validate(c)).toBe(0)
		c.mail = { maxAttempts = 0, backoff = { base = 30, factor = 0.5, max = 10 }, mailboxCap = 1.5 }
		c.balance.rarityTables.T.luckDisclosed = "yes"
		local errors = ConfigValidate.validate(c)
		expect(#errors).toBe(4)
	end)

	it("rejects duplicate item ids", function()
		local c = baseConfig()
		table.insert(c.items, { id = "a", name = "A2", rarity = "Common", incomePerSec = 1 })
		local errors = ConfigValidate.validate(c)
		expect(#errors).toBe(1)
		expect(errors[1]).toContain("duplicate")
	end)

	it("rejects NaN and infinite numbers", function()
		local c = baseConfig()
		c.items[1].incomePerSec = 0 / 0
		c.balance.offline.payoutFraction = math.huge
		expect(#ConfigValidate.validate(c)).toBe(2)
	end)

	it("rejects rarity table entries for unknown items", function()
		local c = baseConfig()
		c.balance.rarityTables.T.entries[1].itemId = "nope"
		expect(ConfigValidate.validate(c)[1]).toContain("unknown")
	end)

	it("rejects bad event schedules and palette hex", function()
		local c = baseConfig()
		c.events.E = { durationSec = 10, schedule = { hourUtc = 25, weekday = 8 } }
		c.palette = { accent = "orange" }
		expect(#ConfigValidate.validate(c)).toBe(3)
	end)

	it("assertValid throws with every error listed", function()
		local c = baseConfig()
		c.gameId = ""
		expect(function()
			ConfigValidate.assertValid(c)
		end).toThrow("gameId")
	end)
end)
