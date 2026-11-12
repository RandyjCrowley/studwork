--!nocheck
--!nolint DeprecatedApi
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local Layout = require("packages/ui/ItemCardLayout.luau")
local Tokens = require("packages/ui/ThemeTokens.luau")
local Shared = require("packages/framework/shared/Theme.luau")
local Responsive = require("packages/ui/Responsive.luau")
local tokens = Tokens.new(Shared.DEFAULT)

describe("ItemCard fixed two-line name", function()
	it("fits every optional row and four gaps inside the aspect-constrained card", function()
		expect(Layout.usedHeight(tokens.text.small) <= Layout.WIDTH / Layout.ASPECT).toBe(true)
	end)
	it("the icon takes what the rows leave, so the card never overflows its size", function()
		-- v1.6.2 Studio check: the Inventory grid's 96x128 cards needed 178 design px with a fixed
		-- 48-px icon and every optional row.
		local default =
			Layout.iconSize(Layout.WIDTH, Layout.WIDTH / Layout.ASPECT, tokens.text.small, true, true)
		expect(default > 0).toBe(true)
		expect(default + Layout.rowsHeight(tokens.text.small, true, true) <= Layout.WIDTH / Layout.ASPECT).toBe(
			true
		)
		for _, rows in { { false, false }, { true, false }, { true, true } } do
			local icon = Layout.iconSize(120, 160, tokens.text.small, rows[1], rows[2])
			expect(icon >= 24).toBe(true) -- the Inventory card keeps a visible icon
			expect(icon + Layout.rowsHeight(tokens.text.small, rows[1], rows[2]) <= 160).toBe(true)
		end
		expect(Layout.iconSize(40, 40, tokens.text.small, true, true)).toBe(0) -- never negative
		local source = fs.readFile("packages/ui/ItemCard.luau")
		expect(string.find(source, "Size = UDim2.fromOffset(icon, icon)", 1, true) ~= nil).toBe(true)
		expect(string.find(source, "Layout.ICON, Layout.ICON", 1, true)).toBeNil()
		local inventory = fs.readFile("packages/ui/screens/Inventory.luau")
		expect(string.find(inventory, "local CARD = Vector2.new(120, 160)", 1, true) ~= nil).toBe(true)
	end)
	it("keeps fixed themed text above the real-pixel floor on a small phone", function()
		expect(tokens.text.small * Responsive.scale(667, 375) >= tokens.metrics.minTextSize).toBe(true)
	end)
	it("uses a two-line ellipsis without cutting the original name", function()
		local source = fs.readFile("packages/ui/ItemCard.luau")
		expect(string.find(source, "Text = props.name", 1, true) ~= nil).toBe(true)
		expect(string.find(source, "TextTruncate = Enum.TextTruncate.AtEnd", 1, true) ~= nil).toBe(true)
		expect(string.find(source, "Layout.nameHeight(Theme.text.small)", 1, true) ~= nil).toBe(true)
		expect(string.find(source, "TextSize = Theme.text.small", 1, true) ~= nil).toBe(true)
		expect(string.find(source, "Primitives.textSize(12", 1, true) == nil).toBe(true)
	end)
end)
