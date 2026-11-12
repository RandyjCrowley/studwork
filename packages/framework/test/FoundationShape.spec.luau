--!nocheck
--[[
	v1.7.0: the SHAPE of every new framework surface (module-api.md §23): the facade members, the
	pure env / flags / strings helpers, the store layers' argument checks, services, Open Cloud,
	store budgets and the census. Behaviour is covered by each surface's own specs.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Framework = ReplicatedStorage:WaitForChild("Framework")
local StudWork = require(Framework)
local Env = require(Framework:WaitForChild("Env"))
local Flags = require(Framework:WaitForChild("Flags"))
local Strings = require(Framework:WaitForChild("Strings"))
local ConfigValidate = require(Framework:WaitForChild("ConfigValidate"))

local Server = script.Parent.Parent.server
local Census = require(Server.Census)
local FlagOverride = require(Server.FlagOverride)
local OpenCloud = require(Server.OpenCloud)
local OrderedStore = require(Server.OrderedStore)
local PlatformServices = require(Server.PlatformServices)
local PlatformStores = require(Server.PlatformStores)
local Services = require(Server.Services)
local SortedMapStore = require(Server.SortedMapStore)
local StoreBudget = require(Server.StoreBudget)
local Text = require(Server.Text)

describe("v1.7.0 version and facade", function()
	it("StudWork.VERSION is 1.7.0", function()
		expect(StudWork.VERSION).toBe("1.7.0")
	end)

	it("exposes env, flags, text and test.fakes", function()
		expect(type(StudWork.env.name)).toBe("function")
		expect(type(StudWork.env.placeId)).toBe("function")
		expect(type(StudWork.env.universeId)).toBe("function")
		for _, name in { "isOn", "onChanged", "all", "source" } do
			expect(type(StudWork.flags[name])).toBe("function")
		end
		expect(type(StudWork.text)).toBe("function")
		for _, name in
			{
				"badgeService",
				"textService",
				"userService",
				"configService",
				"openCloud",
				"translator",
				"experienceNotificationService",
			}
		do
			expect(type(StudWork.test.fakes[name])).toBe("function")
		end
	end)

	it("env, flags and text are not modules: use() refuses them", function()
		local ok = pcall(StudWork.use, StudWork.env)
		expect(ok).toBe(false)
		local ok2 = pcall(StudWork.use, StudWork.flags)
		expect(ok2).toBe(false)
	end)
end)

describe("Env", function()
	local info = { isStudio = false, placeId = 11, universeId = 22 }

	it("resolves studio, test and live; an unlisted place is live", function()
		local environments = { test = { placeIds = { 11 } }, live = { placeIds = { 99 } } }
		expect(Env.resolve(environments, { isStudio = true, placeId = 11, universeId = 22 })).toBe("studio")
		expect(Env.resolve(environments, info)).toBe("test")
		expect(Env.resolve({ test = { universeIds = { 22 } }, live = { universeIds = { 33 } } }, info)).toBe(
			"test"
		)
		expect(Env.resolve({ test = { universeIds = { 22 } } }, info)).toBe("live") -- live universe unknown
		expect(Env.resolve({ test = { placeIds = { 5 } } }, info)).toBe("live")
		expect(Env.resolve(nil, info)).toBe("live")
	end)

	it("validates: an id under both test and live is an error", function()
		local errors = Env.validate({ test = { placeIds = { 1 } }, live = { placeIds = { 1 } } })
		expect(#errors).toBe(1)
		expect(#Env.validate({ test = { placeIds = { 1 } }, live = { placeIds = { 2 } } })).toBe(0)
		local _, warnings = Env.validate({ live = { placeIds = { 2 } } }, info)
		expect(#warnings).toBe(1)
	end)

	it("builds a frozen EnvAPI", function()
		local api = Env.build({ test = { placeIds = { 11 } } }, info)
		expect(api.name()).toBe("test")
		expect(api.placeId()).toBe(11)
		expect(api.universeId()).toBe(22)
		expect(Env.build(nil, info, "live").name()).toBe("live")
	end)
end)

describe("Flags", function()
	it("resolves environment field > default and refuses testOnly in live", function()
		local def = { default = false, test = true }
		expect(Flags.resolve(def, "test")).toBe(true)
		expect(Flags.resolve(def, "live")).toBe(false)
		local errors = Flags.validate({ dbg = { default = false, live = true, testOnly = true } }, nil, nil)
		expect(#errors).toBe(1)
		expect(string.find(errors[1], "testOnly", 1, true) ~= nil).toBe(true)
		expect(#Flags.validate({ a = { default = true } }, { a = { default = true } }, nil)).toBe(1) -- name clash
		expect(#Flags.validate({ ["bad name"] = { default = true } }, nil, nil) > 0).toBe(true)
	end)

	it("builds a flag table with the FlagsAPI shape", function()
		local state = Flags.new({
			flags = {
				a = { default = true },
				b = { default = false, test = true },
				c = { default = true, serverOnly = true },
			},
			envName = "test",
			side = "server",
		})
		expect(state.api.isOn("a")).toBe(true)
		expect(state.api.isOn("b")).toBe(true)
		expect(state.api.source("b")).toBe("config")
		expect(state.api.all().c).toBe(true)
		expect(state.replicated().c).toBe(nil)
		expect(pcall(state.api.isOn, "nope")).toBe(false)
		local seen = {}
		state.api.onChanged("a", function(on)
			table.insert(seen, on)
		end)
		expect(state.setOverride("a", false)).toBe(true)
		expect(state.api.source("a")).toBe("override")
		expect(seen[1]).toBe(false)
	end)

	it("the client twin errors for serverOnly and leaves it out of all()", function()
		local state = Flags.new({
			flags = { c = { default = true, serverOnly = true }, d = { default = true } },
			envName = "live",
			side = "client",
		})
		expect(pcall(state.api.isOn, "c")).toBe(false)
		expect(state.api.all().c).toBe(nil)
		expect(state.api.all().d).toBe(true)
	end)
end)

describe("Strings", function()
	it("formats named and numbered parameters", function()
		expect((Strings.format("Hi {name}", { name = "Ada" }))).toBe("Hi Ada")
		expect((Strings.format("{1} of {2}", { 3, 5 }))).toBe("3 of 5")
		local text, missing = Strings.format("Hi {name}", {})
		expect(text).toBe("Hi {name}")
		expect(missing[1]).toBe("name")
	end)

	it("checks a module's strings table", function()
		local errors = {}
		Strings.check({ ["Mod.ok"] = "x", ["Other.bad"] = "x", ["Mod.empty"] = "" }, "Mod", errors)
		expect(#errors).toBe(2)
	end)

	it("resolves override > default > the key itself, never empty", function()
		local warned = 0
		local r = Strings.new({
			defaults = { ["a.b"] = "default" },
			overrides = { ["a.c"] = "over" },
			warn = function()
				warned += 1
			end,
		})
		expect(r.english("a.b")).toBe("default")
		expect(r.english("a.c")).toBe("over")
		expect(r.english("x.y")).toBe("x.y")
		expect(r.text("x.y")).toBe("x.y")
		expect(warned).toBe(1)
	end)

	it("the framework's own keys have English defaults", function()
		for key, text in Strings.FRAMEWORK do
			expect(Strings.isKey(key)).toBe(true)
			expect(#text > 0).toBe(true)
		end
	end)
end)

describe("defineModule strings", function()
	local function define(strings)
		return StudWork.defineModule({
			name = "Probe",
			version = "1.0.0",
			framework = "^1.7.0",
			strings = strings,
		})
	end

	it("accepts a table and a function; refuses another namespace and empty values", function()
		expect(define({ ["Probe.hello"] = "Hello" }).strings["Probe.hello"]).toBe("Hello")
		expect(type(define(function()
			return {}
		end).strings)).toBe("function")
		expect(pcall(define, { ["Other.hello"] = "Hello" })).toBe(false)
		expect(pcall(define, { ["Probe.hello"] = "" })).toBe(false)
	end)
end)

describe("ConfigValidate: the new top-level keys", function()
	local function validate(extra)
		local config = { gameId = "g", modules = {} }
		for k, v in extra do
			config[k] = v
		end
		return ConfigValidate.validate({}, config)
	end

	it("knows environments, flags, flagOverride, storeBudgets, strings, localization", function()
		local r = validate({
			environments = { test = { placeIds = { 1 } } },
			flags = { a = { default = true } },
			flagOverride = { enabled = true, refreshSeconds = 30 },
			storeBudgets = {
				orderedReserve = 0.5,
				censusSeconds = 60,
				memory = { reserve = 0.2, defaultShare = 0.25 },
			},
			strings = { ["game.x"] = "X" },
			localization = { sourceLocale = "en" },
		})
		expect(r.errors).toEqual({})
		expect(r.warnings).toEqual({})
		expect(r.strings["game.x"]).toBe(nil) -- game strings are overrides, not defaults
	end)

	it("reports bad values together", function()
		local r = validate({
			flags = { dbg = { default = false, live = true, testOnly = true } },
			flagOverride = { refreshSeconds = 1 },
			storeBudgets = { orderedReserve = 2, censusSeconds = 5 },
			environments = { test = { placeIds = { 1 } }, live = { placeIds = { 1 } } },
		})
		expect(#r.errors).toBe(5)
	end)
end)

describe("store, services and Open Cloud layers (shape)", function()
	it("StoreBudget.resolve fills the defaults", function()
		local c = StoreBudget.resolve(nil)
		expect(c.orderedReserve).toBe(0.25)
		expect(c.memoryUnits.base).toBe(20)
		expect(c.memory.defaultShare).toBe(0.25)
		expect(c.censusSeconds).toBe(60)
		expect(StoreBudget.resolve({ orderedReserve = 0.5 }).orderedReserve).toBe(0.5)
		local b = StoreBudget.new({})
		expect(b.allowOrdered("M", "get")).toBe(true)
	end)

	it("Census returns a fixed reading, else nil", function()
		expect(Census.new({}).api()).toBe(nil)
		local c = Census.new({ fixed = { servers = 2, players = 7 } })
		expect(c.api().servers).toBe(2)
		expect(c.api().peakPlayers).toBe(7)
	end)

	it("OrderedStore builds the store name and checks its arguments", function()
		expect(OrderedStore.storeName("Mod", "board", false)).toBe("SW/Mod/board")
		expect(OrderedStore.storeName("Mod", "board", true)).toBe("SW/Mod/board_Studio")
		local open = OrderedStore.new({ backend = PlatformStores.inert().ordered }).forModule("Mod")
		expect(pcall(open, string.rep("x", 60))).toBe(false)
		local board = open("b")
		expect(pcall(board.set, "k", 1.5)).toBe(false)
		expect(pcall(board.top, 0, "desc")).toBe(false)
		local ok, reason = board.get("k") -- the inert platform has no backend: failed, never raised
		expect(ok).toBe(false)
		expect(reason).toBe("failed")
	end)

	it("SortedMapStore classifies Roblox error codes and checks arguments", function()
		expect(SortedMapStore.classify("PartitionRequestsOverLimit")).toBe("throttled")
		expect(SortedMapStore.classify("TotalMemoryOverLimit")).toBe("memory_full")
		expect(SortedMapStore.classify("boom")).toBe("failed")
		local map = SortedMapStore.new({ backend = PlatformStores.inert().sortedMap }).forModule("Mod")("m")
		expect(pcall(map.set, "k", "v", 0)).toBe(false) -- expiry out of range
		expect(pcall(map.set, string.rep("k", 129), "v", 10)).toBe(false)
		expect(pcall(map.range, "up", 10)).toBe(false)
		expect(pcall(map.range, "asc", 201)).toBe(false)
	end)

	it(
		"the live store adapters need the engine: outside it a call raises (the layers return failed)",
		function()
			local ok, err = pcall(PlatformStores.live().ordered("x").get, "k")
			expect(ok).toBe(false)
			expect(string.find(tostring(err), "DataStoreService", 1, true) ~= nil).toBe(true)
		end
	)

	it("Services: allowed, refused with the surface to use, and no-fake stubs", function()
		local fake = { marker = true }
		local s = Services.new({
			get = PlatformServices.inert().services.get,
			fakes = { BadgeService = fake },
			isTest = true,
		})
		local api = s.forModule("Mod")
		expect(api.get("BadgeService")).toBe(fake)
		local _, err = pcall(api.get, "MemoryStoreService")
		expect(string.find(tostring(err), "ctx.data.sortedMap", 1, true) ~= nil).toBe(true)
		expect(pcall(api.get, "ConfigService")).toBe(false)
		expect(pcall(api.get, "Lighting")).toBe(false)
		local _, stubErr = pcall(function()
			api.get("TextService"):FilterStringAsync("x", 1)
		end)
		expect(string.find(tostring(stubErr), "no test fake for TextService", 1, true) ~= nil).toBe(true)
	end)

	it("OpenCloud: deny by default, allow-list, refused families", function()
		expect(OpenCloud.matches("users/*/notifications", "users/5/notifications")).toBe(true)
		expect(OpenCloud.matches("users/*/notifications", "users/5/other")).toBe(false)
		expect(OpenCloud.refusedSurface("universes/1/data-stores/x")).toBe("ctx.data")
		expect(OpenCloud.refusedSurface("universes/1/memory-store/flush")).toBe("ctx.data.sortedMap")
		expect(OpenCloud.refusedSurface("users/5/notifications")).toBe(nil)
		local oc = OpenCloud.new({}).forModule("Mod")
		local ok, status, why = oc.request({ secret = "S", method = "POST", path = "users/5/notifications" })
		expect(ok).toBe(false)
		expect(status).toBe(nil)
		expect(why).toBe("not_allowed")
		expect(oc.available("S")).toBe(false)
	end)

	it("FlagOverride.settings and Text.new have their shape", function()
		expect(FlagOverride.settings(nil).keyPrefix).toBe("flag_")
		expect(FlagOverride.settings({ enabled = true, refreshSeconds = 60 }).refreshSeconds).toBe(60)
		expect(type(FlagOverride.new({}).start)).toBe("function")
		local t = Text.new({ defaults = { ["a.b"] = "Hi {n}" } })
		expect(t.api.english("a.b", { n = "x" })).toBe("Hi x")
		expect(t.api.format({}, "a.b", { n = "y" })).toBe("Hi y")
	end)
end)
