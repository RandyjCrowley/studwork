--!strict
--[[
	The one theme system (module-api.md §13). Pure (no Roblox globals): colours are '#RRGGBB'
	strings, fonts are font-family asset paths, sounds are { id, volume?, pitch? }.

	Merge order (deep; maps merge, lists replace):
	  1. the preset: GameConfig.theme.preset = "framework-default" (default) | <preset table>
	     (a preset table is itself layered on framework-default, so it may be partial)
	  2. each enabled module's `theme` contribution, in boot order (Collection contributes
	     theme.rarity)
	  3. GameConfig.theme itself
	theme.rarity = { preset = "standard7" } resolves to the standard7 tier list; theme.rarity =
	{ tiers = {...} } replaces the list (tier order = list order). The result is frozen.

	Token groups:
	  colors   background surface surfaceAlt outline text textMuted accent accentAlt currency
	           success danger warning sunlight shadow backdrop dropShadow
	  fonts    display displayFallback body
	  metrics  cornerRadius padding strokeThickness minTouchTarget, text = { small body title number min }
	           (text.min: smallest size scaled text may shrink to, v1.6.1)
	  sounds   <key> = { id, volume?, pitch? } (id 0 = silent)
	  rarity   preset?, tiers = { { id, color, glow?, glowStrength?, soundKey? } }

	The "framework-default" preset is today's (v1.2) look token for token (Theme.spec golden test):
	core/shared/Palette + Sounds + RarityTiers and the UI kit's text sizes.

	Pure helpers over a resolved theme: Theme.tier(theme, id), Theme.tierOrder(theme),
	Theme.sound(theme, key).
]]

local Freeze = require(script.Parent.Freeze)

local Theme = {}

local STANDARD7 = {
	{ id = "Common", color = "#C9CFD9", glow = "#E6EAF0", glowStrength = 0.0, soundKey = "rarity_common" },
	{
		id = "Uncommon",
		color = "#6BD66B",
		glow = "#A6F0A6",
		glowStrength = 0.15,
		soundKey = "rarity_uncommon",
	},
	{ id = "Rare", color = "#4DA3FF", glow = "#9CCBFF", glowStrength = 0.35, soundKey = "rarity_rare" },
	{ id = "Epic", color = "#B26BFF", glow = "#D7B0FF", glowStrength = 0.55, soundKey = "rarity_epic" },
	{
		id = "Legendary",
		color = "#FFB547",
		glow = "#FFE0A3",
		glowStrength = 0.75,
		soundKey = "rarity_legendary",
	},
	{ id = "Mythic", color = "#FF5DA8", glow = "#FFB3D6", glowStrength = 0.9, soundKey = "rarity_mythic" },
	{ id = "Secret", color = "#2EF2E0", glow = "#B8FFF8", glowStrength = 1.0, soundKey = "rarity_secret" },
}

Theme.RARITY_PRESETS = Freeze.freezeCopy({ standard7 = STANDARD7 })

local FRAMEWORK_DEFAULT = Freeze.freezeCopy({
	colors = {
		background = "#1E2235",
		surface = "#2B3050",
		surfaceAlt = "#3A4170",
		outline = "#14172A",
		text = "#FFF8EC",
		textMuted = "#B9BEDA",
		accent = "#FFB547",
		accentAlt = "#5ED1C9",
		currency = "#FFD23F",
		success = "#6BD66B",
		danger = "#FF5D6C",
		warning = "#FFD23F",
		sunlight = "#FFE7B8",
		shadow = "#5A6AA8",
		backdrop = "#000000", -- Modal dim (was Color3.new(0, 0, 0))
		dropShadow = "#000000", -- Primitives.shadow (was Color3.new(0, 0, 0))
	},
	fonts = {
		display = "rbxasset://fonts/families/FredokaOne.json",
		displayFallback = "rbxasset://fonts/families/BuilderSans.json",
		body = "rbxasset://fonts/families/BuilderSans.json",
	},
	metrics = {
		cornerRadius = 12,
		padding = 12,
		strokeThickness = 2,
		minTouchTarget = 44,
		minTextSize = 11,
		text = { small = 14, body = 18, title = 24, number = 28, min = 14 },
	},
	sounds = {
		rarity_common = { id = 15675055424, volume = 0.4 },
		rarity_uncommon = { id = 17208204604, volume = 0.45 },
		rarity_rare = { id = 17208361335, volume = 0.5 },
		rarity_epic = { id = 17208327798, volume = 0.55 },
		rarity_legendary = { id = 15675043410, volume = 0.6 },
		rarity_mythic = { id = 16480578169, volume = 0.6 },
		rarity_secret = { id = 16480577565, volume = 0.65 },
		coin_tick = { id = 16480580213, volume = 0.35 },
		purchase = { id = 17208380755, volume = 0.5 },
		rebirth = { id = 15675046931, volume = 0.6 },
		ui_click = { id = 15675059323, volume = 0.4 },
		ui_error = { id = 17208353912, volume = 0.45 },
		streak = { id = 17208372272, volume = 0.5 },
		event_start = { id = 15675085146, volume = 0.5 },
	},
	rarity = { preset = "standard7", tiers = STANDARD7 },
})

Theme.PRESETS = Freeze.freezeCopy({ ["framework-default"] = FRAMEWORK_DEFAULT })

local function isHex(v: any): boolean
	return type(v) == "string" and string.match(v, "^#%x%x%x%x%x%x$") ~= nil
end
Theme.isHex = isHex

local function check(theme: any, where: string, errors: { string })
	if type(theme) ~= "table" then
		table.insert(errors, `{where} must be a table`)
		return
	end
	if type(theme.colors) == "table" then
		for name, hex in theme.colors do
			if not isHex(hex) then
				table.insert(errors, `{where}.colors.{tostring(name)} must be '#RRGGBB'`)
			end
		end
	end
	if type(theme.fonts) == "table" then
		for name, f in theme.fonts do
			if type(f) ~= "string" then
				table.insert(errors, `{where}.fonts.{tostring(name)} must be a font family path`)
			end
		end
	end
	if type(theme.metrics) == "table" then
		for name, m in theme.metrics do
			if name == "text" then
				if type(m) ~= "table" then
					table.insert(errors, `{where}.metrics.text must be a table`)
				end
			elseif name == "minTextSize" and (type(m) ~= "number" or m ~= m or m < 6 or m > 32) then
				table.insert(errors, `{where}.metrics.minTextSize must be between 6 and 32`)
			elseif type(m) ~= "number" then
				table.insert(errors, `{where}.metrics.{tostring(name)} must be a number`)
			end
		end
	end
	if type(theme.sounds) == "table" then
		for key, s in theme.sounds do
			if type(s) ~= "table" or type(s.id) ~= "number" then
				table.insert(
					errors,
					`{where}.sounds.{tostring(key)} must be \{ id: number, volume?, pitch? }`
				)
			end
		end
	end
	local rarity = theme.rarity
	if type(rarity) == "table" then
		if rarity.preset ~= nil and Theme.RARITY_PRESETS[rarity.preset] == nil then
			table.insert(errors, `{where}.rarity.preset: unknown rarity preset '{tostring(rarity.preset)}'`)
		end
		if rarity.tiers ~= nil then
			if type(rarity.tiers) ~= "table" or #rarity.tiers == 0 then
				table.insert(errors, `{where}.rarity.tiers must be a non-empty list`)
			else
				for i, t in rarity.tiers do
					if type(t) ~= "table" or type(t.id) ~= "string" then
						table.insert(errors, `{where}.rarity.tiers[{i}] needs a string id`)
					elseif t.color ~= nil and not isHex(t.color) then
						table.insert(errors, `{where}.rarity.tiers[{i}].color must be '#RRGGBB'`)
					elseif t.glow ~= nil and not isHex(t.glow) then
						table.insert(errors, `{where}.rarity.tiers[{i}].glow must be '#RRGGBB'`)
					end
				end
			end
		end
	end
end

-- One layer on top of `merged`: maps deep-merge; rarity.preset / rarity.tiers replace the list.
local function apply(merged: any, layer: any): any
	local rarity = layer.rarity
	local out = Freeze.deepMerge(merged, layer)
	if type(rarity) == "table" then
		local tiers = rarity.tiers
		if tiers == nil and rarity.preset ~= nil then
			tiers = Theme.RARITY_PRESETS[rarity.preset]
		end
		if type(tiers) == "table" then
			out.rarity = if type(out.rarity) == "table" then out.rarity else {}
			out.rarity.tiers = Freeze.deepCopy(tiers)
			if rarity.tiers ~= nil and rarity.preset == nil then
				out.rarity.preset = nil
			end
		end
	end
	return out
end

-- Derived defaults: a tier without glow glows in its colour; glowStrength defaults to 0.
local function finish(merged: any): any
	local tiers = if type(merged.rarity) == "table" then merged.rarity.tiers else nil
	if type(tiers) == "table" then
		for _, t in tiers do
			if type(t) == "table" then
				t.glow = t.glow or t.color
				t.glowStrength = t.glowStrength or 0
			end
		end
	end
	return merged
end

-- A module's contribution: its `theme` table, or theme(config) for a config-driven theme
-- (v1.3.0: e.g. Rarity's tiers from config.Rarity.tiers). nil = nothing.
local function contribution(ref: any, configs: { [string]: any }?, errors: { string }): any
	local theme = ref.theme
	if type(theme) ~= "function" then
		return if type(theme) == "table" then theme else nil
	end
	local config = if configs then configs[ref.name] else nil
	local ok, result = pcall(theme, config)
	if not ok then
		table.insert(errors, `{tostring(ref.name)}.theme(config) failed: {tostring(result)}`)
		return nil
	end
	if result ~= nil and type(result) ~= "table" then
		table.insert(errors, `{tostring(ref.name)}.theme(config) must return a table of token groups`)
		return nil
	end
	return result
end

local TOP_LEVEL =
	{ preset = true, name = true, colors = true, fonts = true, metrics = true, sounds = true, rarity = true }
local CHECKED_GROUPS = { "colors", "fonts", "metrics" }

-- a key in the game's theme (or preset table) that no layer below
-- defines is almost always a typo (`metrics.minTouch` for `minTouchTarget`), and an unknown token
-- is never read by any UI, so it would silently do nothing. Warn, naming the key (like config's
-- unknown keys). `known` is the merged theme below the game's layer.
local function warnUnknown(layer: any, known: any, where: string, warnings: { string })
	if type(layer) ~= "table" then
		return
	end
	for key in layer do
		if not TOP_LEVEL[key] then
			table.insert(warnings, `{where}.{tostring(key)}: unknown theme group (typo?), ignored`)
		end
	end
	for _, group in CHECKED_GROUPS do
		local values = layer[group]
		local have = if type(known[group]) == "table" then known[group] else {}
		if type(values) == "table" then
			for key, v in values do
				if have[key] == nil then
					table.insert(
						warnings,
						`{where}.{group}.{tostring(key)}: unknown theme token (typo?); no UI reads it`
					)
				elseif
					group == "metrics"
					and key == "text"
					and type(v) == "table"
					and type(have.text) == "table"
				then
					for size in v do
						if have.text[size] == nil then
							table.insert(
								warnings,
								`{where}.metrics.text.{tostring(size)}: unknown theme token (typo?); no UI reads it`
							)
						end
					end
				end
			end
		end
	end
end

-- configs (optional): { [moduleName]: merged config }, passed to a function `theme`.
-- warnings (optional, added in v1.3.0): unknown game theme keys, named.
function Theme.merge(
	order: { any },
	gameTheme: any,
	errors: { string },
	configs: { [string]: any }?,
	warnings: { string }?
): any
	local base: any = FRAMEWORK_DEFAULT
	local presetName = "framework-default"
	if type(gameTheme) == "table" and gameTheme.preset ~= nil then
		if type(gameTheme.preset) == "table" then
			check(gameTheme.preset, "theme.preset", errors)
			if warnings then
				warnUnknown(gameTheme.preset, FRAMEWORK_DEFAULT, "theme.preset", warnings)
			end
			base = apply(Freeze.deepCopy(FRAMEWORK_DEFAULT), gameTheme.preset)
			presetName = if type(gameTheme.preset.name) == "string" then gameTheme.preset.name else "custom"
		elseif Theme.PRESETS[gameTheme.preset] ~= nil then
			base = Theme.PRESETS[gameTheme.preset]
			presetName = gameTheme.preset
		else
			table.insert(errors, `theme.preset: unknown preset '{tostring(gameTheme.preset)}'`)
		end
	end
	local merged = Freeze.deepCopy(base)
	merged.name = nil
	for _, ref in order do
		local layer = if type(ref) == "table" then contribution(ref, configs, errors) else nil
		if layer ~= nil then
			check(layer, `{tostring(ref.name)}.theme`, errors)
			merged = apply(merged, layer)
		end
	end
	if gameTheme ~= nil then
		if type(gameTheme) ~= "table" then
			table.insert(errors, "theme must be a table")
		else
			check(gameTheme, "theme", errors)
			if warnings then
				warnUnknown(gameTheme, merged, "theme", warnings)
			end
			local layer = table.clone(gameTheme)
			layer.preset = nil
			merged = apply(merged, layer)
		end
	end
	merged.preset = presetName
	return Freeze.deepFreeze(finish(merged))
end

-- The resolved framework-default theme (a game with no theme and no module contributions).
Theme.DEFAULT = Theme.merge({}, nil, {})

-- Pure lookups over a resolved theme ---------------------------------------------------------

function Theme.tier(theme: any, id: any): any
	local tiers = if type(theme) == "table" and type(theme.rarity) == "table" then theme.rarity.tiers else nil
	if type(id) ~= "string" or type(tiers) ~= "table" then
		return nil
	end
	for _, t in tiers do
		if t.id == id then
			return t
		end
	end
	return nil
end

-- { [tierId]: 1-based position } (tier order = list order).
function Theme.tierOrder(theme: any): { [string]: number }
	local out: { [string]: number } = {}
	local tiers = if type(theme) == "table" and type(theme.rarity) == "table" then theme.rarity.tiers else nil
	if type(tiers) == "table" then
		for i, t in tiers do
			out[t.id] = i
		end
	end
	return out
end

-- The sound entry for `key`, or nil when absent or silent (id 0).
function Theme.sound(theme: any, key: string): any
	local sounds = if type(theme) == "table" then theme.sounds else nil
	local s = if type(sounds) == "table" then sounds[key] else nil
	if type(s) ~= "table" or type(s.id) ~= "number" or s.id == 0 then
		return nil
	end
	return s
end

return Theme
