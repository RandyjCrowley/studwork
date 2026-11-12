--!nocheck
--!nolint DeprecatedApi
-- v1.6.1 playtest finding: OddsTable cut off its rarity labels ("LEGENDARY" overflowed the badge
-- cell) and item names ("..."). Lune can't render text, so this checks the structure the fit
-- relies on: Scale columns wide enough for the longest label at the theme's minimum text size,
-- TextScaled/TextWrapped labels with a theme UITextSizeConstraint, no TextTruncate, theme tokens.
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local OddsLayout = require(script.Parent.OddsLayout)
local TextFit = require(script.Parent.TextFit)
local ThemeTokens = require(script.Parent.ThemeTokens)
local SharedTheme = require(script.Parent.Parent.framework.shared.Theme)

local SOURCE = fs.readFile("packages/ui/OddsTable.luau")
local BADGE = fs.readFile("packages/ui/RarityBadge.luau")

-- Viewports (design px, landscape + phone portrait) the odds panel must fit in.
local VIEWPORTS = {
	{ name = "Studio default", x = 1280, y = 720 },
	{ name = "small phone", x = 667, y = 375 },
	{ name = "large phone", x = 926, y = 428 },
	{ name = "tablet", x = 1024, y = 768 },
	{ name = "small phone portrait", x = 375, y = 667 },
	{ name = "large phone portrait", x = 428, y = 926 },
}
local LONG_RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Divine" }
local LONG_PERCENTS = { "0.0001%", "12.345%", "100%" }

-- the label's source block: from `<Key> = e("TextLabel"` to the next sibling at the same indent
local function block(source: string, key: string): string
	local s = string.find(source, "\t\t" .. key .. ' = e%("TextLabel"')
	assert(s, "no TextLabel " .. key)
	local stop = string.find(source, "\n\t\t%a+ = ", s + 1) or #source
	return string.sub(source, s, stop)
end

local function minTextSize(): number
	local tokens = ThemeTokens.new(SharedTheme.DEFAULT)
	return TextFit.fixedLabel(tokens.text.body, tokens.text.min).MinTextSize
end

describe("UI.OddsTable fit (v1.6.1)", function()
	it("the theme defines text.min and fixedLabel uses it as the floor", function()
		local tokens = ThemeTokens.new(SharedTheme.DEFAULT)
		expect(type(tokens.text.min)).toBe("number")
		expect(tokens.text.min <= tokens.text.small).toBe(true)
		expect(TextFit.fixedLabel(18, 11).MinTextSize).toBe(11)
		expect(TextFit.fixedLabel(18).MinTextSize).toBe(TextFit.MIN_TEXT_SIZE)
	end)

	it("columns are Scale fractions that tile the row without overlap", function()
		local c = OddsLayout.columns
		expect(c.name.scale > 0 and c.badge.scale > 0 and c.percent.scale > 0).toBe(true)
		expect(math.abs(c.name.scale + c.badge.scale + c.percent.scale - 1) < 1e-9).toBe(true)
		expect(c.badge.x).toBe(c.name.x + c.name.scale)
		expect(c.percent.x).toBe(c.badge.x + c.badge.scale)
		for _, col in c do
			expect(col.offset <= 0).toBe(true) -- offsets only trim, never a fixed width
		end
	end)

	it("no viewport lays a row out narrower than MIN_ROW_WIDTH", function()
		-- the Modal is at least 320 design px wide (then UIScale-d down uniformly to fit)
		expect(OddsLayout.MIN_ROW_WIDTH).toBe(320 - 24 - 6)
		for _, v in VIEWPORTS do
			-- ModalFit keeps the panel within 92% of the width: never below 320 at these sizes
			expect(v.x * 0.92 >= 320).toBe(true)
		end
	end)

	it("the longest rarity label fits its badge at the minimum text size", function()
		local w = OddsLayout.cellWidth(OddsLayout.columns.badge, OddsLayout.MIN_ROW_WIDTH)
		for _, r in LONG_RARITIES do
			local need = OddsLayout.estimateWidth(string.upper(r), minTextSize())
				+ 2 * OddsLayout.BADGE_PADDING
			if need > w then
				error(string.format("%s needs %.1f px, badge cell is %.1f px", r, need, w))
			end
		end
	end)

	it("the longest percentage fits its cell at the minimum text size", function()
		local w = OddsLayout.cellWidth(OddsLayout.columns.percent, OddsLayout.MIN_ROW_WIDTH)
		for _, p in LONG_PERCENTS do
			expect(OddsLayout.estimateWidth(p, minTextSize()) <= w).toBe(true)
		end
	end)

	it("a long item name word fits its cell at the minimum text size (names wrap)", function()
		local w = OddsLayout.cellWidth(OddsLayout.columns.name, OddsLayout.MIN_ROW_WIDTH)
		expect(OddsLayout.estimateWidth("Legendary", minTextSize()) <= w).toBe(true)
	end)

	it("Name and Percent labels scale with a theme constraint and never truncate", function()
		expect(SOURCE).never.toContain("TextTruncate")
		for _, key in { "Name", "Percent" } do
			local b = block(SOURCE, key)
			expect(b).toContain("TextScaled = true")
			expect(b).toContain("UITextSizeConstraint")
			expect(b).toContain("minText(Theme.text.body)")
			expect(b).toContain("MaxTextSize = Theme.text.body")
			expect(b).toContain("FontFace = Theme.font(")
			expect(b).toContain("TextColor3 = ")
			expect(b).never.toContain("UDim2.fromOffset(")
		end
		expect(block(SOURCE, "Name")).toContain("TextWrapped = true")
		expect(SOURCE).toContain("TextFit.fixedLabel(maxSize, Theme.text.min)")
	end)

	it("rows use OddsLayout Scale cells and give the badge a size (so it scales)", function()
		expect(SOURCE).toContain("UDim2.new(col.scale, col.offset, 1, 0)")
		expect(SOURCE).toContain("size = UDim2.new(1, 0, 0, OddsLayout.BADGE_HEIGHT)")
		-- RarityBadge: a sized badge is TextScaled with the theme min/max
		expect(BADGE).toContain("TextScaled = props.size ~= nil")
		expect(BADGE).toContain("TextFit.fixedLabel(Theme.text.small, Theme.text.min)")
	end)

	it("no literal text sizes or colours in the odds row", function()
		expect(string.find(SOURCE, "TextSize = %d")).toBeNil()
		expect(string.find(SOURCE, "Font%.new")).toBeNil()
		expect(SOURCE).never.toContain("Color3.fromRGB")
		expect(string.find(SOURCE, "#%x%x%x%x%x%x")).toBeNil()
	end)
end)
