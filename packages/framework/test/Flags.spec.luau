--!nocheck
--[[
	v1.7.0 feature flags (module-api.md §23.2, docs/framework/kits/environments.md): resolution per
	environment, the boot errors, testOnly never on in live, serverOnly and ServerConfig.flags never
	replicated and erroring on the client, the client resolver equal to the server's, and
	StudWork.flags / ctx.flags on a booted server.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Framework = ReplicatedStorage:WaitForChild("Framework")
local StudWork = require(Framework)
local Flags = require(Framework:WaitForChild("Flags"))

local DEFS = {
	newShop = { default = false, studio = true, test = true },
	weekly = { default = true },
	debugPanel = { testOnly = true, default = false, studio = true, test = true },
	prices = { default = true, serverOnly = true },
	pinned = { default = false, override = false, description = "never overridden" },
}

local function side(name, envName, extra)
	local o = { flags = DEFS, envName = envName, side = name }
	for k, v in extra or {} do
		o[k] = v
	end
	return Flags.new(o)
end

local function boot(opts)
	local captured = {}
	local o = {
		modules = { StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" }) },
		servers = {
			Probe = {
				init = function(ctx)
					captured.ctx = ctx
				end,
			},
		},
	}
	for k, v in opts or {} do
		o[k] = v
	end
	local h, err = StudWork.test.boot(o)
	return h, err, captured.ctx
end

describe("Flags.resolve", function()
	it("takes the environment's field, else default", function()
		expect(Flags.resolve(DEFS.newShop, "studio")).toBe(true)
		expect(Flags.resolve(DEFS.newShop, "test")).toBe(true)
		expect(Flags.resolve(DEFS.newShop, "live")).toBe(false)
		expect(Flags.resolve(DEFS.weekly, "live")).toBe(true)
		expect(Flags.resolve({ default = true, live = false }, "live")).toBe(false)
		expect(Flags.resolve({ default = true, live = false }, "test")).toBe(true)
	end)
end)

describe("Flags.validate", function()
	it("accepts the documented example", function()
		expect(#Flags.validate(DEFS, nil)).toBe(0)
	end)

	it("a testOnly flag whose live value would be true is an error (live field or default)", function()
		local errors = Flags.validate({
			a = { testOnly = true, default = false, live = true },
			b = { testOnly = true, default = true },
			c = { testOnly = true, default = true, live = false }, -- fine: off in live
		}, { d = { testOnly = true, default = true } })
		expect(#errors).toBe(3)
		local text = table.concat(errors, "\n")
		expect(text).toContain(
			"flags.a is testOnly but would be on in live (set live = false or default = false)"
		)
		expect(text).toContain("flags.b is testOnly")
		expect(text).toContain("ServerConfig.flags.d is testOnly")
	end)

	it("reports a missing default, unknown and mistyped fields, bad names, and a name clash", function()
		local errors = Flags.validate({
			noDefault = { test = true },
			typo = { default = true, tset = true },
			wrong = { default = true, live = "no" },
			["9lives"] = { default = true },
			[string.rep("a", 49)] = { default = true },
			notTable = true,
			both = { default = true },
		}, { both = { default = false } })
		local text = table.concat(errors, "\n")
		expect(text).toContain("flags.noDefault.default is required")
		expect(text).toContain("flags.typo.tset: unknown field")
		expect(text).toContain("flags.wrong.live must be a boolean")
		expect(text).toContain("flags.9lives: flag names match")
		expect(text).toContain("flags.notTable must be a table")
		expect(text).toContain("flags.both is declared in both GameConfig.flags and ServerConfig.flags")
		expect(#Flags.validate({ [string.rep("a", 48)] = { default = true } }, nil)).toBe(0)
		expect(#Flags.validate("on", nil)).toBe(1)
	end)
end)

describe("Flags.new (server)", function()
	it("resolves every flag for its environment, source config", function()
		local s = side("server", "test")
		expect(s.api.isOn("newShop")).toBe(true)
		expect(s.api.isOn("debugPanel")).toBe(true)
		expect(s.api.isOn("prices")).toBe(true) -- serverOnly is readable on the server
		expect(s.api.source("newShop")).toBe("config")
		local live = side("server", "live")
		expect(live.api.isOn("newShop")).toBe(false)
		expect(live.api.isOn("debugPanel")).toBe(false)
	end)

	it("an undeclared name errors on every call", function()
		local s = side("server", "live")
		expect(function()
			s.api.isOn("nope")
		end).toThrow("unknown flag 'nope'")
		expect(function()
			s.api.onChanged("nope", function() end)
		end).toThrow("unknown flag")
		expect(function()
			s.api.source("nope")
		end).toThrow("unknown flag")
	end)

	it("override > environment field > default; clearing goes back to config", function()
		local s = side("server", "live")
		local seen = {}
		s.api.onChanged("newShop", function(on)
			table.insert(seen, on)
		end)
		expect(s.setOverride("newShop", true)).toBe(true)
		expect(s.api.isOn("newShop")).toBe(true)
		expect(s.api.source("newShop")).toBe("override")
		s.setOverride("newShop", true) -- no change: no event
		s.setOverride("newShop", nil)
		expect(s.api.isOn("newShop")).toBe(false)
		expect(s.api.source("newShop")).toBe("config")
		expect(#seen).toBe(2)
		expect(seen[1]).toBe(true)
		expect(seen[2]).toBe(false)
	end)

	it("an override can't switch a testOnly flag on in live; it can in test", function()
		local logs = {}
		local live = side("server", "live", {
			log = function(m)
				table.insert(logs, m)
			end,
		})
		local ok, reason = live.setOverride("debugPanel", true)
		expect(ok).toBe(false)
		expect(reason).toBe("test_only")
		expect(live.api.isOn("debugPanel")).toBe(false)
		expect(#logs).toBe(1)
		expect(live.setOverride("debugPanel", false)).toBe(true) -- switching it off is fine
		local test = side("server", "test")
		test.setOverride("debugPanel", nil)
		expect(test.setOverride("debugPanel", false)).toBe(true)
		expect(test.api.isOn("debugPanel")).toBe(false)
		expect(test.setOverride("debugPanel", true)).toBe(true)
		expect(test.api.isOn("debugPanel")).toBe(true)
	end)

	it("override = false refuses an override", function()
		local s = side("server", "live")
		local ok, reason = s.setOverride("pinned", true)
		expect(ok).toBe(false)
		expect(reason).toBe("not_overridable")
		expect(s.overridable("pinned")).toBe(false)
		expect(s.overridable("newShop")).toBe(true)
		expect(s.overridable("nope")).toBe(false)
	end)

	it("all() is frozen; replicated() leaves out serverOnly and ServerConfig.flags", function()
		local s = side("server", "live", { serverFlags = { hidden = { default = true } } })
		local all = s.api.all()
		expect(table.isfrozen(all)).toBe(true)
		expect(all.prices).toBe(true)
		expect(all.hidden).toBe(true)
		local wire = s.replicated()
		expect(wire.prices).toBeNil()
		expect(wire.hidden).toBeNil()
		expect(wire.weekly).toBe(true)
		expect(s.isHidden("hidden")).toBe(true)
	end)
end)

describe("Flags.new (client)", function()
	it("resolves exactly what the server resolves, for every replicated flag in every environment", function()
		for _, envName in { "studio", "test", "live" } do
			local server = side("server", envName)
			local client = side("client", envName)
			local wire = server.replicated()
			local clientAll = client.api.all()
			for name, on in wire do
				expect(clientAll[name]).toBe(on)
			end
			for name in clientAll do
				expect(wire[name]).never.toBeNil()
			end
		end
	end)

	it("serverOnly flags error on the client and are left out of all()", function()
		local c = side("client", "live")
		expect(function()
			c.api.isOn("prices")
		end).toThrow("'prices' is serverOnly")
		expect(function()
			c.api.onChanged("prices", function() end)
		end).toThrow("serverOnly")
		expect(function()
			c.api.source("prices")
		end).toThrow("serverOnly")
		expect(c.api.all().prices).toBeNil()
		-- ServerConfig.flags never reach the client: an unknown name
		local withHidden = side("client", "live", { serverFlags = { hidden = { default = true } } })
		expect(function()
			withHidden.api.isOn("hidden")
		end).toThrow("unknown flag")
	end)

	it("takes the server's replicated values, never for a serverOnly or unknown flag", function()
		local c = side("client", "live")
		local seen = {}
		c.api.onChanged("newShop", function(on)
			table.insert(seen, on)
		end)
		c.applyReplicated({ newShop = true, prices = false, ghost = true, weekly = "x" })
		expect(c.api.isOn("newShop")).toBe(true)
		expect(c.api.source("newShop")).toBe("override")
		expect(c.api.isOn("weekly")).toBe(true)
		expect(c.api.all().prices).toBeNil()
		expect(c.api.all().ghost).toBeNil()
		c.applyReplicated({ newShop = false })
		expect(c.api.source("newShop")).toBe("config")
		expect(#seen).toBe(2)
	end)
end)

describe("flags on a booted server", function()
	it("StudWork.flags and ctx.flags agree; a change fires onChanged and re-replicates", function()
		local h, err, ctx = boot({ flags = DEFS, env = "live", isStudio = true })
		expect(err).toBeNil()
		for _, name in { "newShop", "weekly", "debugPanel", "prices", "pinned" } do
			expect(StudWork.flags.isOn(name)).toBe(ctx.flags.isOn(name))
		end
		local p = h:addPlayer({ userId = 1 })
		expect(h:state(p).framework.flags.newShop).toBe(false)
		local fired = {}
		StudWork.flags.onChanged("newShop", function(on)
			table.insert(fired, on)
		end)
		h:console("flags set newShop true")
		expect(fired[1]).toBe(true)
		expect(h:state(p).framework.flags.newShop).toBe(true)
		expect(h:state(p).framework.flags.prices).toBeNil()
		expect(ctx.flags.isOn("newShop")).toBe(true)
		h:console("flags set newShop clear")
		expect(h:state(p).framework.flags.newShop).toBe(false)
	end)

	it("the console can't switch a testOnly flag on in live", function()
		local h, _, ctx = boot({ flags = DEFS, env = "live", isStudio = true })
		h:console("flags set debugPanel true")
		expect(ctx.flags.isOn("debugPanel")).toBe(false)
	end)

	it("a testOnly flag on in live is a boot error, also when declared in ServerConfig.flags", function()
		local h, err = boot({ serverConfig = { flags = { dbg = { testOnly = true, default = true } } } })
		expect(h).toBeNil()
		expect(err).toContain("ServerConfig.flags.dbg is testOnly but would be on in live")
	end)
end)
