local ModalFit = require(script.Parent.ModalFit)
local ThemeTokens = require(script.Parent.ThemeTokens)
local SharedTheme = require(script.Parent.Parent.framework.shared.Theme)
local Responsive = require(script.Parent.Responsive)

describe("UI.ModalFit", function()
	it("leaves a panel that fits alone", function()
		expect(ModalFit.fitScale(400, 300, 1000, 700)).toBe(1)
	end)
	it("shrinks a tall panel to 88% of the screen height", function()
		-- the v1.2 playtest case: 662 px panel on a 635 px screen
		local s = ModalFit.fitScale(607, 662, 1081, 635)
		expect(math.abs(662 * s - 635 * 0.88) < 0.001).toBe(true)
	end)
	it("shrinks a wide panel to 92% of the screen width", function()
		local s = ModalFit.fitScale(1000, 100, 500, 1000)
		expect(math.abs(1000 * s - 460) < 0.001).toBe(true)
	end)
	it("returns 1 for unknown sizes", function()
		expect(ModalFit.fitScale(0, 100, 500, 500)).toBe(1)
		expect(ModalFit.fitScale(100, 100, 0, 0)).toBe(1)
	end)
	it("caps the scroll area in the content's design pixels, not real pixels (v1.6.2)", function()
		-- v1.6.2 Studio finding: an 824-px-tall screen under a 1.75 responsive scale holds
		-- 824 / 1.75 = 471 design px; dividing real pixels by the fit scale alone allowed
		-- 665 design px, so the panel ran off the top and bottom of the screen.
		local h = ModalFit.contentHeight(824, 1.75, 1, 100, 1500, 44)
		expect(math.abs(h - (824 / 1.75 * 0.88 - 100)) < 0.001).toBe(true)
		expect(h + 100 <= 824 / 1.75 * 0.88 + 0.001).toBe(true)
		-- the Modal's own fit scale shrinks the panel, so the content may be taller
		expect(
			math.abs(ModalFit.contentHeight(824, 1.75, 0.5, 100, 1500, 44) - (824 / 1.75 / 0.5 * 0.88 - 100))
				< 0.001
		).toBe(true)
	end)
	it("uses the content's own height when it fits, and a touch-target floor on tiny screens", function()
		expect(ModalFit.contentHeight(824, 1.75, 1, 100, 120, 44)).toBe(120)
		expect(ModalFit.contentHeight(100, 1, 1, 100, 500, 44)).toBe(44)
		expect(ModalFit.contentHeight(100, 1, 1, 100, 10, 44)).toBe(10)
	end)
	it("keeps the smallest text at the real pixel floor at minimum responsive scale", function()
		local tokens = ThemeTokens.new(SharedTheme.DEFAULT)
		local scale = ModalFit.minScale(tokens)
		expect(scale <= 1).toBe(true)
		expect(tokens.text.min * Responsive.MIN_SCALE * scale >= tokens.metrics.minTextSize - 0.001).toBe(
			true
		)
	end)
end)
