local ThemeTokens = require(script.Parent.ThemeTokens)
local SharedTheme = require(script.Parent.Parent.framework.shared.Theme)

describe("ThemeTokens (what UI components read)", function()
	it("reads the framework-default look", function()
		local t = ThemeTokens.new(SharedTheme.DEFAULT)
		expect(t.hex("accent")).toBe("#FFB547")
		expect(t.fontFamily("display")).toBe("rbxasset://fonts/families/FredokaOne.json")
		expect(t.fontFamily("bold")).toBe("rbxasset://fonts/families/BuilderSans.json")
		expect(t.metrics.cornerRadius).toBe(12)
		expect(t.text.number).toBe(28)
		expect(t.touchTarget).toBe(52) -- v1.2 Theme.touchTarget
		expect(t.tier("Epic").color).toBe("#B26BFF")
		expect(t.tierOrder.Secret).toBe(7)
		expect(t.sound("coin_tick").id).toBe(16480580213)
	end)

	it("changes with a custom theme: colours, fonts, metrics, sounds and rarity look", function()
		local custom = SharedTheme.merge({}, {
			colors = { accent = "#123456" },
			fonts = { display = "rbxasset://fonts/families/LuckiestGuy.json" },
			metrics = { cornerRadius = 4, minTouchTarget = 60, text = { small = 16 } },
			sounds = { coin_tick = { id = 42 } },
			rarity = { tiers = { { id = "Shiny", color = "#ABCDEF" } } },
		}, {})
		local t = ThemeTokens.new(custom)
		expect(t.hex("accent")).toBe("#123456")
		expect(t.fontFamily("display")).toBe("rbxasset://fonts/families/LuckiestGuy.json")
		expect(t.metrics.cornerRadius).toBe(4)
		expect(t.text.small).toBe(16)
		expect(t.touchTarget).toBe(71)
		expect(t.sound("coin_tick").id).toBe(42)
		expect(t.tier("Shiny").color).toBe("#ABCDEF")
		expect(t.tier("Common")).toBeNil()
		expect(t.tierOrder).toEqual({ Shiny = 1 })
	end)

	it("applies legacy GameConfig.palette overrides on top and errors on unknown keys", function()
		local t = ThemeTokens.new(SharedTheme.DEFAULT, { accent = "#000001" })
		expect(t.hex("accent")).toBe("#000001")
		expect(t.hex("surface")).toBe("#2B3050")
		expect(function()
			t.hex("nope")
		end).toThrow("unknown colour key nope")
	end)
end)
