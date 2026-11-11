--!strict
--[[
	TEST FIXTURE (core-v1.3.0 Phase 2): kept from the deleted v1.2 shared Palette.luau: the v1.2 palette Theme.spec compares the framework's
	default theme against.
	Never required by game or kit code.
	Shared palette (docs/research/art-direction.md: one locked palette of ~12-16 colours for models,
	UI and particles; rounded display font for headings/numbers plus one body font).

	Pure: colours are hex strings. Use Palette.color(key, overrides?) at runtime to get a Color3.
	Games override keys through GameConfig.palette (hex strings).
]]

local Palette = {}

-- Base + UI colours (rarity colours live in RarityTiers.luau)
Palette.colors = {
	background = "#1E2235", -- deep navy, behind panels
	surface = "#2B3050", -- panels
	surfaceAlt = "#3A4170", -- raised elements, list rows
	outline = "#14172A", -- strokes / UIStroke / Highlight outline
	text = "#FFF8EC", -- warm white
	textMuted = "#B9BEDA",
	accent = "#FFB547", -- warm orange: primary buttons, next goal arrow
	accentAlt = "#5ED1C9", -- teal: secondary buttons, links
	currency = "#FFD23F", -- coins
	success = "#6BD66B",
	danger = "#FF5D6C",
	warning = "#FFD23F",
	sunlight = "#FFE7B8", -- warm sun (lighting)
	shadow = "#5A6AA8", -- cool shadow / ambient (lighting)
}

Palette.fonts = {
	-- Built-in Roblox font families (no upload needed)
	display = "rbxasset://fonts/families/FredokaOne.json", -- headings, numbers
	displayFallback = "rbxasset://fonts/families/BuilderSans.json", -- Builder Sans (bold weight)
	body = "rbxasset://fonts/families/BuilderSans.json",
}

Palette.metrics = {
	cornerRadius = 12, -- px, UICorner
	padding = 12, -- px, standard inner padding
	strokeThickness = 2, -- px, UIStroke / Highlight outline
	minTouchTarget = 44, -- px, minimum tappable size (mobile first)
}

-- Resolve a hex for `key`, honouring per-game overrides.
function Palette.hex(key: string, overrides: { [string]: string }?): string
	if overrides and overrides[key] then
		return overrides[key]
	end
	local value = (Palette.colors :: any)[key]
	assert(type(value) == "string", "Palette: unknown colour key " .. tostring(key))
	return value
end

-- Runtime only (needs Color3).
function Palette.color(key: string, overrides: { [string]: string }?): Color3
	return Color3.fromHex(Palette.hex(key, overrides))
end

function Palette.isHex(value: any): boolean
	return type(value) == "string" and string.match(value, "^#%x%x%x%x%x%x$") ~= nil
end

return Palette
