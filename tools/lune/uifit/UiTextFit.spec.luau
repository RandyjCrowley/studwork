--!nocheck
-- Source/model fixtures are checked per component and viewport.
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local Checker = require("tools/lune/uifit/Checker.luau")
local Responsive = require("packages/ui/Responsive.luau")
local OddsLayout = require("packages/ui/OddsLayout.luau")
local ThemeTokens = require("packages/ui/ThemeTokens.luau")
local SharedTheme = require("packages/framework/shared/Theme.luau")
local ModalFit = require("packages/ui/ModalFit.luau")
local ItemCardLayout = require("packages/ui/ItemCardLayout.luau")
local tokens = ThemeTokens.new(SharedTheme.DEFAULT)
local minimum = tokens.metrics.minTextSize
local modalScale = ModalFit.minScale(tokens)
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
		{
			name = "name",
			text = longName,
			size = tokens.text.small,
			wrapped = true,
			truncateLines = 2,
			width = ItemCardLayout.WIDTH - 2 * ItemCardLayout.PADDING,
			height = ItemCardLayout.nameHeight(tokens.text.small),
		},
		{ name = "mutation", text = "RAINBOW", size = tokens.text.small, autoWidth = true },
		{ name = "income", text = "+999.99B/s", size = tokens.text.small, autoWidth = true },
	},
	["packages/ui/Leaderboard.luau"] = {
		{ name = "rank", text = "Top 100+", size = tokens.text.body, width = tokens.text.body * 6 },
		{ name = "name", text = longName, size = tokens.text.body, autoWidth = true }, -- Fill: the rest of the row
		{ name = "value", text = "999,999,999,999", size = tokens.text.body, autoWidth = true },
		{ name = "empty", text = "No scores yet", size = tokens.text.body, autoWidth = true },
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
			autoWidth = true, -- WrappedText measures the notice height from its actual width.
		},
		{
			name = "name",
			text = longName,
			size = tokens.text.body,
			wrapped = true,
			truncateLines = 2,
			width = OddsLayout.cellWidth(OddsLayout.columns.name, OddsLayout.MIN_ROW_WIDTH),
			height = OddsLayout.ROW_HEIGHT,
		},
		{
			name = "percent",
			text = "0.0001%",
			size = tokens.text.min, -- TextScaled percent shrinks to the theme constraint floor.
			width = OddsLayout.cellWidth(OddsLayout.columns.percent, OddsLayout.MIN_ROW_WIDTH),
		},
	},
	["packages/ui/Panel.luau"] = {
		{
			name = "title",
			text = "Extraordinary Rainbow Rewards",
			size = tokens.text.title,
			autoWidth = true,
		}, -- Panel title is TextScaled and width follows the caller.
	},
	["packages/ui/RarityBadge.luau"] = {
		{
			name = "tier",
			text = "LEGENDARY",
			size = tokens.text.small,
			width = OddsLayout.cellWidth(OddsLayout.columns.badge, OddsLayout.MIN_ROW_WIDTH) - 16,
		},
	},
	["packages/ui/Toast.luau"] = {
		{
			name = "message",
			text = longNotice,
			size = tokens.text.body,
			wrapped = true,
			autoWidth = true, -- Toast delegates height to WrappedText.
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
	truncation = {
		["packages/ui/OddsTable.luau"] = "Tap a name to reveal its full value",
		["packages/ui/ItemCard.luau"] = "Cards summarize names in two lines; the full name belongs in the odds table",
		["packages/ui/Leaderboard.luau"] = "A display name is at most 20 characters and the row gives it all the room the rank and value leave",
	},
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
local function walk(dir)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			walk(path)
		elseif string.match(name, "%.luau$") and not string.match(name, "%.spec%.luau$") then
			local source = fs.readFile(path)
			describe(path, function()
				it("is registered and follows source wrap/truncation rules", function()
					local check = table.clone(options)
					check.viewports = {}
					local problems = Checker.scan(path, source, check)
					assert(
						#problems == 0,
						path .. ": " .. (problems[1] and problems[1].rule .. " " .. problems[1].detail or "")
					)
				end)
				for _, viewport in viewports do
					it("fits modeled text at " .. viewport.name, function()
						local check = table.clone(options)
						check.viewports = { viewport }
						local problems = Checker.scan(path, source, check)
						assert(
							#problems == 0,
							path
								.. ": "
								.. (problems[1] and problems[1].rule .. " " .. problems[1].detail or "")
						)
					end)
				end
			end)
		end
	end
end
walk("packages/ui")

-- The fixtures above model the components; these lines tie each model to the exact source it
-- describes, so changing a component (a 1-px name box, a Toast that no longer follows its measured
-- text) fails here instead of leaving a stale fixture green (v1.6.2 review finding).
local PROVENANCE = {
	["packages/ui/ItemCard.luau"] = {
		"Size = UDim2.new(1, 0, 0, Layout.nameHeight(Theme.text.small))",
		"TextTruncate = Enum.TextTruncate.AtEnd",
	},
	["packages/ui/Toast.luau"] = { "e(WrappedText", "onHeight = setMeasured" },
	["packages/ui/OddsTable.luau"] = {
		"e(WrappedText",
		"UDim2.new(col.scale, col.offset, 0, ROW_HEIGHT)",
		"TextSize = Theme.text.body",
	},
	["packages/ui/Modal.luau"] = { "ModalFit.contentHeight(", "UDim2.new(1, 0, 0, scrollHeight)" },
	["packages/ui/Leaderboard.luau"] = {
		"local rankWidth = Theme.text.body * 6",
		"Size = UDim2.new(0, rankWidth, 1, 0)",
		"FlexMode = Enum.UIFlexMode.Fill",
	},
}
describe("text-fit fixtures match their component source", function()
	for path, needles in PROVENANCE do
		it(path, function()
			local source = fs.readFile(path)
			for _, needle in needles do
				if not string.find(source, needle, 1, true) then
					error(
						path
							.. " no longer contains `"
							.. needle
							.. "`: update the component's text-fit fixture"
					)
				end
			end
		end)
	end
end)
