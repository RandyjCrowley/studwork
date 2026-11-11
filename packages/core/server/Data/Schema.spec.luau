local Migrate = require(script.Parent.Migrate)
local Sanitize =
	require(game:GetService("ServerScriptService"):WaitForChild("Compat"):WaitForChild("V12Sanitize"))
local Schema = require(script.Parent.Schema)

local function config(extra: any?): any
	local c: any = {
		gameId = "g",
		items = {},
		balance = { primaryCurrency = "coins", startingCurrency = { coins = 50, gems = 2 } },
		products = {},
		events = {},
		data = { defaults = { touches = 0, nested = { a = 1 } }, version = 1 },
	}
	if extra then
		for k, v in extra do
			c[k] = v
		end
	end
	return c
end

describe("Migrate.run", function()
	it("applies migrations in ascending order from fromVersion+1", function()
		local order = {}
		local migrations = {
			[1] = function(d)
				table.insert(order, 1)
				return d
			end,
			[2] = function(d)
				table.insert(order, 2)
				d.b = (d.a or 0) + 1
				return d
			end,
			[3] = function(d)
				table.insert(order, 3)
				return { c = d.b * 10 }
			end,
		}
		local out, status, applied = Migrate.run({ a = 1 }, 1, 3, migrations)
		expect(status).toBe("ok")
		expect(order).toEqual({ 2, 3 })
		expect(applied).toEqual({ 2, 3 })
		expect(out.c).toBe(20)
	end)

	it("skips versions without a function", function()
		local migrations = {
			[3] = function(d)
				d.three = true
				return d
			end,
		}
		local out, status, applied = Migrate.run({}, 0, 4, migrations)
		expect(status).toBe("ok")
		expect(applied).toEqual({ 3 })
		expect(out.three).toBe(true)
	end)

	it("is a no-op at the current version", function()
		local d = { x = 1 }
		local out, status, applied = Migrate.run(d, 2, 2, {})
		expect(status).toBe("ok")
		expect(#applied).toBe(0)
		expect(out).toBe(d)
	end)

	it("returns newer data untouched and never downgrades", function()
		local d = { x = 1 }
		local called = false
		local out, status = Migrate.run(d, 5, 3, {
			[4] = function(v)
				called = true
				return v
			end,
		})
		expect(status).toBe("newer")
		expect(out).toBe(d)
		expect(called).toBe(false)
	end)

	it("reports errors and non-table results", function()
		local _, s1, _, m1 = Migrate.run({}, 0, 1, {
			[1] = function()
				error("boom")
			end,
		})
		expect(s1).toBe("error")
		expect(m1).toContain("boom")
		local _, s2 = Migrate.run({}, 0, 1, {
			[1] = function()
				return 5 :: any
			end,
		})
		expect(s2).toBe("error")
	end)

	it("readVersion falls back on garbage", function()
		expect(Migrate.readVersion(3, 0)).toBe(3)
		expect(Migrate.readVersion(nil, 1)).toBe(1)
		expect(Migrate.readVersion(0 / 0, 0)).toBe(0)
		expect(Migrate.readVersion(1.5, 0)).toBe(0)
		expect(Migrate.readVersion(-1, 0)).toBe(0)
	end)
end)

describe("Schema.prepare", function()
	it("creates defaults for an empty profile", function()
		local data, status = Schema.prepare({}, config(), 1000)
		expect(status).toBe("new")
		expect(data.schemaVersion).toBe(Schema.CURRENT_VERSION)
		expect(data.currency.coins).toBe(50)
		expect(data.currency.gems).toBe(2)
		expect(data.lastSeen).toBe(1000)
		expect(data.firstJoin).toBe(1000)
		expect(data.stats.sessions).toBe(0)
		expect(data.game.g.touches).toBe(0)
		expect(data.game.g._version).toBe(1)
	end)

	it("does not share nested default tables between players", function()
		local a = Schema.prepare({}, config(), 1)
		local b = Schema.prepare({}, config(), 1)
		a.game.g.nested.a = 99
		expect(b.game.g.nested.a).toBe(1)
	end)

	it("reconciles missing keys without starting-currency gifts for existing players", function()
		local raw = {
			schemaVersion = 1,
			currency = { coins = 7 },
			lastSeen = 500,
			firstJoin = 100,
			stats = { sessions = 3 },
		}
		local data, status = Schema.prepare(raw, config(), 1000)
		expect(status).toBe("ok")
		expect(data.currency.coins).toBe(7)
		expect(data.currency.gems).toBe(0)
		expect(data.lastSeen).toBe(500)
		expect(data.stats.sessions).toBe(3)
		expect(type(data.inventory)).toBe("table")
		expect(data.streak.day).toBe(0)
		expect(data.game.g.touches).toBe(0)
	end)

	it("runs the schema migration list on version-0 data", function()
		local raw = { coins = 12 }
		local data, status = Schema.prepare(raw, config(), 1000)
		expect(status).toBe("ok")
		expect(data.currency.coins).toBe(12)
		expect(data.coins).toBeNil()
		expect(raw.coins).toBe(12) -- raw untouched (worked on a copy)
	end)

	it("refuses data from a newer schema and returns raw itself", function()
		local raw = { schemaVersion = Schema.CURRENT_VERSION + 1, currency = { coins = 1 } }
		local data, status = Schema.prepare(raw, config(), 1000)
		expect(status).toBe("newer")
		expect(data).toBe(raw)
	end)

	it("uses injected migrations and target version", function()
		local raw = { schemaVersion = 1, currency = { coins = 1 } }
		local data, status = Schema.prepare(raw, config(), 1000, {
			[2] = function(d)
				d.currency.coins *= 100
				return d
			end,
		}, 2)
		expect(status).toBe("ok")
		expect(data.schemaVersion).toBe(2)
		expect(data.currency.coins).toBe(100)
	end)

	it("migrates the game table using its _version key", function()
		local cfg = config({
			data = {
				defaults = { touches = 0, renamed = 0 },
				version = 3,
				migrations = {
					[2] = function(g)
						g.renamed = g.old
						g.old = nil
						return g
					end,
					[3] = function(g)
						g.renamed += 1
						return g
					end,
				},
			},
		})
		local raw = { schemaVersion = 1, game = { g = { old = 5 } } } -- no _version -> 1
		local data, status = Schema.prepare(raw, cfg, 1)
		expect(status).toBe("ok")
		expect(data.game.g.renamed).toBe(6)
		expect(data.game.g.old).toBeNil()
		expect(data.game.g._version).toBe(3)
		expect(data.game.g.touches).toBe(0)
	end)

	it("refuses a game table newer than the config", function()
		local raw = { schemaVersion = 1, game = { g = { _version = 9 } } }
		local data, status = Schema.prepare(raw, config(), 1)
		expect(status).toBe("newer")
		expect(data).toBe(raw)
	end)

	it("keeps other games' tables", function()
		local raw = { schemaVersion = 1, game = { other = { x = 1 } } }
		local data = Schema.prepare(raw, config(), 1)
		expect(data.game.other.x).toBe(1)
		expect(data.game.g.touches).toBe(0)
	end)

	it("sanitizes and prunes on load", function()
		local purchases = {}
		for i = 1, Schema.PURCHASES_CAP + 5 do
			purchases["p" .. i] = i
		end
		local raw =
			{ schemaVersion = 1, currency = { coins = 0 / 0, gems = math.huge }, purchases = purchases }
		local data = Schema.prepare(raw, config(), 1)
		expect(data.currency.coins).toBe(0)
		expect(data.currency.gems).toBe(0)
		local count = 0
		for _ in data.purchases do
			count += 1
		end
		expect(count).toBe(Schema.PURCHASES_CAP)
		expect(data.purchases.p1).toBeNil()
	end)
end)

describe("Sanitize", function()
	it("reconcile replaces wrong types and keeps unknown keys", function()
		local t: any = { a = "x", b = { c = 1 }, extra = true }
		Sanitize.reconcile(t, { a = 0, b = { c = 0, d = 2 }, e = { 1 } })
		expect(t.a).toBe(0)
		expect(t.b.c).toBe(1)
		expect(t.b.d).toBe(2)
		expect(t.extra).toBe(true)
		expect(t.e).toEqual({ 1 })
	end)

	it("playerData drops bad numbers, items and multipliers", function()
		local d: any = Schema.default(config(), 1)
		d.currency.coins = 0 / 0
		d.currency.ok = 5
		d.upgrades.speed = 2.7
		d.upgrades.neg = -1
		d.rebirths = -math.huge
		d.inventory.u1 = { uid = "u1", itemId = "a", acquiredAt = 1 }
		d.inventory.u2 = { uid = "other", itemId = "a", acquiredAt = 1 }
		d.inventory.u3 = { uid = "u3", itemId = "a", acquiredAt = 1, meta = { x = {} } }
		d.multipliers.good = { mult = 2 }
		d.multipliers.bad = { mult = 0 / 0 }
		d.displayed.s1 = 5
		local fixes = Sanitize.playerData(d)
		expect(fixes).toBeGreaterThan(0)
		expect(d.currency.coins).toBeNil()
		expect(d.currency.ok).toBe(5)
		expect(d.upgrades.speed).toBe(2)
		expect(d.upgrades.neg).toBeNil()
		expect(d.rebirths).toBe(0)
		expect(d.inventory.u1).toBeTruthy()
		expect(d.inventory.u2).toBeNil()
		expect(d.inventory.u3).toBeNil()
		expect(d.multipliers.good).toBeTruthy()
		expect(d.multipliers.bad).toBeNil()
		expect(d.displayed.s1).toBeNil()
	end)

	it("prunePurchases keeps the newest entries", function()
		local p = { a = 1, b = 5, c = 3, d = 4 }
		expect(Sanitize.prunePurchases(p, 2)).toBe(2)
		expect(p.a).toBeNil()
		expect(p.c).toBeNil()
		expect(p.b).toBe(5)
		expect(p.d).toBe(4)
		expect(Sanitize.prunePurchases(p, 2)).toBe(0)
	end)
end)
