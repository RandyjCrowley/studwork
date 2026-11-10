--!strict
--[[
	UI theme derived from the shared palette. OWNED BY AGENT F (core/f-ui).

	Theme.color(key, overrides?) -> Color3 (palette key; overrides default to Theme.setOverrides)
	Theme.setOverrides(palette?)    apply GameConfig.palette to every component (Hud.init does this)
	Theme.rarity(tier, overrides?) -> (color: Color3, glow: Color3, glowStrength: number)
	Theme.font(kind) -> Font       kind: "display" (Fredoka One) | "body" (Builder Sans) | "bold"
	Theme.metrics                   cornerRadius, padding, strokeThickness, minTouchTarget (px)
	Theme.touchTarget               design-pixel size that is >= minTouchTarget real px at the
	                                smallest UIScale (see Responsive)
	Theme.text                      design-pixel text sizes: small, body, title, number
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Palette"))
local RarityTiers = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("RarityTiers"))
local Responsive = require(script.Parent.Responsive)

local Theme = {}

-- Per-game palette overrides (GameConfig.palette, hex strings); set once by the game or the HUD.
local activeOverrides: { [string]: string }? = nil

function Theme.setOverrides(overrides: { [string]: string }?)
	activeOverrides = overrides
end

Theme.fonts = Palette.fonts
Theme.metrics = Palette.metrics
Theme.touchTarget = Responsive.touchTarget(Palette.metrics.minTouchTarget)
Theme.text = {
	small = 14,
	body = 18,
	title = 24,
	number = 28,
}

function Theme.color(key: string, overrides: { [string]: string }?): Color3
	return Palette.color(key, overrides or activeOverrides)
end

function Theme.rarity(tier: string?, _overrides: { [string]: string }?): (Color3, Color3, number)
	if tier and RarityTiers.isTier(tier) then
		local def = RarityTiers.get(tier :: any)
		return Color3.fromHex(def.color), Color3.fromHex(def.glow), def.glowStrength
	end
	local muted = Theme.color("textMuted")
	return muted, muted, 0
end

function Theme.font(kind: ("display" | "body" | "bold")?): Font
	if kind == "display" then
		return Font.new(Palette.fonts.display, Enum.FontWeight.Regular)
	elseif kind == "bold" then
		return Font.new(Palette.fonts.body, Enum.FontWeight.Bold)
	end
	return Font.new(Palette.fonts.body, Enum.FontWeight.Medium)
end

function Theme.cornerRadius(): UDim
	return UDim.new(0, Palette.metrics.cornerRadius)
end

function Theme.padding(px: number?): UDim
	return UDim.new(0, px or Palette.metrics.padding)
end

-- Two-stop vertical gradient: lighter top, base bottom (Panel/Button "glossy" look).
function Theme.gradient(base: Color3, lift: number?): ColorSequence
	local h, s, v = base:ToHSV()
	local top = Color3.fromHSV(h, s * 0.85, math.min(1, v + (lift or 0.12)))
	return ColorSequence.new(top, base)
end

return Theme
