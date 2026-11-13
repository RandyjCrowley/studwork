--!nocheck
--!nolint DeprecatedApi
--[[
	Offline UI-fit check for the quests kit (the repo's tools/lune/uifit Checker, the same one
	packages/ui is checked with) at the four standard viewports, 667x375 (small phone) among them:
	the board (Board, Row), the tracker, the toasts and the Goals pill.

	React isn't available under Lune (known issue U5), so the geometry is modeled, like the packages/ui
	fixtures in tools/lune/uifit/UiTextFit.spec.luau, and each model is tied to its source with
	needles so a changed component fails here instead of leaving a stale model green.

	What this pins (Studio findings, v1.8.0):
	  * board: UI.Modal gets no `size` (the 0.85 x 0 size hung the panel off-screen); at 667x375 the
	    modal is wide enough for its content and narrower than the screen
	  * objective line: name and value have layout orders (they rendered as "0/1Visit the tower")
	  * reward chip: auto-sized, never wrapped (it rendered "sta/r")
	  * pill: its width cap follows the camera's viewport, with a floor (it collapsed to "Co…")
]]
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local Checker = require("tools/lune/uifit/Checker.luau")
local Responsive = require("packages/ui/Responsive.luau")
local OddsLayout = require("packages/ui/OddsLayout.luau")
local ThemeTokens = require("packages/ui/ThemeTokens.luau")
local SharedTheme = require("packages/framework/shared/Theme.luau")
local ModalFit = require("packages/ui/ModalFit.luau")
local Pill = require("packages/kits/quests/Goals/client/Pill.luau")

local tokens = ThemeTokens.new(SharedTheme.DEFAULT)
local viewports = {
	{ name = "desktop", x = 1280, y = 720 },
	{ name = "small phone 667x375", x = 667, y = 375 },
	{ name = "large phone", x = 926, y = 428 },
	{ name = "tablet", x = 1024, y = 768 },
}

local QUESTS = "packages/kits/quests/Quests/client/"
local GOALS = "packages/kits/quests/Goals/client/"
local longTitle = "Defeat forty-two of the Legendary Rainbow Guardians"
local longReward = "1,000,000 Legendary Rainbow Coins"

-- Geometry fixtures for every text-bearing source of the kit's client (a file with text and no entry
-- fails the checker's coverage rule).
local fixtures = {
	[QUESTS .. "Row.luau"] = {
		{ name = "title", text = longTitle, size = tokens.text.small, wrapped = true, autoWidth = true },
		{
			name = "objective name",
			text = "Visit the tower",
			size = tokens.text.small,
			wrapped = true,
			autoWidth = true,
		},
		{
			name = "objective value",
			text = "999,999/999,999",
			size = tokens.text.small,
			wrapped = true,
			autoWidth = true,
		},
		{ name = "reward chip", text = longReward, size = tokens.text.small, autoWidth = true },
	},
	[QUESTS .. "Tracker.luau"] = {
		{
			name = "tracker title",
			text = longTitle,
			size = tokens.text.small,
			wrapped = true,
			autoWidth = true,
		},
		{
			name = "tracker value",
			text = "999,999/999,999",
			size = tokens.text.small,
			wrapped = true,
			autoWidth = true,
		},
	},
	[GOALS .. "Pill.luau"] = {
		{ name = "goal text", text = longTitle, size = tokens.text.small, autoWidth = true },
	},
}
local options = {
	covered = fixtures,
	fixtures = fixtures,
	truncation = {
		[GOALS .. "Pill.luau"] = "One line, ellipsized; the board lists the full goal text",
	},
	modal = { [QUESTS .. "Row.luau"] = true, [QUESTS .. "Board.luau"] = true },
	minTextSize = tokens.metrics.minTextSize,
	modalScale = ModalFit.minScale(tokens),
	scale = Responsive.scale,
	glyphWidth = OddsLayout.GLYPH_WIDTH,
	viewports = viewports,
}

local function readAll(dir)
	local out = {}
	for _, name in fs.readDir(dir) do
		if string.match(name, "%.luau$") and not string.match(name, "%.spec%.luau$") then
			out[dir .. name] = fs.readFile(dir .. name)
		end
	end
	return out
end

local sources = table.clone(readAll(QUESTS))
for path, src in readAll(GOALS) do
	sources[path] = src
end

local function codeOf(path)
	local lines = {}
	for line in string.gmatch(sources[path] .. "\n", "(.-)\n") do
		if not string.match(line, "^%s*%-%-") then
			table.insert(lines, line)
		end
	end
	return table.concat(lines, "\n")
end

local function has(path, needle)
	return string.find(codeOf(path), needle, 1, true) ~= nil
end

describe("quests client: text fit (tools/lune/uifit Checker)", function()
	for path, source in sources do
		it(path .. " follows the wrap / truncation / coverage rules", function()
			local check = table.clone(options)
			check.viewports = {}
			local problems = Checker.scan(path, source, check)
			assert(
				#problems == 0,
				path .. ": " .. (problems[1] and problems[1].rule .. " " .. problems[1].detail or "")
			)
		end)
		for _, viewport in viewports do
			it(path .. " fits modeled text at " .. viewport.name, function()
				local check = table.clone(options)
				check.viewports = { viewport }
				local problems = Checker.scan(path, source, check)
				assert(
					#problems == 0,
					path .. ": " .. (problems[1] and problems[1].rule .. " " .. problems[1].detail or "")
				)
			end)
		end
	end
end)

describe("quests client: 667x375", function()
	local phone = { x = 667, y = 375 }

	it(
		"the board's modal: no size given, so UI.Modal's own 0.6-wide scrolling panel (320-640 px) fits",
		function()
			local board = codeOf(QUESTS .. "Board.luau")
			local i = string.find(board, "e(UI.Modal, {", 1, true)
			assert(i ~= nil, "Board no longer renders UI.Modal")
			local block = string.sub(board, i, string.find(board, "}, children)", i, true))
			expect(string.find(block, "size%s*=") == nil).toBe(true)
			-- the panel width UI.Modal gives (Modal.luau: fromScale(0.6) clamped to 320..640) fits the screen
			local width = math.clamp(phone.x * 0.6, 320, 640)
			expect(width <= phone.x).toBe(true)
			expect(width >= 320).toBe(true)
			-- and the modal source still sizes that way (a model tied to its source)
			local modal = fs.readFile("packages/ui/Modal.luau")
			expect(string.find(modal, "UDim2.fromScale(0.6, 0)", 1, true) ~= nil).toBe(true)
			expect(
				string.find(modal, "MinSize = Vector2.new(320, 0), MaxSize = Vector2.new(640, 560)", 1, true)
					~= nil
			).toBe(true)
		end
	)

	it("the board's rows keep the theme text floor under the modal scale", function()
		local scale = Responsive.scale(phone.x, phone.y) * ModalFit.minScale(tokens)
		expect(tokens.text.small * scale + 0.001 >= tokens.metrics.minTextSize).toBe(true)
	end)

	it("the objective line: name and value have layout orders, so the value sits after the name", function()
		local row = codeOf(QUESTS .. "Row.luau")
		local i = string.find(row, "Name = label({", 1, true)
		expect(i ~= nil).toBe(true)
		local nameLine = string.sub(row, i, string.find(row, "\n", i, true))
		expect(string.find(nameLine, "layoutOrder = 1", 1, true) ~= nil).toBe(true)
		local j = string.find(row, "Value = label({", 1, true)
		expect(j ~= nil).toBe(true)
		expect(string.find(string.sub(row, j, j + 40), "layoutOrder = 2", 1, true) ~= nil).toBe(true)
	end)

	it("the reward chip is auto-sized and never wrapped", function()
		expect(has(QUESTS .. "Row.luau", "TextWrapped = props.wrapped ~= false")).toBe(true)
		local row = codeOf(QUESTS .. "Row.luau")
		local i = string.find(row, "local function Chip", 1, true)
		expect(i ~= nil).toBe(true)
		local chip = string.sub(row, i, i + 1200)
		expect(string.find(chip, "wrapped = false", 1, true) ~= nil).toBe(true)
		expect(string.find(chip, "automaticSize = Enum.AutomaticSize.XY", 1, true) ~= nil).toBe(true)
	end)

	it("the pill's width cap is a share of the viewport with a floor", function()
		expect(Pill.maxWidth(phone.x)).toBe(400)
		expect(Pill.maxWidth(1280)).toBe(768)
		expect(Pill.maxWidth(0)).toBe(Pill.MIN_WIDTH) -- the camera before its first layout
		expect(Pill.maxWidth(nil)).toBe(Pill.MIN_WIDTH)
		expect(Pill.maxWidth(1)).toBe(Pill.MIN_WIDTH)
		expect(Pill.maxWidth(0 / 0)).toBe(Pill.MIN_WIDTH)
		expect(Pill.MIN_WIDTH >= 120).toBe(true)
		expect(Pill.MIN_WIDTH <= phone.x * Pill.MAX_WIDTH_SHARE).toBe(true) -- the floor fits the smallest phone
	end)

	it("the pill follows the camera and never takes input", function()
		local pill = codeOf(GOALS .. "Pill.luau")
		expect(string.find(pill, 'GetPropertyChangedSignal("ViewportSize")', 1, true) ~= nil).toBe(true)
		expect(string.find(pill, "MinSize = Vector2.new(Pill.MIN_WIDTH, 0)", 1, true) ~= nil).toBe(true)
		expect(
			string.find(pill, "MaxSize = Vector2.new(Pill.maxWidth(viewportX), math.huge)", 1, true) ~= nil
		).toBe(true)
		local props = Pill.labelProps("Visit the tower")
		expect(props.Active).toBe(false)
		expect(props.Selectable).toBe(false)
		expect(tokens.text.small * Responsive.scale(phone.x, phone.y) >= tokens.metrics.minTextSize).toBe(
			true
		)
	end)

	it("the tracker and the toasts: tracker is not selectable, the toast host is theme-only", function()
		expect(has(QUESTS .. "Tracker.luau", "Selectable = false")).toBe(true)
		expect(has(QUESTS .. "Toasts.luau", "UI.ToastHost")).toBe(true)
	end)
end)
