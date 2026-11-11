--!nocheck
-- Override case (e) example game: foundation only.
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

local PROJECT = "examples/overrides/ov-e/default.project.json"

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

describe("override (e) ov-e", function()
	afterEach(function()
		ClientBoot.attach(nil)
	end)

	it("the framework alone: a player loads, saves and leaves", function()
		local world, server, p = play(15)
		expect(#server.runtime.order).toBe(1) -- only the game's own module
		local sections = server:sections(p)
		expect(sections._framework ~= nil).toBe(true)
		expect(sections._framework.stats.sessions).toBe(1)
		server:leave(p)
		world:advance(10)
		expect(world:errors()).toEqual({})
		expect(ThemeTokens.new(client().theme).hex("accent")).toBe(SharedTheme.DEFAULT.colors.accent)
	end)
end)
