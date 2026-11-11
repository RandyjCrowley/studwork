--!nocheck
-- Playtest finding (v1.3.0): UI kit text fits its box for any theme font.
local TextFit = require(script.Parent.TextFit)
local ThemeTokens = require(script.Parent.ThemeTokens)
local SharedTheme = require(script.Parent.Parent.framework.shared.Theme)

local BUTTON = { padding = 16, iconWidth = 0, gap = 6, minWidth = 44 }

describe("UI.TextFit", function()
	it("a button is at least as wide as its text in the real font (the LuckiestGuy overflow)", function()
		-- "Upgrade income (50)" at 18 px: about 160 px in FredokaOne, about 205 px in LuckiestGuy
		expect(TextFit.buttonMinWidth(205, BUTTON)).toBe(205 + 32)
		expect(TextFit.buttonMinWidth(160, BUTTON)).toBe(160 + 32)
		expect(TextFit.buttonMinWidth(204.2, BUTTON)).toBe(237)
	end)

	it("counts the icon and its gap, and never goes below the touch target", function()
		expect(TextFit.buttonMinWidth(100, { padding = 16, iconWidth = 26, gap = 6, minWidth = 44 })).toBe(
			164
		)
		expect(TextFit.buttonMinWidth(0, BUTTON)).toBe(44)
		expect(TextFit.buttonMinWidth(0 / 0, BUTTON)).toBe(44)
		expect(TextFit.buttonMinWidth(math.huge, BUTTON)).toBe(44)
	end)

	it("fixed-width text scales down, capped at the theme size", function()
		local fit = TextFit.fixedLabel(18)
		expect(fit.TextScaled).toBe(true)
		expect(fit.MaxTextSize).toBe(18)
		expect(fit.TextSize).toBe(18)
		expect(fit.MinTextSize <= 18).toBe(true)
		expect(TextFit.fixedLabel(6).MinTextSize).toBe(6)
	end)

	it("golden: auto-width text keeps the v1.2 look (the theme body size, not scaled)", function()
		local tokens = ThemeTokens.new(SharedTheme.DEFAULT)
		local fit = TextFit.autoLabel(tokens.text.body)
		expect(fit.TextScaled).toBe(false)
		expect(fit.TextSize).toBe(18)
		expect(fit.MaxTextSize).toBeNil()
	end)
end)
