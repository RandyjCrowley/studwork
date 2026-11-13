--!nocheck
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Codes = require(Modules:WaitForChild("Codes"):WaitForChild("module"))
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Items = require(Modules:WaitForChild("Items"):WaitForChild("module"))
local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module"))
local Loader = require("packages/framework/server/Loader.luau")
local Ledger = require("packages/kits/player/Codes/server/Ledger.luau")
local Catalog = require("packages/kits/player/Codes/server/Catalog.luau")

local function definition(id, extra)
	local d = { id = id, code = string.upper(id), rewards = { { kind = "currency", amount = 10 } } }
	for key, value in extra or {} do
		d[key] = value
	end
	return d
end
local function boot(options)
	local o = options or {}
	local captured
	local part = Loader.defaultLoadServer(Codes, nil, { bindNet = false })
	local init = part.init
	part.init = function(ctx)
		if o.shared then
			ctx = table.clone(ctx)
			ctx.data = table.clone(ctx.data)
			ctx.data.shared = o.shared
		end
		captured = ctx
		init(ctx)
	end
	local config =
		{ definitions = o.definitions or { definition("hello") }, rate = { rate = 100, burst = 100 } }
	for k, v in o.config or {} do
		config[k] = v
	end
	local modules = { Economy, Codes }
	for _, ref in o.modules or {} do
		table.insert(modules, ref)
	end
	local moduleConfig = { Codes = config }
	for name, value in o.moduleConfig or {} do
		moduleConfig[name] = value
	end
	local h = StudWork.test.harness({
		modules = modules,
		servers = { Codes = part },
		config = moduleConfig,
		items = o.items,
		store = o.store or StudWork.test.memoryStore(),
		env = o.env or "test",
		isStudio = o.isStudio,
		serverConfig = o.serverConfig,
		services = o.services,
		flags = o.flags,
		compliance = o.compliance,
	})
	return h, function()
		return captured
	end
end
local function add(h, userId, data)
	local p = h:addPlayer({ userId = userId or 1, data = data })
	task.wait()
	return p
end
local function ledgerStore()
	local values, log = {}, {}
	local shared = { values = values, calls = log }
	function shared.update(key, fn)
		table.insert(log, key)
		values[key] = fn(values[key])
		return true, values[key]
	end
	return shared
end

describe("Codes authoritative grants", function()
	it("normalizes, grants once and survives rejoin with a private save", function()
		local h = boot()
		local p = add(h)
		local seen = 0
		h:use(Codes).signals.Redeemed:Connect(function()
			seen += 1
		end)
		expect(h:use(Codes).redeem(p, "  hello  ")).toBe("ok")
		expect(h:use(Economy).balance(p)).toBe(10)
		expect(h:use(Codes).redeem(p, "HELLO")).toBe("already_used")
		expect(seen).toBe(1)
		h:rejoin(p, { secondsAway = 1 })
		task.wait()
		expect(h:use(Codes).redeem(p, "hello")).toBe("already_used")
		expect(h:use(Economy).balance(p)).toBe(10)
		expect(Codes.data.replicate).toBe(false)
	end)
	it("releases a cap reservation when the second reward fails and rolls all rewards back", function()
		local shared = ledgerStore()
		local d = definition(
			"broken",
			{ maxUses = 1, rewards = { { kind = "currency", amount = 10 }, { kind = "reject" } } }
		)
		local h, context = boot({ definitions = { d }, shared = shared })
		h:use(Codes).registerReward("reject", function()
			return false
		end)
		local p = add(h)
		expect(h:use(Codes).redeem(p, "broken")).toBe("try_later")
		expect(h:use(Economy).balance(p)).toBe(0)
		expect(context().data.get(p).redeemed.broken).toBe(nil)
		expect(Ledger.count(shared.values["cap/broken"])).toBe(0)
	end)
	it("retains a committed receipt on save failure and never regrants when retried", function()
		local shared = ledgerStore()
		local h, context = boot({ shared = shared, definitions = { definition("safe", { maxUses = 1 }) } })
		local p = add(h)
		h.store.failNext(1)
		expect(h:use(Codes).redeem(p, "safe")).toBe("try_later")
		expect(h:use(Economy).balance(p)).toBe(10)
		expect(context().data.get(p).pending.safe ~= nil).toBe(true)
		expect(Ledger.count(shared.values["cap/safe"])).toBe(1)
		expect(h:use(Codes).redeem(p, "safe")).toBe("already_used")
		expect(h:use(Economy).balance(p)).toBe(10)
		expect(shared.values["cap/safe"].used).toBe(1)
		expect(context().data.get(p).pending.safe).toBe(nil)
	end)
	it("retains pending when finalization loses its response, then finalizes idempotently", function()
		local shared = ledgerStore()
		local raw = shared.update
		local calls = 0
		shared.update = function(key, fn)
			calls += 1
			local ok, result = raw(key, fn)
			if calls == 2 then
				return false, nil
			end
			return ok, result
		end
		local h = boot({ shared = shared, definitions = { definition("retry", { maxUses = 1 }) } })
		local p = add(h)
		expect(h:use(Codes).redeem(p, "retry")).toBe("try_later")
		expect(shared.values["cap/retry"].used).toBe(1)
		expect(h:use(Codes).redeem(p, "retry")).toBe("already_used")
		expect(shared.values["cap/retry"].used).toBe(1)
		expect(h:use(Economy).balance(p)).toBe(10)
	end)
	it("refuses global cap exhaustion and durable cap-policy disagreement", function()
		local shared = ledgerStore()
		local h = boot({ shared = shared, definitions = { definition("limited", { maxUses = 1 }) } })
		local a, b = add(h, 1), add(h, 2)
		expect(h:use(Codes).redeem(a, "limited")).toBe("ok")
		expect(h:use(Codes).redeem(b, "limited")).toBe("limit_reached")
		local other = boot({ shared = shared, definitions = { definition("limited", { maxUses = 2 }) } })
		local c = add(other, 3)
		expect(other:use(Codes).redeem(c, "limited")).toBe("try_later")
		expect(other:use(Economy).balance(c)).toBe(0)
		expect(h:use(Codes).uses("limited")).toBe(1)
		expect(Ledger.valid(shared.values["cap/limited"])).toBe(true)
	end)
	it("reuses an uncertain reservation response without consuming another slot", function()
		local shared = ledgerStore()
		local raw, first = shared.update, true
		shared.update = function(key, fn)
			local ok, result = raw(key, fn)
			if first then
				first = false
				return false, nil
			end
			return ok, result
		end
		local h = boot({ shared = shared, definitions = { definition("uncertain", { maxUses = 1 }) } })
		local p = add(h)
		expect(h:use(Codes).redeem(p, "uncertain")).toBe("try_later")
		expect(h:use(Economy).balance(p)).toBe(0)
		expect(h:use(Codes).redeem(p, "uncertain")).toBe("ok")
		expect(Ledger.count(shared.values["cap/uncertain"])).toBe(1)
	end)
	it("rejects capped to uncapped transitions across independent runtimes", function()
		local shared = ledgerStore()
		local h = boot({ shared = shared, definitions = { definition("policy", { maxUses = 2 }) } })
		local p = add(h)
		expect(h:use(Codes).redeem(p, "policy")).toBe("ok")
		local other = boot({ shared = shared, definitions = { definition("policy") } })
		local q = add(other, 2)
		expect(other:use(Codes).redeem(q, "policy")).toBe("try_later")
		expect(other:use(Economy).balance(q)).toBe(0)
	end)
	it("shares the busy gate with eligibility callbacks", function()
		local h = boot({ definitions = { definition("gated", { requires = { { kind = "custom" } } }) } })
		local p = add(h)
		local nested
		h:use(Codes).registerRequirement("custom", function(player)
			nested = h:use(Codes).redeem(player, "gated")
			return true
		end)
		expect(h:use(Codes).redeem(p, "gated")).toBe("ok")
		expect(nested).toBe("try_later")
		expect(h:use(Economy).balance(p)).toBe(10)
	end)

	it("rechecks its kill switch after a custom eligibility callback", function()
		local h = boot({
			isStudio = true,
			flags = { promotions = { default = true } },
			config = { flag = "promotions" },
			definitions = { definition("flagged", { requires = { { kind = "switch" } } }) },
		})
		local p = add(h)
		h:use(Codes).registerRequirement("switch", function()
			h:console("flags", "set", "promotions", "false")
			return true
		end)
		expect(h:use(Codes).redeem(p, "flagged")).toBe("try_later")
		expect(h:use(Economy).balance(p)).toBe(0)
	end)

	it("grants items and a disclosed free roll through normal dependency transaction APIs", function()
		local h = boot({
			modules = { Items, Inventory, Rarity },
			items = { { id = "stone", name = "Stone", rarity = "Common" } },
			moduleConfig = {
				Rarity = { rarityTables = { free = { entries = { { itemId = "stone", weight = 1 } } } } },
			},
			definitions = {
				definition(
					"collection",
					{ rewards = { { kind = "item", itemId = "stone" }, { kind = "roll", tableId = "free" } } }
				),
			},
		})
		local p = add(h)
		h:fire(p, "StateInit")
		expect(h:use(Codes).redeem(p, "collection")).toBe("ok")
		expect(#h:use(Inventory).list(p)).toBe(2)
		expect(h:use(Economy).balance(p)).toBe(0)
	end)

	it("enforces time, test environment, eligibility and brute-force lockout", function()
		local h = boot({
			env = "live",
			config = { failureLimit = 3, lockoutSeconds = 5 },
			definitions = {
				definition("expired", { expiresAt = 1 }),
				definition("future", { startsAt = 2e9 }),
				definition("test", { testOnly = true }),
			},
		})
		local p = add(h)
		expect(h:use(Codes).redeem(p, "expired")).toBe("expired")
		expect(h:use(Codes).redeem(p, "future")).toBe("not_yet")
		expect(h:use(Codes).redeem(p, "test")).toBe("invalid")
		expect(h:use(Codes).redeem(p, "missing")).toBe("try_later")
		h:tick(6)
		expect(h:use(Codes).redeem(p, "missing")).toBe("invalid")
		expect(h:console("codes", "add", "extra", "secret")).toBe("test promotion refused in live")
	end)
	it("never sends typed text or full definitions to analytics, clients or console", function()
		local h = boot({
			serverConfig = { Codes = { definitions = { definition("private", { code = "PRIVATE_VALUE" }) } } },
		})
		local p = add(h)
		expect(h:use(Codes).redeem(p, "PRIVATE_VALUE")).toBe("ok")
		expect(string.find(h:console("codes", "list"), "PRIVATE_VALUE", 1, true)).toBe(nil)
		for _, entry in h.fake.analytics do
			for _, value in entry.fields or {} do
				expect(value == "PRIVATE_VALUE").toBe(false)
			end
		end
		for _, entry in h:sent("Codes") do
			for _, value in entry.args do
				expect(value == "PRIVATE_VALUE").toBe(false)
			end
		end
	end)
	it("refuses malformed inputs, missing custom requirement and paid currency rewards", function()
		local h = boot({ definitions = { definition("eligible", { requires = { { kind = "gate" } } }) } })
		local p = add(h)
		for _, raw in { "", string.rep("x", 65), "\nhello", false, {} } do
			expect(h:use(Codes).redeem(p, raw)).toBe("invalid")
		end
		h:tick(301)
		expect(h:use(Codes).redeem(p, "eligible")).toBe("not_eligible")
		local paid = boot({ compliance = { paidCurrencies = { "Coins" } } })
		local q = add(paid)
		expect(paid:use(Codes).redeem(q, "hello")).toBe("try_later")
		expect(paid:use(Economy).balance(q)).toBe(0)
	end)
end)

describe("Codes live catalog", function()
	it("adds/disables cached live codes and retains last good state after malformed payload", function()
		local fake = StudWork.test.fakes.configService({
			values = { player_codes = { definitions = { definition("live") } } },
		})
		local h = boot({
			services = { ConfigService = fake },
			config = { live = { enabled = true, refreshSeconds = 5 } },
		})
		task.wait()
		local p = add(h)
		expect(h:use(Codes).redeem(p, "live")).toBe("ok")
		fake.set("player_codes", { definitions = { definition("live") }, disabled = { "hello" } })
		fake.publish()
		h:tick(5)
		task.wait()
		expect(h:use(Codes).redeem(p, "hello")).toBe("invalid")
		fake.set("player_codes", "bad payload")
		fake.publish()
		h:tick(5)
		task.wait()
		expect(h:use(Codes).redeem(p, "hello")).toBe("invalid")
		local initialReads = 0
		for _, call in fake.calls do
			if call.method == "GetConfigAsync" then
				initialReads += 1
			end
		end
		expect(initialReads).toBe(1)
		h:shutdown()
	end)
	it("keeps static codes available when the first live read fails", function()
		local fake = StudWork.test.fakes.configService({ failNext = 1 })
		local h = boot({
			services = { ConfigService = fake },
			config = { live = { enabled = true, refreshSeconds = 5 } },
		})
		task.wait()
		local p = add(h)
		expect(h:use(Codes).redeem(p, "hello")).toBe("ok")
		h:tick(5)
		task.wait()
		local n = 0
		for _, call in fake.calls do
			if call.method == "GetConfigAsync" then
				n += 1
			end
		end
		expect(n).toBe(2)
		h:shutdown()
	end)

	it("prunes settled removed live ids while keeping base identities", function()
		local fake = StudWork.test.fakes.configService({
			values = { player_codes = { definitions = { definition("temporary") } } },
		})
		local h, context = boot({
			services = { ConfigService = fake },
			config = { live = { enabled = true, refreshSeconds = 5 } },
		})
		task.wait()
		local p = add(h)
		expect(h:use(Codes).redeem(p, "temporary")).toBe("ok")
		expect(h:use(Codes).redeem(p, "hello")).toBe("ok")
		fake.set("player_codes", { definitions = {} })
		fake.publish()
		h:tick(5)
		task.wait()
		expect(context().data.get(p).redeemed.temporary).toBe(nil)
		expect(context().data.get(p).redeemed.hello).toBe(true)
		h:shutdown()
	end)

	it("recovers a removed pending definition without consulting eligibility or regranting", function()
		local shared = ledgerStore()
		local h, context = boot({ shared = shared, definitions = { definition("old", { maxUses = 1 }) } })
		local p = add(h)
		h.store.failNext(1)
		expect(h:use(Codes).redeem(p, "old")).toBe("try_later")
		expect(h:use(Codes).disable("old")).toBe(true)
		expect(h:use(Codes).redeem(p, "old")).toBe("invalid")
		expect(context().data.get(p).pending.old).toBe(nil)
		expect(shared.values["cap/old"].used).toBe(1)
		expect(h:use(Economy).balance(p)).toBe(10)
	end)
	it("recovers persisted pending receipts after their definition is removed on another runtime", function()
		local shared, store = ledgerStore(), StudWork.test.memoryStore()
		local first =
			boot({ store = store, shared = shared, definitions = { definition("retired", { maxUses = 1 }) } })
		local p = add(first)
		store.failNext(1)
		expect(first:use(Codes).redeem(p, "retired")).toBe("try_later")
		first:removePlayer(p)
		local second, context =
			boot({ store = store, shared = shared, definitions = { definition("current") } })
		local q = add(second)
		expect(context().data.get(q).pending.retired).toBe(nil)
		expect(shared.values["cap/retired"].used).toBe(1)
		expect(second:use(Economy).balance(q)).toBe(10)
		expect(second:use(Codes).redeem(q, "retired")).toBe("invalid")
	end)
end)

describe("Codes counter transforms", function()
	it("is retry-safe, immutable and fail-closed for corrupt or conflicting ledgers", function()
		local a = Ledger.reserve(nil, 1, "token")
		local b = Ledger.reserve(a, 1, "other")
		expect(a).toEqual(b)
		local c = Ledger.finish(a, "token", true)
		expect(a.used).toBe(0)
		expect(c.used).toBe(1)
		expect(Ledger.finish(c, "token", true).used).toBe(1)
		expect(Ledger.reserve(c, 2, "other").limit).toBe(1)
		expect(Ledger.valid({ version = 1, limit = 1, used = 0 / 0, reserved = {} })).toBe(false)
		expect(Ledger.valid({ version = 1, limit = 1, used = 1, reserved = { other = true } })).toBe(false)
	end)
	it("rejects oversized live payloads and skips malformed individual entries", function()
		local cfg = table.clone(require(Modules.Codes.shared.Rules).DEFAULTS)
		local warned = 0
		local ok, entries = Catalog.live(
			{ definitions = { { id = "bad" }, definition("good") } },
			cfg,
			function()
				warned += 1
			end
		)
		expect(ok).toBe(true)
		expect(#entries).toBe(1)
		expect(warned).toBe(1)
		expect(Catalog.live({ definitions = {}, extra = string.rep("x", 90001) }, cfg, function() end)).toBe(
			false
		)
	end)
end)
