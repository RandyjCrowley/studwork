--!nocheck
--[[
	Planted case 38, default boot under the harness (the test-adopt / new-game shape): Carry and Movement
	boot at their config defaults with NO World installed. The Lune harness has no Workspace, CFrame,
	CollectionService or RunService, so World.live() returns nil and both modules idle: no error, no
	warning, a player loads and the ticker runs. Also: useWorld is callable at any time and takes the fake.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local FakeWorld = require("packages/kits/carry/tests/FakeWorld.luau")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Carry = require(Modules:WaitForChild("Carry"):WaitForChild("module"))
local Movement = require(Modules:WaitForChild("Movement"):WaitForChild("module"))

local function boot(modules)
	-- StudWork.test.harness loads each listed module's real server part (Loader.defaultLoadServer)
	return StudWork.test.harness({ modules = modules })
end

describe("carry kit default boot with no World (case 38)", function()
	it("both modules boot at defaults, load a player and idle through the ticker", function()
		local h = boot({ Movement, Carry })
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(true)
		h:tick(5)
		expect(h:warnings()).toEqual({})
	end)

	it("Carry boots without Movement, Movement without Carry", function()
		local a = boot({ Carry })
		a:addPlayer({ userId = 1 })
		a:tick(3)
		expect(a:warnings()).toEqual({})
		local b = boot({ Movement })
		b:addPlayer({ userId = 1 })
		b:tick(3)
		expect(b:warnings()).toEqual({})
	end)

	it("useWorld takes an adapter at any time, before and after ticks", function()
		local h = boot({ Movement, Carry })
		local fw = FakeWorld.new()
		h:use(Carry).useWorld(fw.world)
		h:use(Movement).useWorld(fw.world)
		h:addPlayer({ userId = 1 })
		h:tick(2)
		h:use(Carry).useWorld(fw.world)
		h:use(Movement).useWorld(fw.world)
	end)

	it("declares the config keys and strings of the design", function()
		local cfg = Carry.config.defaults
		expect(cfg.sampleSeconds).toBe(0.1)
		expect(cfg.motionHz).toBe(30)
		expect(cfg.clamp.speedSlack).toBe(1.35)
		expect(cfg.agree.lagSeconds).toBe(0.6)
		expect(Carry.client).toBe("Carry")
		expect(Movement.client).toBe(nil)
		expect(Carry.strings["Carry.delivered"]).toBe("Delivered!")
		expect(Movement.strings["Movement.kicked"]).toBe("Removed for unusual movement")
		expect(Movement.config.defaults.teleport.minLagSeconds).toBe(0.6)
		expect(Movement.config.defaults.response).toBe("log")
	end)
end)
