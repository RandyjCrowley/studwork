--!nocheck
-- Override case (a) scratch game (core-v1.3.0 Phase 2, P2-C): defaults only: the sandbox loop behaves like v1.2.
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

local PROJECT = "examples/overrides/ov-a/default.project.json"

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

describe("override (a) ov-a", function()
	afterEach(function()
		ClientBoot.attach(nil)
	end)

	it("collect, earn, upgrade, rebirth and a paid roll, with the default look", function()
		local world, server, p = play(11)
		local inv, econ = server:use("Inventory"), server:use("Economy")
		expect(inv.count(p)).toBe(1) -- the starter pebble
		local def, info = server:use("Rarity").roll("Block", p, nil, { grant = true, reason = "block" })
		expect(info.ok).toBe(true)
		expect(def ~= nil).toBe(true)
		expect(inv.count(p)).toBe(2)
		world:advance(5)
		expect(econ.balance(p) > 0).toBe(true) -- displayed items earn (autoDisplay)
		econ.grant(p, 100000, "test")
		local before = econ.balance(p)
		expect(server:use("Upgrades").purchase(p, "IncomeBoost")).toBe(true)
		expect(econ.balance(p)).toBeNear(before - 50, 1e-6)
		expect(server:use("Rebirth").rebirth(p)).toBe(true)
		expect(server:use("Rebirth").multiplier(p)).toBeNear(1.5, 1e-9)
		local h = server:purchase(F.receipt(p.UserId, "egg-1", 9001))
		assert(
			world:advanceUntil(function()
				return h.done
			end, 30),
			"receipt answered"
		)
		expect(h.result).toBe("PurchaseGranted")
		local paid = 0
		for _, item in inv.list(p) do
			if item.source == "paid:EggRoll" then
				paid += 1
			end
		end
		expect(paid).toBe(1)
		expect(world:errors()).toEqual({})
		local rt = client()
		expect(ThemeTokens.new(rt.theme).hex("accent")).toBe(SharedTheme.DEFAULT.colors.accent)
		expect(#rt.theme.rarity.tiers).toBe(7)
		expect(HudLayout.config(Config.client.hud).mode).toBe("default")
	end)
end)
