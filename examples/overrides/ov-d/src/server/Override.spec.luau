--!nocheck
-- Override case (d) scratch game (core-v1.3.0 Phase 2, P2-C): Collection on, Economy off: items with no income.
-- The game's real project boots in the multi-server sim (StudWork.test.sim); the client side is
-- the client runtime started with the same Config (merged theme, GameConfig.client).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local F = StudWork.test.sim
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local ClientRuntime = require(ReplicatedStorage:WaitForChild("FrameworkClient"):WaitForChild("Runtime"))
local ClientBoot = require(ReplicatedStorage:WaitForChild("FrameworkClient"):WaitForChild("Boot"))
local SharedTheme = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Theme"))
local ThemeTokens = require("packages/ui/ThemeTokens.luau")
local HudLayout = require("packages/ui/HudLayout.luau")

local PROJECT = "examples/overrides/ov-d/default.project.json"

local function play(userId: number)
	local world = F.world()
	local server = F.gameServer(world, PROJECT)
	local p = server:join(userId)
	assert(
		world:advanceUntil(function()
			return server:isLoaded(p)
		end, 30),
		"loaded"
	)
	world:advance(1)
	return world, server, p
end

local function client(): any
	ClientBoot.attach(nil)
	local gameModule = require(ReplicatedStorage:WaitForChild("GameModule"):WaitForChild("module"))
	local rt = ClientRuntime.start(Config, nil, {
		loadClient = function()
			return nil
		end,
		gameModule = gameModule,
	})
	return rt
end

local _ = { SharedTheme, ThemeTokens, HudLayout, play, client }

describe("override (d) ov-d", function()
	afterEach(function()
		ClientBoot.attach(nil)
	end)

	it("collects items that earn nothing; Economy is not enabled", function()
		local world, server, p = play(14)
		local def, info = server:use("Rarity").roll("Block", p, nil, { grant = true })
		expect(info.ok).toBe(true)
		expect(def.economy).toBeNil()
		expect(server:use("Inventory").count(p) >= 2).toBe(true)
		world:advance(10)
		expect(server:section(p, "economy")).toBeNil()
		local names = {}
		for _, ref in server.runtime.order do
			names[ref.name] = true
		end
		expect(names.Economy).toBeNil()
		expect(world:errors()).toEqual({})
		local cfg = HudLayout.config(client().gameConfig.client.hud)
		expect(cfg.mode).toBe("default")
	end)
end)
