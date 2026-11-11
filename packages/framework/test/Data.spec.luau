--!nocheck
-- Per-module save sections and transactions (module-api.md §5.1, §5.2, §6; H1, H2, H5, M1, M3).
local StudWork = require(script.Parent.Parent.shared)
local Harness = require(script.Parent.harness)
local FrameworkSection = require(script.Parent.Parent.server.FrameworkSection)

local def = StudWork.defineModule

local sanitizeCalls = 0
local Greeter = def({
	name = "Greeter",
	version = "1.0.0",
	framework = "^1.3.0",
	data = {
		key = "greeter",
		version = 3,
		default = { visits = 0, greeting = "hello", junk = nil },
		migrations = script.Parent.fixtures.greeter_migrations, -- 002_*, 003_* (folder of NNN_*.luau)
		sanitize = function(section)
			sanitizeCalls += 1
			if section.visits < 0 then
				section.visits = 0
			end
			return section
		end,
		replicate = { "visits" },
	},
})

local Counter = def({
	name = "Counter",
	version = "1.0.0",
	framework = "^1.3.0",
	data = { key = "counter", version = 1, default = { n = 0 } },
})

local counterCtx, greeterCtx
local servers = {
	Greeter = {
		init = function(ctx)
			greeterCtx = ctx
		end,
		api = {
			visit = function(player)
				return greeterCtx.data.update(player, function(s)
					s.visits += 1
				end)
			end,
		},
	},
	Counter = {
		init = function(ctx)
			counterCtx = ctx
		end,
		api = {
			bump = function(player)
				return counterCtx.tx(player, function(tx)
					counterCtx.section(tx).n += 1
				end)
			end,
		},
	},
}

local function boot(modules)
	sanitizeCalls = 0
	return Harness.new({ modules = modules or { Greeter, Counter }, servers = servers })
end

describe("sections: migrations, sanitize, defaults", function()
	it("a module's own section round-trips through its migrations folder", function()
		local h = boot()
		local p = h:addPlayer({
			userId = 1,
			data = {
				_framework = {
					schemaVersion = 2,
					firstJoin = 10,
					lastSeen = 20,
					_owners = { greeter = "Greeter" },
				},
				_versions = { greeter = 1 },
				greeter = { count = 4 },
			},
		})
		expect(p.loaded).toBe(true)
		local view = greeterCtx.data.get(p)
		expect(view.visits).toBe(4)
		expect(view.count).toBeNil()
		expect(view.greeting).toBe("welcome back")
		h:rejoin(p)
		local saved = h:saved(p)
		expect(saved._versions.greeter).toBe(3)
		expect(saved.greeter.visits).toBe(4)
		expect(greeterCtx.data.get(p).visits).toBe(4) -- reloads cleanly at the current version
	end)

	it("sanitize runs exactly once per load, after migrations", function()
		local h = boot()
		local p = h:addPlayer({
			userId = 2,
			data = {
				_framework = { schemaVersion = 2, _owners = {} },
				_versions = { greeter = 2 },
				greeter = { visits = -5 },
			},
		})
		expect(sanitizeCalls).toBe(1)
		expect(greeterCtx.data.get(p).visits).toBe(0)
		h:use(Greeter).visit(p)
		expect(sanitizeCalls).toBe(1) -- not on tx / save
		h:rejoin(p)
		expect(sanitizeCalls).toBe(2)
	end)

	it("new players get each module's default and the _framework section", function()
		local h = boot()
		local p = h:addPlayer({ userId = 3 })
		expect(greeterCtx.data.get(p).visits).toBe(0)
		expect(counterCtx.data.get(p).n).toBe(0)
		expect(counterCtx.framework.firstJoin(p)).toBe(h.clock)
		h:tick(100)
		h:removePlayer(p)
		local saved = h:saved(p)
		expect(saved._framework._owners.greeter).toBe("Greeter")
		expect(saved._framework._owners.counter).toBe("Counter")
		expect(saved._framework.lastSeen).toBe(h.clock)
		expect(saved._framework.firstJoin).toBe(h.clock - 100)
	end)

	it("a failing migration loads nothing, kicks, and never saves over the stored data", function()
		local Broken = def({
			name = "Broken",
			version = "1.0.0",
			framework = "^1.3.0",
			data = {
				key = "broken",
				version = 2,
				default = {},
				migrations = {
					[2] = function()
						error("boom")
					end,
				},
			},
		})
		local h = Harness.new({ modules = { Broken }, servers = {} })
		local original = {
			_framework = { schemaVersion = 2, _owners = {} },
			_versions = { broken = 1 },
			broken = { v = 1 },
		}
		local p = h:addPlayer({ userId = 4, data = original })
		expect(p.loaded).toBe(false)
		expect(p.kicked).toContain("couldn't be loaded")
		h:removePlayer(p)
		expect(h:saved(p).broken.v).toBe(1)
		expect(h:saved(p)._versions.broken).toBe(1)
	end)

	it("a section written by newer code is not loaded", function()
		local h = boot({ Counter })
		local p = h:addPlayer({
			userId = 5,
			data = {
				_framework = { schemaVersion = 2, _owners = {} },
				_versions = { counter = 9 },
				counter = { n = 1 },
			},
		})
		expect(p.loaded).toBe(false)
	end)
end)

describe("disabled modules", function()
	it("sections of modules that aren't enabled survive saves untouched", function()
		local h1 = boot({ Greeter, Counter })
		local p = h1:addPlayer({ userId = 10 })
		h1:use(Counter).bump(p)
		h1:use(Counter).bump(p)
		h1:removePlayer(p)
		-- same store, Counter switched off
		local h2 = Harness.new({ modules = { Greeter }, servers = servers, store = h1.store })
		local p2 = h2:addPlayer({ userId = 10 })
		h2:use(Greeter).visit(p2)
		h2:removePlayer(p2)
		local saved = h2:saved(p2)
		expect(saved.counter.n).toBe(2)
		expect(saved._versions.counter).toBe(1)
		expect(saved._framework._owners.counter).toBe("Counter")
		expect(saved.greeter.visits).toBe(1)
	end)
end)

describe("owner registry", function()
	local Squatter = def({
		name = "Squatter",
		version = "1.0.0",
		framework = "^1.3.0",
		data = { key = "counter", version = 1, default = { other = true } },
	})
	local Heir = def({
		name = "Heir",
		version = "1.0.0",
		framework = "^1.3.0",
		data = { key = "counter", version = 1, default = { n = 0 }, adopts = "Counter" },
	})

	it("an unrelated module claiming a disabled module's key is a load error naming both", function()
		local h1 = boot({ Counter })
		local p = h1:addPlayer({ userId = 20 })
		h1:use(Counter).bump(p)
		h1:removePlayer(p)
		local h2 = Harness.new({ modules = { Squatter }, servers = {}, store = h1.store })
		local p2 = h2:addPlayer({ userId = 20 })
		expect(p2.loaded).toBe(false)
		local warns = table.concat(h2:warnings(), "\n")
		expect(warns).toContain(
			"save section 'counter' belongs to module 'Counter', but module 'Squatter' now claims it"
		)
		h2:removePlayer(p2)
		expect(h2:saved(p2).counter.n).toBe(1) -- untouched
	end)

	it("data.adopts takes the section over and records the new owner", function()
		local h1 = boot({ Counter })
		local p = h1:addPlayer({ userId = 21 })
		h1:use(Counter).bump(p)
		h1:removePlayer(p)
		local h2 = Harness.new({ modules = { Heir }, servers = {}, store = h1.store })
		local p2 = h2:addPlayer({ userId = 21 })
		expect(p2.loaded).toBe(true)
		h2:removePlayer(p2)
		expect(h2:saved(p2)._framework._owners.counter).toBe("Heir")
		expect(h2:saved(p2).counter.n).toBe(1)
		expect(table.concat(h2:warnings(), "\n")).toContain(
			"Heir adopts save section 'counter' from module 'Counter'"
		)
	end)
end)

describe("transactions", function()
	it("tx is a sealed handle: no route from tx to any section", function()
		local h = boot()
		local p = h:addPlayer({ userId = 30 })
		local probes = {}
		counterCtx.tx(p, function(tx)
			probes.player = tx.player
			probes.after = type(tx.after)
			probes.retry = type(tx.retryLater)
			probes.dataErr = select(
				2,
				pcall(function()
					return tx.data
				end)
			)
			probes.raw = rawget(tx, "data")
			probes.rawSection = rawget(tx, "counter")
			local found = {}
			for k in pairs(tx) do
				table.insert(found, k)
			end
			probes.pairsCount = #found
			probes.nextKey = next(tx)
			probes.iterOk = pcall(function()
				local n = 0
				for _ in tx do
					n += 1
				end
				probes.iterCount = n
			end)
			probes.setOk = pcall(function()
				tx.data = {}
			end)
			probes.metaWritable = pcall(function()
				getmetatable(tx).__index = function()
					return "hijacked"
				end
			end)
			probes.frozen = table.isfrozen(tx)
			probes.counterKey = select(
				2,
				pcall(function()
					return tx.counter
				end)
			)
		end)
		expect(probes.player).toBe(p)
		expect(probes.after).toBe("function")
		expect(probes.retry).toBe("function")
		expect(tostring(probes.dataErr)).toContain("tx has no field 'data'")
		expect(tostring(probes.counterKey)).toContain("tx has no field 'counter'")
		expect(probes.raw).toBeNil()
		expect(probes.rawSection).toBeNil()
		expect(probes.pairsCount).toBe(0)
		expect(probes.nextKey).toBeNil()
		expect(probes.iterOk).toBe(false)
		expect(probes.setOk).toBe(false)
		expect(probes.metaWritable).toBe(false)
		expect(probes.frozen).toBe(true)
	end)

	it("ctx.section is bound to the calling module's own key", function()
		local h = boot()
		local p = h:addPlayer({ userId = 31 })
		counterCtx.tx(p, function(tx)
			counterCtx.section(tx).n = 7
			greeterCtx.section(tx).visits = 3
		end)
		expect(counterCtx.data.get(p).n).toBe(7)
		expect(greeterCtx.data.get(p).visits).toBe(3)
	end)

	it("only one tx per call stack; a different player's tx errors", function()
		local h = boot()
		local a = h:addPlayer({ userId = 32, name = "Alice" })
		local b = h:addPlayer({ userId = 33, name = "Bob" })
		local crossErr, nestedErr
		local ok = counterCtx.tx(a, function(tx)
			counterCtx.section(tx).n += 1
			local _, e = pcall(h:use(Greeter).visit, b) -- another module's mutating API, other player
			crossErr = e
			local _, e2 = pcall(counterCtx.tx, a, function() end)
			nestedErr = e2
			tx.after(function()
				h:use(Greeter).visit(b) -- the supported route
			end)
		end)
		expect(ok).toBe(true)
		expect(tostring(crossErr)).toContain(
			"tx open for Alice; use tx.after to act on another player once this one commits"
		)
		expect(tostring(nestedErr)).toContain("nested ctx.tx for the same player")
		expect(counterCtx.data.get(a).n).toBe(1)
		expect(greeterCtx.data.get(b).visits).toBe(1)
	end)

	it("errors discard every write and re-raise; after effects don't run", function()
		local h = boot()
		local p = h:addPlayer({ userId = 34 })
		local ran = false
		expect(function()
			counterCtx.tx(p, function(tx)
				counterCtx.section(tx).n = 99
				tx.after(function()
					ran = true
				end)
				error("nope")
			end)
		end).toThrow("nope")
		expect(counterCtx.data.get(p).n).toBe(0)
		expect(ran).toBe(false)
	end)

	it("yielding inside a tx is refused and discarded", function()
		local h = boot()
		local p = h:addPlayer({ userId = 35 })
		expect(function()
			counterCtx.tx(p, function(tx)
				counterCtx.section(tx).n = 5
				coroutine.yield()
			end)
		end).toThrow("must not yield")
		expect(counterCtx.data.get(p).n).toBe(0)
		-- the guard was released: a new tx works
		expect(h:use(Counter).bump(p)).toBe(true)
	end)

	it("retryLater discards the tx; unloaded players return false; a dead tx can't reach sections", function()
		local h = boot()
		local p = h:addPlayer({ userId = 36 })
		local kept
		local ok = counterCtx.tx(p, function(tx)
			counterCtx.section(tx).n = 4
			tx.retryLater()
			kept = tx
		end)
		expect(ok).toBe(false)
		expect(counterCtx.data.get(p).n).toBe(0)
		expect(function()
			counterCtx.section(kept)
		end).toThrow("this tx is closed")
		local ghost = Harness.player(999)
		expect(counterCtx.tx(ghost, function() end)).toBe(false)
	end)

	it("section versions move only for sections that changed", function()
		local h = boot()
		local p = h:addPlayer({ userId = 37 })
		local g0 = greeterCtx.data.sectionVersion(p)
		local c0 = counterCtx.data.sectionVersion(p)
		h:use(Counter).bump(p)
		counterCtx.tx(p, function(tx)
			local _ = greeterCtx.section(tx).visits -- read only
		end)
		expect(greeterCtx.data.sectionVersion(p)).toBe(g0)
		expect(counterCtx.data.sectionVersion(p)).Not.toBe(c0)
	end)
end)

describe("read views", function()
	it("ScopedData.get is frozen in every environment and cached per section version", function()
		for _, studio in { false, true } do
			local h = Harness.new({ modules = { Counter }, servers = servers, isStudio = studio })
			local p = h:addPlayer({ userId = 40 })
			local v1 = counterCtx.data.get(p)
			expect(table.isfrozen(v1)).toBe(true)
			expect(function()
				v1.n = 5
			end).toThrow()
			expect(counterCtx.data.get(p)).toBe(v1) -- cached
			h:use(Counter).bump(p)
			local v2 = counterCtx.data.get(p)
			expect(v2).Not.toBe(v1)
			expect(v2.n).toBe(1)
			expect(v1.n).toBe(0)
		end
	end)
end)

describe("v1.2 save migration (_framework 1 -> 2)", function()
	local v12 = {
		schemaVersion = 4,
		currency = { Coins = 120 },
		inventory = { u1 = { uid = "u1", itemId = "Pebble" } },
		displayed = { s1 = "u1" },
		upgrades = { speed = 2 },
		rebirths = 1,
		multipliers = {},
		streak = { day = 3 },
		lastSeen = 50,
		firstJoin = 5,
		purchases = { r1 = 10 },
		pity = { basic = 3 },
		stats = { totalEarned = 900 },
		funnel = { join = 5 },
		game = { ["test-game"] = { clues = 2 }, other = { x = 1 } },
		mail = { seen = {}, attempts = {}, dead = {} },
		mystery = true,
	}

	it("splits a flat v1.2 save into sections", function()
		local out = FrameworkSection.migrate(v12, "test-game", 99)
		expect(out._framework.schemaVersion).toBe(2)
		expect(out._framework.firstJoin).toBe(5)
		expect(out._framework.lastSeen).toBe(50)
		expect(out._framework.purchases.r1).toBe(10)
		expect(out._framework.stats.totalEarned).toBe(900)
		expect(out.economy.currency.Coins).toBe(120)
		expect(out.upgrades.upgrades.speed).toBe(2)
		expect(out.rebirth.rebirths).toBe(1)
		expect(out.inventory.inventory.u1.itemId).toBe("Pebble")
		expect(out.rarity.pity.basic).toBe(3)
		expect(out.plot.displayed.s1).toBe("u1")
		expect(out.mail.mail.dead).toEqual({})
		expect(out.streak.streak.day).toBe(3)
		expect(out["test-game"].clues).toBe(2)
		expect(out._versions.economy).toBe(0)
		expect(out._framework.legacy.mystery).toBe(true)
		expect(out._framework.legacy["game.other"].x).toBe(1)
		expect(v12.currency.Coins).toBe(120) -- input untouched
		expect(v12._framework).toBeNil()
	end)

	it("a kit's migration 001 receives the v1.2 shape when the save loads", function()
		local Economy = def({
			name = "Economy",
			version = "1.0.0",
			framework = "^1.3.0",
			data = {
				key = "economy",
				version = 1,
				default = { currency = {}, upgrades = {}, rebirths = 0 },
				migrations = {
					[1] = function(old)
						old.fromV12 = true
						return old
					end,
				},
			},
		})
		local h = Harness.new({ modules = { Economy }, servers = {} })
		local p = h:addPlayer({ userId = 50, data = v12 })
		expect(p.loaded).toBe(true)
		h:removePlayer(p)
		local saved = h:saved(p)
		expect(saved.economy.currency.Coins).toBe(120)
		expect(saved.economy.fromV12).toBe(true)
		expect(saved._framework._owners.economy).toBe("Economy")
		expect(saved.inventory.inventory.u1.itemId).toBe("Pebble") -- disabled kit's section carried
		expect(saved.schemaVersion).toBeNil()
	end)
end)
