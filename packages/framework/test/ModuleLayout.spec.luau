--!nocheck
-- core-v1.3.1 (R19, module-api.md §19.9): the live module lookups on both sides.
--   server  Loader.defaultLoadServer: ServerScriptService.Modules[ref.server] only, new() for a part
--           factory (fresh per call), the `Net` child bound as `net`
--   client  Runtime.defaultLoadClient: ReplicatedStorage.Modules[ref.client].client (or
--           GameModule.client for the game module), the `Net` child bound as `net`
-- plus the real repo mapping (the testkit's fake game maps every module folder like Rojo).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loader = require("packages/framework/server/Loader.luau")
local Runtime = require(ReplicatedStorage:WaitForChild("FrameworkClient"):WaitForChild("Runtime"))

local fixtures = script.Parent.fixtures.ModuleLayout
local serverModules = fixtures.ServerModules
local replicated = fixtures.Replicated

local function ref(name: string): any
	return { name = name, server = name, client = name }
end

describe("server part lookup (Loader.defaultLoadServer)", function()
	it("finds ServerScriptService.Modules[ref.server] and binds its Net child as net", function()
		local part = Loader.defaultLoadServer(ref("Thing"), serverModules)
		expect(type(part.init)).toBe("function")
		expect(type(part.net)).toBe("table")
		expect(type(part.net.Ping.Fire)).toBe("function")
	end)

	it("calls new() on a part factory, a fresh part every call", function()
		local a = Loader.defaultLoadServer(ref("Factory"), serverModules)
		local b = Loader.defaultLoadServer(ref("Factory"), serverModules)
		expect(a ~= b).toBe(true)
		expect(a.api.id()).toBe(2)
		expect(type(a.new)).toBe("nil")
	end)

	it("skips the Net child with bindNet = false (the testkit and the sim: no Blink wire)", function()
		expect(Loader.defaultLoadServer(ref("Factory"), serverModules, { bindNet = false }).net).toBeNil()
		local thing = Loader.defaultLoadServer(ref("Thing"), serverModules, { bindNet = false })
		expect(type(thing.init)).toBe("function")
	end)

	it("keeps a part's own net and returns nil for a module without a server part", function()
		expect(Loader.defaultLoadServer(ref("OwnNet"), serverModules).net.mine).toBe(true)
		expect(Loader.defaultLoadServer(ref("Missing"), serverModules)).toBeNil()
	end)

	it("resolves the real kit modules from ServerScriptService.Modules (fresh parts per runtime)", function()
		local a = Loader.defaultLoadServer(ref("Economy"))
		local b = Loader.defaultLoadServer(ref("Economy"))
		expect(type(a.init)).toBe("function")
		expect(a ~= b).toBe(true)
		local s = Loader.defaultLoadServer(ref("Streak"))
		expect(type(s.init)).toBe("function")
	end)
end)

describe("client part lookup (Runtime.defaultLoadClient)", function()
	it("finds ReplicatedStorage.Modules[ref.client].client and binds its Net child as net", function()
		local part = Runtime.defaultLoadClient(ref("Thing"), false, replicated)
		expect(type(part.net.Ping.Fire)).toBe("function")
		local actions = Runtime.buildActions(ref("Thing"), part, function() end)
		actions.ping("hi")
		expect(part.net.log[#part.net.log][1]).toBe("hi")
	end)

	it("finds the game module's GameModule.client, and nil when there is no client part", function()
		expect(Runtime.defaultLoadClient(ref("AnyName"), true, replicated).api.game).toBe(true)
		expect(Runtime.defaultLoadClient(ref("Missing"), false, replicated)).toBeNil()
		expect(Runtime.defaultLoadClient({ name = "X" }, false, replicated)).toBeNil()
	end)

	it("resolves the real kit client parts from ReplicatedStorage.Modules", function()
		-- core-v1.3.1 R19: Upgrades now has a generated client/Net.luau, which the live lookup binds and
		-- Lune can't run (no Blink wire); Economy's client part (no net.blink) exercises the same lookup.
		-- Upgrades' declared `upgrade` action is pinned by packages/kits/KitClients.spec.luau.
		local part = Runtime.defaultLoadClient(ref("Economy"), false)
		expect(type(part.start)).toBe("function")
	end)
end)
