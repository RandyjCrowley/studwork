local Theme = require(script.Parent.Theme)
local Palette = require(script.Parent.Parent.test.fixtures.PaletteV12)
local Sounds = require(script.Parent.Parent.test.fixtures.SoundsV12)
local RarityTiers = require(script.Parent.Parent.test.fixtures.RarityTiersV12)

local function merge(order, gameTheme)
	local errors = {}
	local t = Theme.merge(order, gameTheme, errors)
	return t, errors
end

describe("Theme framework-default preset (golden: today's look)", function()
	local d = Theme.DEFAULT

	it("has every v1.2 Palette colour, font and metric unchanged", function()
		for key, hex in Palette.colors do
			expect(d.colors[key]).toBe(hex)
		end
		for key, font in Palette.fonts do
			expect(d.fonts[key]).toBe(font)
		end
		for key, value in Palette.metrics do
			expect(d.metrics[key]).toBe(value)
		end
	end)

	it("pins the literal v1.2 tokens", function()
		expect(d.preset).toBe("framework-default")
		expect(d.colors.accent).toBe("#FFB547")
		expect(d.colors.surface).toBe("#2B3050")
		expect(d.colors.outline).toBe("#14172A")
		expect(d.colors.text).toBe("#FFF8EC")
		expect(d.colors.backdrop).toBe("#000000")
		expect(d.colors.dropShadow).toBe("#000000")
		expect(d.fonts.display).toBe("rbxasset://fonts/families/FredokaOne.json")
		expect(d.metrics).toEqual({
			cornerRadius = 12,
			padding = 12,
			strokeThickness = 2,
			minTouchTarget = 44,
			text = { small = 14, body = 18, title = 24, number = 28 },
		})
	end)

	it("has every v1.2 sound unchanged", function()
		local n = 0
		for key, entry in Sounds do
			n += 1
			expect(d.sounds[key]).toEqual(entry)
		end
		local m = 0
		for _ in d.sounds do
			m += 1
		end
		expect(m).toBe(n)
	end)

	it("has the standard7 rarity look in v1.2 order", function()
		expect(d.rarity.preset).toBe("standard7")
		expect(#d.rarity.tiers).toBe(#RarityTiers.ORDER)
		for i, id in RarityTiers.ORDER do
			local want = RarityTiers.get(id)
			local got = d.rarity.tiers[i]
			expect(got.id).toBe(want.id)
			expect(got.color).toBe(want.color)
			expect(got.glow).toBe(want.glow)
			expect(got.glowStrength).toBe(want.glowStrength)
			expect(got.soundKey).toBe(want.soundKey)
			expect(Theme.tierOrder(d)[id]).toBe(want.order)
		end
	end)

	it("is frozen and equals an explicit framework-default merge", function()
		expect(table.isfrozen(d)).toBe(true)
		expect(table.isfrozen(d.rarity.tiers[1])).toBe(true)
		local t, errors = merge({}, { preset = "framework-default" })
		expect(#errors).toBe(0)
		expect(t).toEqual(d)
	end)
end)

describe("Theme.merge custom themes", function()
	it("deep-merges colours, fonts, metrics and sounds from the game", function()
		local t, errors = merge({}, {
			colors = { accent = "#FF5DA2" },
			fonts = { display = "rbxasset://fonts/families/LuckiestGuy.json" },
			metrics = { cornerRadius = 8, text = { body = 20 } },
			sounds = { coin_tick = { id = 123, volume = 0.3 }, new_key = { id = 9 } },
		})
		expect(#errors).toBe(0)
		expect(t.colors.accent).toBe("#FF5DA2")
		expect(t.colors.surface).toBe("#2B3050")
		expect(t.fonts.display).toBe("rbxasset://fonts/families/LuckiestGuy.json")
		expect(t.fonts.body).toBe("rbxasset://fonts/families/BuilderSans.json")
		expect(t.metrics.cornerRadius).toBe(8)
		expect(t.metrics.padding).toBe(12)
		expect(t.metrics.text.body).toBe(20)
		expect(t.metrics.text.title).toBe(24)
		expect(Theme.sound(t, "coin_tick")).toEqual({ id = 123, volume = 0.3 })
		expect(Theme.sound(t, "new_key").id).toBe(9)
		expect(Theme.sound(t, "purchase").id).toBe(17208380755)
	end)

	it("layers module contributions in boot order, then the game", function()
		local a = { name = "A", theme = { colors = { accent = "#111111", success = "#222222" } } }
		local b = { name = "B", theme = { colors = { accent = "#333333" } } }
		local t = merge({ a, b }, { colors = { success = "#444444" } })
		expect(t.colors.accent).toBe("#333333")
		expect(t.colors.success).toBe("#444444")
	end)

	it("replaces the rarity tier list (Collection's theme.rarity) and keeps list order", function()
		local collection = {
			name = "Rarity",
			theme = {
				rarity = {
					tiers = {
						{ id = "Bronze", color = "#CD7F32", soundKey = "r1" },
						{ id = "Gold", color = "#FFD700", glow = "#FFF2A0", glowStrength = 0.5 },
					},
				},
			},
		}
		local t = merge({ collection }, nil)
		expect(#t.rarity.tiers).toBe(2)
		expect(Theme.tier(t, "Bronze").glow).toBe("#CD7F32") -- glow defaults to colour
		expect(Theme.tier(t, "Bronze").glowStrength).toBe(0)
		expect(Theme.tier(t, "Gold").glowStrength).toBe(0.5)
		expect(Theme.tier(t, "Common")).toBeNil()
		expect(Theme.tierOrder(t)).toEqual({ Bronze = 1, Gold = 2 })
		-- the game can return to the preset
		local back = merge({ collection }, { rarity = { preset = "standard7" } })
		expect(#back.rarity.tiers).toBe(7)
		expect(back.rarity.tiers[7].id).toBe("Secret")
	end)

	it("accepts a game-supplied preset table on top of framework-default", function()
		local t, errors = merge({}, {
			preset = { name = "candy", colors = { surface = "#FFE0F0" }, metrics = { cornerRadius = 20 } },
			colors = { accent = "#FF00AA" },
		})
		expect(#errors).toBe(0)
		expect(t.preset).toBe("candy")
		expect(t.colors.surface).toBe("#FFE0F0")
		expect(t.colors.accent).toBe("#FF00AA")
		expect(t.metrics.cornerRadius).toBe(20)
		expect(t.colors.text).toBe("#FFF8EC")
	end)

	it("reports bad tokens", function()
		local _, errors = merge({}, {
			preset = "nope",
			colors = { a = "red" },
			metrics = { padding = "big" },
			sounds = { x = { volume = 1 } },
			rarity = { preset = "standard9", tiers = { { id = "X", color = "blue" } } },
		})
		local all = table.concat(errors, "\n")
		expect(all).toContain("theme.preset: unknown preset 'nope'")
		expect(all).toContain("theme.colors.a must be '#RRGGBB'")
		expect(all).toContain("theme.metrics.padding must be a number")
		expect(all).toContain("theme.sounds.x must be")
		expect(all).toContain("unknown rarity preset 'standard9'")
		expect(all).toContain("theme.rarity.tiers[1].color must be '#RRGGBB'")
	end)

	it("treats id 0 as silent", function()
		local t = merge({}, { sounds = { ui_click = { id = 0 } } })
		expect(Theme.sound(t, "ui_click")).toBeNil()
	end)
end)

describe("Theme unknown keys", function()
	local function warnOf(order, gameTheme)
		local errors, warnings = {}, {}
		local t = Theme.merge(order, gameTheme, errors, nil, warnings)
		return t, errors, table.concat(warnings, "\n")
	end

	it("warns, naming the key, for a token no layer defines (the old doc names)", function()
		local t, errors, w = warnOf({}, {
			colors = { panel = "#101010", accent = "#FF5DA2" },
			metrics = { minTouch = 60, outline = 3, text = { huge = 40 } },
			fonts = { headline = "rbxasset://fonts/families/LuckiestGuy.json" },
			colours = {},
		})
		expect(#errors).toBe(0)
		expect(w).toContain("theme.colors.panel")
		expect(w).toContain("theme.metrics.minTouch")
		expect(w).toContain("theme.metrics.outline")
		expect(w).toContain("theme.metrics.text.huge")
		expect(w).toContain("theme.fonts.headline")
		expect(w).toContain("theme.colours")
		expect((string.find(w, "accent", 1, true))).toBeNil()
		expect(t.colors.accent).toBe("#FF5DA2")
	end)

	it("knows the real tokens and module-contributed ones (no warning)", function()
		local mod = { name = "Quests", theme = { colors = { questGold = "#FFD23F" } } }
		local _, _, w = warnOf({ mod }, {
			colors = { surface = "#222222", accentAlt = "#00FF00", questGold = "#FFFFFF" },
			metrics = { strokeThickness = 3, minTouchTarget = 48, text = { body = 20 } },
			fonts = { display = "rbxasset://fonts/families/LuckiestGuy.json" },
			sounds = { coin_tick = { id = 1 } },
			rarity = { preset = "standard7" },
		})
		expect(w).toBe("")
	end)

	it("reaches boot: ConfigValidate passes the warnings through", function()
		local ConfigValidate = require(script.Parent.ConfigValidate)
		local result = ConfigValidate.validate({}, { theme = { metrics = { minTouch = 60 } } })
		expect(table.concat(result.warnings, "\n")).toContain("theme.metrics.minTouch")
	end)
end)
