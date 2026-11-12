--!nocheck
local Checker = require("tools/lune/uifit/Checker.luau")
local Responsive = require("packages/ui/Responsive.luau")
local options = {
	covered = { ["fixture"] = {} },
	fixtures = { fixture = {} },
	truncation = {},
	modal = {},
	minTextSize = 11,
	modalScale = 0.8,
	scale = Responsive.scale,
	glyphWidth = 0.65,
	viewports = { { name = "small phone", x = 667, y = 375 } },
}
local function has(problems, rule)
	for _, p in problems do
		if p.rule == rule then
			return true
		end
	end
	return false
end

describe("UI kit fit checker planted violations", function()
	it("detects the released OddsTable notice auto-height pattern", function()
		local source =
			'return e("TextLabel", { Text = props.restrictedText or DEFAULT_RESTRICTED_TEXT, TextWrapped = true, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y })'
		expect(has(Checker.scan("fixture", source, options), "wrap")).toBe(true)
	end)
	it("discovers a newly introduced unregistered text-bearing component", function()
		expect(
			has(Checker.scan("unlisted", 'return e("TextLabel", { Text = "Hello" })', options), "coverage")
		).toBe(true)
	end)
	it("rejects wrapped auto-height labels and buttons", function()
		local label = 'return e("TextLabel", { TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y })'
		local button = 'return e("TextButton", { TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y })'
		expect(has(Checker.scan("fixture", label, options), "wrap")).toBe(true)
		expect(has(Checker.scan("fixture", button, options), "wrap")).toBe(true)
	end)
	it("rejects a fixed-height box too short for wrapped long text", function()
		options.fixtures.fixture = {
			{
				name = "notice",
				text = string.rep("A", 80),
				size = 14,
				width = 100,
				height = 20,
				wrapped = true,
			},
		}
		expect(has(Checker.scan("fixture", "", options), "wrap")).toBe(true)
		options.fixtures.fixture = {}
	end)
	it("rejects text below the real-pixel floor including a modal scale", function()
		options.modal.fixture = true
		options.fixtures.fixture = { { name = "name", text = "Name", size = 9, autoWidth = true } }
		expect(has(Checker.scan("fixture", "", options), "min-size")).toBe(true)
		options.modal.fixture = nil
		options.fixtures.fixture = {}
	end)
	it("rejects a fixed-width single-line label that overflows", function()
		options.fixtures.fixture = { { name = "title", text = string.rep("W", 40), size = 18, width = 80 } }
		expect(has(Checker.scan("fixture", "", options), "single-line")).toBe(true)
		options.fixtures.fixture = {}
	end)
	it("checks wrapped TextButton automatic sizing only in its own properties", function()
		local unrelated =
			'e("TextButton", { TextWrapped = true }); e("TextLabel", { AutomaticSize = Enum.AutomaticSize.Y })'
		expect(has(Checker.scan("fixture", unrelated, options), "wrap")).toBe(false)
		local offending = 'e("TextButton", { TextWrapped = true, AutomaticSize = Enum.AutomaticSize.XY })'
		expect(has(Checker.scan("fixture", offending, options), "wrap")).toBe(true)
	end)
	it("allows documented two-line ellipsis but rejects a box shorter than two lines", function()
		options.truncation.fixture = "Card summary; full name in odds"
		options.fixtures.fixture = {
			{
				name = "name",
				text = string.rep("A", 80),
				size = 16,
				width = 100,
				height = 40,
				wrapped = true,
				truncateLines = 2,
			},
		}
		expect(has(Checker.scan("fixture", "", options), "wrap")).toBe(false)
		options.fixtures.fixture[1].height = 20
		expect(has(Checker.scan("fixture", "", options), "wrap")).toBe(true)
		options.fixtures.fixture = {}
		options.truncation.fixture = nil
	end)
	it("rejects truncation with no documented full-text interaction", function()
		local source = 'return e("TextLabel", { TextTruncate = Enum.TextTruncate.AtEnd })'
		expect(has(Checker.scan("fixture", source, options), "truncation")).toBe(true)
	end)
end)
