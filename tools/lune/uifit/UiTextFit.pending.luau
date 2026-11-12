--!nocheck
-- Rename to UiTextFit.spec.luau only after the UI contract lands.
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local Checker = require("tools/lune/uifit/Checker.luau")
local Responsive = require("packages/ui/Responsive.luau")
local OddsLayout = require("packages/ui/OddsLayout.luau")
local ThemeTokens = require("packages/ui/ThemeTokens.luau")
local SharedTheme = require("packages/framework/shared/Theme.luau")
local ModalFit = require("packages/ui/ModalFit.luau")
local tokens = ThemeTokens.new(SharedTheme.DEFAULT)
local minimum = tokens.metrics.minTextSize or 11
local modalScale = if ModalFit.minScale then ModalFit.minScale(tokens) else 0.665
local viewports = {
	{ name = "desktop", x = 1280, y = 720 },
	{ name = "small phone", x = 667, y = 375 },
	{ name = "large phone", x = 926, y = 428 },
	{ name = "tablet", x = 1024, y = 768 },
}
local longName = "Legendary Rainbow Sword of the Ancients"
local longNotice =
	"Paid random items are restricted in your region. You can still earn these rewards by playing."
-- These are geometry fixtures, not an exemption list. Every text-bearing source needs one.
local fixtures = {
	["packages/ui/Button.luau"] = {
		{ name = "button", text = "Upgrade income (5000000)", size = tokens.text.body, autoWidth = true },
	},
	["packages/ui/CurrencyCounter.luau"] = {
		{ name = "amount", text = "999.99T", size = tokens.text.number, autoWidth = true },
		{ name = "rate", text = "+999.99B/s", size = tokens.text.small, autoWidth = true },
	},
	["packages/ui/ItemCard.luau"] = {
		{ name = "name", text = longName, size = tokens.text.min, wrapped = true, width = 130, height = 48 },
		{ name = "mutation", text = "RAINBOW", size = tokens.text.small, autoWidth = true },
	},
	["packages/ui/Modal.luau"] = {
		{ name = "close", text = "X", size = tokens.text.title, width = tokens.touchTarget },
	},
	["packages/ui/OddsTable.luau"] = {
		{
			name = "notice",
			text = longNotice,
			size = tokens.text.small,
			wrapped = true,
			width = OddsLayout.MIN_ROW_WIDTH - 16,
			height = 80,
		},
		{
			name = "name",
			text = longName,
			size = tokens.text.min,
			wrapped = true,
			width = OddsLayout.cellWidth(OddsLayout.columns.name, OddsLayout.MIN_ROW_WIDTH),
			height = 48,
		},
		{
			name = "percent",
			text = "0.0001%",
			size = tokens.text.min,
			width = OddsLayout.cellWidth(OddsLayout.columns.percent, OddsLayout.MIN_ROW_WIDTH),
		},
	},
	["packages/ui/Panel.luau"] = {
		{ name = "title", text = "Extraordinary Rainbow Rewards", size = tokens.text.min, width = 580 },
	},
	["packages/ui/RarityBadge.luau"] = {
		{
			name = "tier",
			text = "LEGENDARY",
			size = tokens.text.min,
			width = OddsLayout.cellWidth(OddsLayout.columns.badge, OddsLayout.MIN_ROW_WIDTH) - 16,
		},
	},
	["packages/ui/Toast.luau"] = {
		{
			name = "message",
			text = longNotice,
			size = tokens.text.body,
			wrapped = true,
			width = 340,
			height = 120,
		},
	},
	["packages/ui/screens/Inventory.luau"] = {
		{ name = "empty", text = "Nothing here yet.", size = tokens.text.body, autoWidth = true },
	},
	["packages/ui/screens/Mailbox.luau"] = {
		{ name = "empty", text = "Your mailbox is empty.", size = tokens.text.body, autoWidth = true },
	},
}
-- The wrapper's measured height is tested in Studio; component source must not use auto-Y.
fixtures["packages/ui/WrappedText.luau"] =
	{ { name = "measured text", text = longNotice, size = tokens.text.small, autoWidth = true } }
local options = {
	covered = fixtures,
	fixtures = fixtures,
	truncation = { ["packages/ui/OddsTable.luau"] = "Tap a name to reveal its full value" },
	modal = {
		["packages/ui/Modal.luau"] = true,
		["packages/ui/OddsTable.luau"] = true,
		["packages/ui/screens/Inventory.luau"] = true,
		["packages/ui/screens/Mailbox.luau"] = true,
	},
	minTextSize = minimum,
	modalScale = modalScale,
	scale = Responsive.scale,
	glyphWidth = OddsLayout.GLYPH_WIDTH,
	viewports = viewports,
}
local failures = {}
local function walk(dir)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			walk(path)
		elseif string.match(name, "%.luau$") and not string.match(name, "%.spec%.luau$") then
			local problems = Checker.scan(path, fs.readFile(path), options)
			for _, problem in problems do
				table.insert(failures, problem.rule .. " " .. problem.path .. ": " .. problem.detail)
			end
		end
	end
end
walk("packages/ui")
table.sort(failures)
assert(#failures == 0, table.concat(failures, "\n"))
