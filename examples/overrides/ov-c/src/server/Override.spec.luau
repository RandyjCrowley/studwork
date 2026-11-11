--!nocheck
-- Override case (c) scratch game (core-v1.3.0 Phase 2, P2-C): the HUD replaced with a custom component, plus a custom screen.
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

local PROJECT = "examples/overrides/ov-c/default.project.json"

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

describe("override (c) ov-c", function()
	afterEach(function()
		ClientBoot.attach(nil)
	end)

	it("boots with a custom HUD layout (ModuleScript) and the mailbox widget removed", function()
		local world = play(13)
		expect(world:errors()).toEqual({})
		local rt = client()
		local loaded = nil
		local function StandIn() end
		-- the layout is a ModuleScript (src/shared/MyHud.luau); the client loads it with require
		-- (React needs the engine, so a stand-in component is returned here)
		local cfg = HudLayout.config(rt.gameConfig.client.hud, function(m)
			loaded = m
			return StandIn
		end, function(v)
			return type(v) == "table" and v.__path ~= nil
		end)
		expect(cfg.mode).toBe("custom")
		expect(cfg.layout).toBe(StandIn)
		expect(string.find(loaded.__path, "examples/overrides/ov%-c/src/shared/MyHud") ~= nil).toBe(true)
		expect(cfg.widgets["Social.mailbox"]).toBe(false)
	end)
end)
