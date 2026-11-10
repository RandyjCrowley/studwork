--!strict
--[[
	Core.Client.Hud. OWNED BY AGENT F (core/f-ui). Public API: Types.HudAPI.

	PHASE 0 STUB: a plain TextLabel showing primary currency, rate per second and the next goal,
	updated from Core.Client.state with Charm.effect. Agent F replaces it with a React-lua HUD
	built from packages/ui components (CurrencyCounter, Toast, ...), mobile-first.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Charm"))
local Palette = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Palette"))
local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))
local State = require(script.Parent.State)

local Hud = {}

local ctx: any = nil
local gui: ScreenGui? = nil
local cleanup: (() -> ())? = nil

function Hud.init(context: any)
	ctx = context
end

function Hud.mount(opts: Types.HudOptions?)
	Hud.unmount()
	local o: Types.HudOptions = opts or {}
	local screen = Instance.new("ScreenGui")
	screen.Name = "CoreHud"
	screen.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(0.4, 0.08)
	label.Position = UDim2.fromScale(0.5, 0.02)
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.BackgroundColor3 = Palette.color("surface", ctx.config.palette)
	label.TextColor3 = Palette.color("text", ctx.config.palette)
	label.TextScaled = true
	label.Parent = screen
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = screen
	cleanup = Charm.effect(function()
		local state: Types.ReplicatedState = State.atom()
		local primary = ctx.config.balance.primaryCurrency
		local coins = if state.data then (state.data.currency[primary] or 0) else 0
		local text = string.format("%s: %d  (+%.1f/s)", primary, math.floor(coins), state.ratePerSec)
		local goal = o.nextGoal and o.nextGoal()
		if goal then
			text ..= "  |  " .. goal
		end
		label.Text = text
	end)
end

function Hud.unmount()
	if cleanup then
		cleanup()
		cleanup = nil
	end
	if gui then
		gui:Destroy()
		gui = nil
	end
end

return Hud
