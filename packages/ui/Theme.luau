--!strict
--[[
	UI theme: every component reads its colours, fonts, metrics and rarity look from here, and
	this reads the one merged theme (module-api.md §13; Framework/shared/Theme). Nothing in the UI
	kit hardcodes a colour, font, size or sound id.

	Theme.set(theme, paletteOverrides?)  install the resolved theme (the framework HUD does this at
	                                boot with the runtime's merged theme); defaults to the
	                                "framework-default" preset
	Theme.current() -> resolved theme table
	Theme.tokens                    the pure ThemeTokens for the current theme
	Theme.setOverrides(palette?)    legacy GameConfig.palette (hex per colour key) on top
	Theme.color(key, overrides?) -> Color3
	Theme.rarity(tier) -> (color: Color3, glow: Color3, glowStrength: number)
	Theme.tiers() -> ordered tier list; Theme.tierOrder() -> { [tierId]: position }
	Theme.sound(key) -> { id, volume?, pitch? }?
	Theme.font(kind) -> Font        kind: "display" | "body" | "bold"
	Theme.metrics / Theme.text / Theme.fonts / Theme.touchTarget (refreshed by set)
	Theme.subscribe(fn) -> unsubscribe   fn() after every set / setOverrides
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedTheme = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Theme")) :: any
local ThemeTokens = require(script.Parent.ThemeTokens)

local Theme = {}

local activeTheme: any = SharedTheme.DEFAULT
local activeOverrides: { [string]: string }? = nil
local listeners: { [any]: boolean } = {}

local function rebuild()
	local tokens = ThemeTokens.new(activeTheme, activeOverrides)
	Theme.tokens = tokens
	Theme.fonts = tokens.fonts
	Theme.metrics = tokens.metrics
	Theme.text = tokens.text
	Theme.touchTarget = tokens.touchTarget
	for fn in listeners do
		task.spawn(fn)
	end
end

function Theme.set(theme: any?, overrides: { [string]: string }?)
	activeTheme = theme or SharedTheme.DEFAULT
	if overrides ~= nil then
		activeOverrides = overrides
	end
	rebuild()
end

function Theme.current(): any
	return activeTheme
end

function Theme.setOverrides(overrides: { [string]: string }?)
	activeOverrides = overrides
	rebuild()
end

function Theme.subscribe(fn: () -> ()): () -> ()
	listeners[fn] = true
	return function()
		listeners[fn] = nil
	end
end

function Theme.color(key: string, overrides: { [string]: string }?): Color3
	if overrides and type(overrides[key]) == "string" then
		return Color3.fromHex(overrides[key])
	end
	return Color3.fromHex(Theme.tokens.hex(key))
end

function Theme.rarity(tier: string?, _overrides: { [string]: string }?): (Color3, Color3, number)
	local def = Theme.tokens.tier(tier)
	if def then
		return Color3.fromHex(def.color), Color3.fromHex(def.glow), def.glowStrength
	end
	local muted = Theme.color("textMuted")
	return muted, muted, 0
end

function Theme.tiers(): { any }
	return Theme.tokens.tiers
end

function Theme.tierOrder(): { [string]: number }
	return Theme.tokens.tierOrder
end

function Theme.sound(key: string): any
	return Theme.tokens.sound(key)
end

function Theme.font(kind: ("display" | "body" | "bold")?): Font
	if kind == "display" then
		return Font.new(Theme.tokens.fontFamily("display"), Enum.FontWeight.Regular)
	elseif kind == "bold" then
		return Font.new(Theme.tokens.fontFamily("body"), Enum.FontWeight.Bold)
	end
	return Font.new(Theme.tokens.fontFamily("body"), Enum.FontWeight.Medium)
end

function Theme.cornerRadius(): UDim
	return UDim.new(0, Theme.metrics.cornerRadius)
end

function Theme.padding(px: number?): UDim
	return UDim.new(0, px or Theme.metrics.padding)
end

-- Two-stop vertical gradient: lighter top, base bottom (Panel/Button "glossy" look).
function Theme.gradient(base: Color3, lift: number?): ColorSequence
	local h, s, v = base:ToHSV()
	local top = Color3.fromHSV(h, s * 0.85, math.min(1, v + (lift or 0.12)))
	return ColorSequence.new(top, base)
end

rebuild()

return Theme
