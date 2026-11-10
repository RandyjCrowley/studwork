--!nocheck
-- Boot sequence (§3), StudWork.use / sugar (§4, C1), ctx (§5), lifecycle, fail-closed (N7).
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

local Base = mod("Base", {
	config = { schema = { step = "number", label = "string?" }, defaults = { step = 1 } },
	data = { key = "base", version = 1, default = { total = 0 } },
})
local Top = mod("Top", { dependsOn = { Base }, data = { key = "top", version = 1, default = { seen = 0 } } })
local Missing = mod("Missing")
local Soft = mod("Soft", { optional = { Missing, Base } })

describe("boot order and lifecycle", function()
	it("runs init for every module in order, then start for every module in order", function()
		local calls = {}
		local function impl(name)
			return {
				init = function()
					table.insert(calls, name .. ".init")
				end,
				start = function()
					table.insert(calls, name .. ".start")
				end,
			}
		end
		Harness.new({ modules = { Top, Base }, servers = { Top = impl("Top"), Base = impl("Base") } })
		expect(table.concat(calls, ",")).toBe("Base.init,Top.init,Base.start,Top.start")
	end)

	it("fires onPlayerLoaded / onTick / onPlayerRemoving / onShutdown", function()
		local log = {}
		local h = Harness.new({
			modules = { Base },
			servers = {
				Base = {
					init = function(ctx)
						ctx.lifecycle.onPlayerLoaded(function(p)
							table.insert(log, "loaded " .. p.Name .. " " .. tostring(ctx.data.isLoaded(p)))
						end)
						ctx.lifecycle.onTick(5, function(dt)
							table.insert(log, "tick " .. dt)
						end)
						ctx.lifecycle.onPlayerRemoving(function(p)
							table.insert(log, "removing " .. p.Name)
						end)
						ctx.lifecycle.onShutdown(function()
							table.insert(log, "shutdown")
						end)
					end,
				},
			},
		})
		local p = h:addPlayer({ userId = 1, name = "Ann" })
		h:tick(12)
		h:shutdown()
		expect(table.concat(log, "|")).toBe("loaded Ann true|tick 5|tick 5|shutdown|removing Ann")
		expect(h:saved(p).base.total).toBe(0)
	end)

	it("init must not yield", function()
		local _, err = Harness.boot({
			modules = { Base },
			servers = { Base = {
				init = function()
					coroutine.yield()
				end,
			} },
		})
		expect(err).toContain("Base.init yielded")
	end)

	it("init may not call other modules' APIs; start may", function()
		local got
		local servers = {
			Base = { api = {
				value = function()
					return 42
				end,
			} },
			Top = {
				init = function(ctx)
					local _, e = pcall(ctx.deps[Base].value)
					got = e
				end,
				start = function(ctx)
					got = got .. " / start=" .. ctx.deps[Base].value()
				end,
			},
		}
		Harness.new({ modules = { Base, Top }, servers = servers })
		expect(got).toContain("Base.api.value called during init")
		expect(got).toContain("start=42")
	end)
end)

describe("fail closed (N7)", function()
	it("a throwing start fails the boot; every later call errors with the boot message", function()
		local ctxRef
		local _, err = Harness.boot({
			modules = { Base, Top },
			servers = {
				Base = {
					init = function(ctx)
						ctxRef = ctx
					end,
					api = {
						ping = function()
							return "pong"
						end,
					},
				},
				Top = {
					start = function()
						error("kaboom")
					end,
				},
			},
		})
		expect(err).toContain("boot failed")
		expect(err).toContain("Top.start failed")
		expect(err).toContain("kaboom")
		expect(function()
			StudWork.use(Base)
		end).toThrow("boot failed")
		expect(function()
			local _ = StudWork.Base
		end).toThrow("boot failed")
		expect(function()
			ctxRef.data.get({})
		end).toThrow("boot failed")
		expect(function()
			ctxRef.tx({}, function() end)
		end).toThrow("boot failed")
	end)

	it("invalid config fails boot listing every error", function()
		local _, err = Harness.boot({
			modules = { Base, Top },
			config = { Base = { step = "fast", label = 3 } },
			items = { { id = "a", name = "A", mystery = {} } },
		})
		expect(err).toContain("config.Base.step: expected number")
		expect(err).toContain("config.Base.label: expected string")
		expect(err).toContain("items[1].mystery")
	end)

	it("missing hard dependency fails boot", function()
		local _, err = Harness.boot({ modules = { Top } })
		expect(err).toContain("module 'Top' requires 'Base': add Base to GameConfig.modules")
	end)
end)

describe("StudWork.use (§4, C1)", function()
	it("returns the frozen API of an enabled module, an erroring proxy for a disabled one", function()
		local h = Harness.new({
			modules = { Base },
			servers = { Base = { api = {
				ping = function()
					return "pong"
				end,
			} } },
		})
		local api = StudWork.use(Base)
		expect(api.ping()).toBe("pong")
		expect(table.isfrozen(api)).toBe(true)
		expect(StudWork.Base.ping()).toBe("pong") -- untyped sugar
		local proxy = StudWork.use(Missing)
		expect(proxy).Not.toBeNil()
		expect(function()
			proxy.anything()
		end).toThrow("Missing is not enabled in GameConfig.modules")
		expect(h:use(Base).ping()).toBe("pong")
	end)

	it("accepts only a ModuleRef; framework internals are unreachable", function()
		Harness.new({ modules = { Base } })
		for _, name in { "Data", "Compliance", "Net", "Replication", "Shop", "Policy" } do
			expect(function()
				StudWork.use(name)
			end).toThrow("framework internal")
			expect(function()
				local _ = StudWork[name]
			end).toThrow("framework internal")
		end
		expect(function()
			StudWork.use("Base")
		end).toThrow("expects a ModuleRef")
		expect(function()
			StudWork.use({ name = "Base" })
		end).toThrow("expects a ModuleRef")
		expect(function()
			local _ = StudWork.Nope
		end).toThrow("no enabled module named Nope")
	end)

	it("errors before StudWork.start (during boot)", function()
		local err
		Harness.new({
			modules = { Base },
			servers = {
				Base = {
					init = function()
						local _, e = pcall(StudWork.use, Base)
						err = e
					end,
				},
			},
		})
		expect(tostring(err)).toContain("called before StudWork.start")
	end)
end)

describe("ctx (§5)", function()
	it("is frozen and scoped to the module", function()
		local c
		local h = Harness.new({
			modules = { Base, Soft },
			config = { Base = { label = "hi" } },
			serverConfig = { Base = { admins = { 1 } }, Soft = { secret = true } },
			items = { { id = "pebble", name = "Pebble" } },
			servers = { Base = {
				init = function(ctx)
					c = ctx
				end,
			} },
		})
		expect(table.isfrozen(c)).toBe(true)
		expect(c.name).toBe("Base")
		expect(c.config.step).toBe(1)
		expect(c.config.label).toBe("hi")
		expect(table.isfrozen(c.config)).toBe(true)
		expect(c.gameConfig.gameId).toBe("test-game")
		expect(c.gameConfig.items[1].id).toBe("pebble")
		expect(c.gameConfig.config).toBeNil() -- no other modules' config
		expect(c.serverConfig.admins[1]).toBe(1)
		expect(c.serverConfig.secret).toBeNil()
		expect(c.isStudio).toBe(false)
		expect(c.theme.colors.accent).toBe("#FF8A3D")
		expect(table.isfrozen(c.theme)).toBe(true)
		for _, field in
			{
				"net",
				"replicate",
				"compliance",
				"policy",
				"analytics",
				"events",
				"shop",
				"signals",
				"console",
				"lifecycle",
				"log",
				"framework",
				"data",
			}
		do
			assert(c[field] ~= nil, "ctx." .. field .. " missing")
		end
		c.log.info("hello")
		expect(h.logs[#h.logs].msg).toBe("[Base] hello")
	end)

	it(
		"deps contain exactly the declared dependencies; disabled optional deps are erroring proxies",
		function()
			local c
			Harness.new({
				modules = { Base, Soft },
				servers = {
					Base = { api = {
						v = function()
							return 1
						end,
					} },
					Soft = {
						init = function(ctx)
							c = ctx
						end,
					},
				},
			})
			expect(c.isEnabled(Base)).toBe(true)
			expect(c.isEnabled(Missing)).toBe(false)
			expect(function()
				c.deps[Missing].x()
			end).toThrow("Missing is not enabled in GameConfig.modules")
			expect(function()
				local _ = c.deps[Top]
			end).toThrow("'Top' is not a declared dependency")
			expect(function()
				c.section({})
			end).toThrow("needs a save section")
		end
	)

	it("signals, console prefix and framework services behave", function()
		local c
		local h = Harness.new({
			modules = { Base },
			servers = {
				Base = {
					init = function(ctx)
						c = ctx
						local s = ctx.signals.new("Changed")
						ctx.console.register("grant", function(player, amount)
							s:Fire(player, tonumber(amount))
							return "ok"
						end)
					end,
				},
			},
		})
		local got
		c.signals.Changed:Connect(function(_, n)
			got = n
		end)
		local ok, res = h.runtime.runConsole(nil, "base grant 5")
		expect(ok).toBe(true)
		expect(res).toBe("ok")
		expect(got).toBe(5)
		-- step 4b: the framework services behind ctx are real (no stubs left)
		expect(function()
			c.compliance.roll()
		end).toThrow("must be the OPEN tx")
		local p = h:addPlayer({ userId = 7 })
		c.replicate.set(p, "rate", 3)
		h:tick(1)
		expect(h.runtime.replication.peek(p).modules.Base.extra.rate).toBe(3)
	end)
end)
