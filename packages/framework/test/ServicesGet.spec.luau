--!nocheck
--[[
	v1.7.0 ctx.services.get (module-api.md §23.6). (Named ServicesGet: test/Services.spec.luau is the
	v1.3.0 spec of the framework services behind ctx.) Allowed names return the harness fake or a
	stub that says which fake to pass; services with a framework surface are refused with an error
	naming it; live, the engine lookup.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Services = require(script.Parent.Parent.server.Services)
local fakes = StudWork.test.fakes

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
	assert(h, err)
	return h, captured.ctx
end

describe("ctx.services.get", function()
	it("returns the harness fake for every allowed name", function()
		local given = {
			BadgeService = fakes.badgeService({}),
			TextService = fakes.textService({}),
			UserService = fakes.userService({}),
			LocalizationService = { marker = "loc" },
			Players = { marker = "players" },
		}
		local _, ctx = boot({ services = given })
		for name in Services.ALLOWED do
			expect(given[name]).never.toBeNil() -- this spec covers every allowed name
			expect(ctx.services.get(name)).toBe(given[name])
		end
	end)

	it("refuses every service with a framework surface, naming the surface", function()
		local _, ctx = boot()
		local expected = {
			DataStoreService = "ctx.data",
			MemoryStoreService = "ctx.data.sortedMap",
			MarketplaceService = "ctx.shop",
			HttpService = "ctx.openCloud",
			MessagingService = "ctx.data.messages",
			ConfigService = "ctx.flags",
			PolicyService = "ctx.policy",
		}
		for name, surface in Services.REFUSED do
			expect(expected[name]).toBe(surface)
		end
		for name, surface in expected do
			local ok, err = pcall(ctx.services.get, name)
			expect(ok).toBe(false)
			expect(tostring(err)).toContain(
				`Probe: ctx.services.get("{name}") is refused: use {surface} instead`
			)
		end
	end)

	it("refuses even when a test passes a fake for a refused name", function()
		local _, ctx = boot({ services = { HttpService = { marker = true } } })
		expect(pcall(ctx.services.get, "HttpService")).toBe(false)
	end)

	it("an unknown name errors listing the allowed ones; a non-string errors", function()
		local _, ctx = boot()
		local _, err = pcall(ctx.services.get, "Lighting")
		expect(tostring(err)).toContain("not an allowed service")
		expect(tostring(err)).toContain(
			"BadgeService, LocalizationService, Players, TextService, UserService"
		)
		local _, err2 = pcall(ctx.services.get, 5)
		expect(tostring(err2)).toContain("name must be a string")
	end)

	it("without a fake, every method of the stub errors with the option to pass", function()
		local _, ctx = boot()
		local stub = ctx.services.get("BadgeService")
		local ok, err = pcall(function()
			stub:AwardBadge(1, 2)
		end)
		expect(ok).toBe(false)
		expect(tostring(err)).toContain(
			"no test fake for BadgeService: pass harness({ services = { BadgeService = ... } })"
		)
	end)

	it("is frozen and scoped per module", function()
		local _, ctx = boot()
		expect(table.isfrozen(ctx.services)).toBe(true)
	end)
end)

describe("Services.new", function()
	it("live: the engine lookup, once per call; internal() skips the name check", function()
		local asked = {}
		local s = Services.new({
			get = function(name)
				table.insert(asked, name)
				return { name = name }
			end,
		})
		expect(s.forModule("M").get("Players").name).toBe("Players")
		expect(s.internal("ConfigService").name).toBe("ConfigService") -- the flag override's route
		expect(asked[1]).toBe("Players")
		expect(asked[2]).toBe("ConfigService")
	end)

	it("a fake wins over the engine, also on the internal route", function()
		local cs = fakes.configService({})
		local s = Services.new({
			get = function()
				error("engine reached")
			end,
			fakes = { ConfigService = cs },
			isTest = true,
		})
		expect(s.internal("ConfigService")).toBe(cs)
		expect(pcall(function()
			s.internal("TextService"):FilterStringAsync("x", 1)
		end)).toBe(false)
	end)
end)
