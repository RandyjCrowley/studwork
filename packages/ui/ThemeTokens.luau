--!strict
--[[
	Pure token lookups over a resolved theme (Framework/shared/Theme.merge output, module-api.md §13).
	UI.Theme wraps this with Color3/Font; Lune specs test it directly.

	ThemeTokens.new(theme, paletteOverrides?) -> Tokens
	  hex(key)          '#RRGGBB' for a colour token (legacy GameConfig.palette overrides win);
	                    errors on an unknown key
	  tier(id)          { id, color, glow, glowStrength, soundKey? } or nil (unknown tier)
	  tierOrder         { [tierId]: position } (tier order = theme.rarity.tiers order)
	  tiers             the ordered tier list
	  fontFamily(kind)  "display" | "bold" | "body" -> font family path
	  metrics           cornerRadius, padding, strokeThickness, minTouchTarget (+ text)
	  text              design-pixel text sizes: small, body, title, number
	  touchTarget       design-pixel size >= metrics.minTouchTarget real px at Responsive.MIN_SCALE
	  sound(key)        { id, volume?, pitch? } or nil (absent / id 0)
]]

local Responsive = require(script.Parent.Responsive)

local ThemeTokens = {}

export type Tier = { id: string, color: string, glow: string, glowStrength: number, soundKey: string? }

function ThemeTokens.new(theme: any, overrides: { [string]: string }?): any
	assert(type(theme) == "table", "ThemeTokens.new: theme must be a resolved theme table")
	local colors = theme.colors or {}
	local metrics = theme.metrics or {}
	local fonts = theme.fonts or {}
	local tiers = if type(theme.rarity) == "table" and type(theme.rarity.tiers) == "table"
		then theme.rarity.tiers
		else {}
	local byId: { [string]: Tier } = {}
	local order: { [string]: number } = {}
	for i, t in tiers do
		byId[t.id] = t
		order[t.id] = i
	end

	local tokens = {}
	tokens.theme = theme
	tokens.tiers = tiers
	tokens.tierOrder = order
	tokens.metrics = metrics
	tokens.fonts = fonts
	tokens.text = metrics.text or {}
	tokens.touchTarget = Responsive.touchTarget(metrics.minTouchTarget or 44)

	function tokens.hex(key: string): string
		if overrides and type(overrides[key]) == "string" then
			return overrides[key]
		end
		local value = colors[key]
		assert(type(value) == "string", "Theme: unknown colour key " .. tostring(key))
		return value
	end

	function tokens.tier(id: any): Tier?
		return if type(id) == "string" then byId[id] else nil
	end

	function tokens.fontFamily(kind: string?): string
		if kind == "display" then
			return fonts.display
		end
		return fonts.body
	end

	function tokens.sound(key: string): any
		local s = if type(theme.sounds) == "table" then theme.sounds[key] else nil
		if type(s) ~= "table" or type(s.id) ~= "number" or s.id == 0 then
			return nil
		end
		return s
	end

	return table.freeze(tokens)
end

return ThemeTokens
