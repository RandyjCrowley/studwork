local Load = require(script.Parent.Load)
local Sanitize =
	require(game:GetService("ServerScriptService"):WaitForChild("Compat"):WaitForChild("V12Sanitize"))
local Schema = require(script.Parent.Schema)

local function config(): any
	return {
		gameId = "g",
		items = {},
		balance = { primaryCurrency = "coins", startingCurrency = { coins = 50 } },
		products = {},
		events = {},
		data = { defaults = { touches = 0 }, version = 1 },
	}
end

local function existing(): any
	return {
		schemaVersion = 0,
		currency = { coins = 1234 },
		inventory = { u1 = { uid = "u1", itemId = "a", acquiredAt = 1 } },
		stats = { sessions = 9 },
	}
end

describe("Data.Load.decide", function()
	it("migration failure on an existing profile: kick, analytics, raw never replaced or mutated", function()
		local raw = existing()
		local snapshot = Sanitize.deepCopy(raw)
		local failing = {
			[1] = function(d)
				d.currency.coins = 0 -- mutate the (copied) input before failing
				error("bad migration")
			end,
		}
		local decision = Load.decide(raw, function(r)
			return Schema.prepare(r, config(), 1000, failing, 1)
		end)
		expect(decision.action).toBe("kick")
		expect(decision.status).toBe("error")
		expect(decision.message).toBe(
			"We couldn't load your save safely. Please rejoin. Your progress is safe."
		)
		expect(decision.analytics).toBe(true)
		expect(decision.data).toBeNil()
		expect(tostring(decision.reason)).toContain("bad migration")
		expect(raw).toEqual(snapshot) -- default data never saved over it
		expect(raw.currency.coins).toBe(1234)
	end)

	it("prepare throwing is treated as a load failure", function()
		local raw = existing()
		local decision = Load.decide(raw, function()
			error("cannot parse")
		end)
		expect(decision.action).toBe("kick")
		expect(decision.analytics).toBe(true)
		expect(decision.message).toBe(Load.KICK_MIGRATION_FAILED)
		expect(raw.currency.coins).toBe(1234)
	end)

	it("newer data keeps the older-server kick without analytics", function()
		local raw = { schemaVersion = Schema.CURRENT_VERSION + 1, currency = { coins = 1 } }
		local decision = Load.decide(raw, function(r)
			return Schema.prepare(r, config(), 1)
		end)
		expect(decision.action).toBe("kick")
		expect(decision.status).toBe("newer")
		expect(decision.message).toBe(Load.KICK_NEWER_DATA)
		expect(decision.analytics).toBe(false)
	end)

	it("ok / new -> use the prepared copy", function()
		local raw = existing()
		local d1 = Load.decide(raw, function(r)
			return Schema.prepare(r, config(), 1)
		end)
		expect(d1.action).toBe("use")
		expect(d1.data).never.toBe(raw)
		expect((d1.data :: any).currency.coins).toBe(1234)
		local d2 = Load.decide({}, function(r)
			return Schema.prepare(r, config(), 1)
		end)
		expect(d2.action).toBe("use")
		expect(d2.status).toBe("new")
	end)

	it("reports dropped inventory entries (L7)", function()
		local raw = existing()
		raw.schemaVersion = 1
		raw.inventory.bad = { uid = "other", itemId = "a", acquiredAt = 1 }
		raw.inventory.bad2 = 5
		raw.currency.gems = 0 / 0
		local decision = Load.decide(raw, function(r)
			return Schema.prepare(r, config(), 1)
		end)
		local report = decision.report :: any
		expect(report.inventory).toBe(2)
		expect(report.other).toBe(1)
		local msg = Load.dropWarning(42, report) :: string
		expect(msg).toContain("42")
		expect(msg).toContain("2 invalid inventory")
		expect(Load.dropWarning(42, { inventory = 0, other = 0 })).toBeNil()
		expect(Load.dropWarning(42, nil)).toBeNil()
	end)
end)

describe("Data.Load.awaitStore", function()
	local function fakeClock()
		local t = 0
		return function()
			return t
		end, function()
			t += 1
		end
	end

	it("returns true once ready", function()
		local clock, sleep = fakeClock()
		local n = 0
		local ready = Load.awaitStore(function()
			n += 1
			return n > 3
		end, function()
			return false
		end, clock, sleep, 15)
		expect(ready).toBe(true)
	end)

	it("gives up after the timeout (chooseStore never finished)", function()
		local clock, sleep = fakeClock()
		local ready = Load.awaitStore(function()
			return false
		end, function()
			return false
		end, clock, sleep, 15)
		expect(ready).toBe(false)
		expect(clock()).toBe(15)
	end)

	it("gives up at once when choosing the store failed", function()
		local clock, sleep = fakeClock()
		local ready = Load.awaitStore(function()
			return false
		end, function()
			return true
		end, clock, sleep, 15)
		expect(ready).toBe(false)
		expect(clock()).toBe(0)
	end)
end)
