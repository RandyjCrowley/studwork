--!nocheck
-- Override case (b) scratch game (core-v1.3.0 Phase 2, P2-C): a custom 4-tier rarity preset with a custom theme and sounds.
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

local PROJECT = "examples/overrides/ov-b/default.project.json"

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

describe("override (b) ov-b", function()
	afterEach(function()
		ClientBoot.attach(nil)
	end)

	it("rolls on the 4 custom tiers; the client theme carries tiers, colours, fonts and sounds", function()
		local world, server, p = play(12)
		local ids = {}
		for _, tier in server:use("Rarity").tiers() do
			table.insert(ids, tier.id)
		end
		expect(ids).toEqual({ "Bronze", "Silver", "Gold", "Diamond" })
		local def, info = server:use("Rarity").roll("Block", p, nil, { grant = true })
		expect(info.ok).toBe(true)
		expect(def.rarity == "Bronze" or def.rarity == "Silver").toBe(true)
		expect(world:errors()).toEqual({})
		local t = ThemeTokens.new(client().theme)
		expect(t.hex("accent")).toBe("#FF5DA2")
		expect(t.fontFamily("display")).toBe("rbxasset://fonts/families/LuckiestGuy.json")
		expect(t.metrics.cornerRadius).toBe(6)
		expect(t.tierOrder).toEqual({ Bronze = 1, Silver = 2, Gold = 3, Diamond = 4 })
		expect(t.tier("Diamond").color).toBe("#7DF9FF")
		expect(t.tier("Common")).toBeNil()
		expect(t.sound(t.tier("Gold").soundKey).id).toBe(15675043410)
		expect(t.sound(t.tier("Diamond").soundKey).pitch).toBe(1.1)
		expect(t.sound("coin_tick").volume).toBe(0.2)
	end)
end)
