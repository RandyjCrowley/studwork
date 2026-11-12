--!nocheck
-- tools/lune/GuardStrings: the `strings` lint check (docs/framework/kits/localization.md,
-- module-api.md §23.12). The planted cases of the plan, the edge cases of the scanner, the defaults it
-- reads, and the tree itself staying clean.
local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")
local GuardStrings = require("tools/lune/GuardStrings.luau")

local CTX = {
	path = "packages/ui/Planted.luau",
	defaults = { ["ui.close"] = true, ["Mail.title"] = true },
	namespaces = { Leaderboards = true },
}

local function scan(source: string, path: string?): { string }
	return GuardStrings.scanSource(
		source,
		{ path = path or CTX.path, defaults = CTX.defaults, namespaces = CTX.namespaces }
	)
end

describe("GuardStrings: planted violations", function()
	it("flags literal text in a UI file", function()
		local found = scan('return e("TextLabel", { Text = "Close" })')
		expect(#found).toBe(1)
		expect(found[1]).toBe(
			'packages/ui/Planted.luau:1: [strings] hard-coded UI text "Close" (use UI.text with a key; docs/framework/kits/localization.md)'
		)
	end)

	it("flags a property assignment", function()
		expect(#scan('label.Text = "Your items"')).toBe(1)
		expect(#scan('label.PlaceholderText = "Search"')).toBe(1)
	end)

	it("flags literal button text in a kit client file", function()
		expect(#scan('return e(UI.Button, { text = "Buy" })', "packages/kits/economy/Shop/client/init.luau")).toBe(
			1
		)
	end)

	it("flags a literal passed to a feedback call in framework client code", function()
		local path = "packages/framework/client/Feedback/init.luau"
		expect(#scan('ctx.net.feedback(player, "toast", "Saved!")', path)).toBe(1)
		expect(#scan('Feedback.toast("Saved!")', path)).toBe(1)
		expect(#scan('Feedback.pop("+1", position)', path)).toBe(0)
		expect(#scan('Feedback.pop("Nice!", position)', path)).toBe(1)
	end)

	it("flags a key with no English default", function()
		local found = scan('local t = UI.text("ui.doesNotExist")')
		expect(#found).toBe(1)
		expect(string.find(found[1], "ui.doesNotExist", 1, true) ~= nil).toBe(true)
		expect(#scan('local t = UI.useText("ui.doesNotExist")')).toBe(1)
		expect(#scan('local t = StudWork.text("Mail.nothing")')).toBe(1)
		expect(#scan('local t = UIText.text("ui.doesNotExist")')).toBe(1)
	end)

	it("flags English hiding behind a fallback, a concatenation, a branch or a second prop", function()
		expect(#scan('Text = props.emptyText or "Nothing here yet."')).toBe(1)
		expect(#scan('Text = "Claim " .. name')).toBe(1)
		expect(#scan('Text = if ok then "Yes" else UI.text("ui.close")')).toBe(1)
		expect(#scan('e("Frame", { Name = "Row", Text = "Hello" })')).toBe(1)
	end)

	it("reports the line number and the first 30 characters", function()
		local found = scan('local a = 1\nlocal b = 2\nText = "' .. string.rep("long ", 12) .. '"')
		expect(#found).toBe(1)
		expect(string.find(found[1], ":3: [strings]", 1, true) ~= nil).toBe(true)
		expect(string.find(found[1], string.rep("long ", 6), 1, true) ~= nil).toBe(true)
		expect(string.find(found[1], string.rep("long ", 7), 1, true)).toBeNil()
	end)
end)

describe("GuardStrings: allowed code", function()
	it("passes keyed text, symbols, empty strings, asset ids and format-only strings", function()
		expect(#scan('Text = UI.text("ui.close")')).toBe(0)
		expect(#scan('Text = "%"')).toBe(0)
		expect(#scan('Text = "×"')).toBe(0)
		expect(#scan('Text = "0"')).toBe(0)
		expect(#scan('Text = ""')).toBe(0)
		expect(#scan('Image = "rbxassetid://1"')).toBe(0)
		expect(#scan('Text = string.format("%d", n)')).toBe(0)
		expect(#scan('Text = string.format("%.2f", n)')).toBe(0)
		expect(#scan('Text = "{count}"')).toBe(0)
	end)

	it("passes a class name, a comparison and a key call as the value", function()
		expect(#scan('Text = e("Frame", {})')).toBe(0)
		expect(#scan('Text = Instance.new("TextLabel")')).toBe(0)
		expect(#scan('Text = if kind == "a" then UI.text("ui.close") else ""')).toBe(0)
		expect(#scan('Text = UI.text("ui.close", { name = "Ada" })')).toBe(0)
	end)

	it("passes any key in the namespace of a module whose strings is a function", function()
		expect(#scan('Text = UI.text("Leaderboards.board.coins")')).toBe(0)
		expect(#scan('Text = UI.text("Mail.title")')).toBe(0)
	end)

	it("honours -- guard: allow strings, on the line or the line above", function()
		expect(#scan('-- guard: allow strings (a brand mark, not translated)\nText = "Brand"')).toBe(0)
		expect(#scan('Text = "Brand" -- guard: allow strings (a brand mark)')).toBe(0)
		expect(#scan('-- guard: allow strings (reason)\n\nText = "Brand"')).toBe(1)
	end)

	it("ignores comments, block comments and a longer property name", function()
		expect(#scan('-- Text = "Close"\nText = UI.text("ui.close")')).toBe(0)
		expect(#scan('--[[\nText = "Close"\n]]\nText = UI.text("ui.close")')).toBe(0)
		expect(#scan('ContentText = "Close"')).toBe(0)
		expect(#scan('local isText = Text == "Close"')).toBe(0)
	end)

	it("does not scan specs, default tables or generated files", function()
		expect(GuardStrings.isScanned("packages/ui/Button.spec.luau")).toBe(false)
		expect(GuardStrings.isScanned("packages/ui/Strings.luau")).toBe(false)
		expect(GuardStrings.isScanned("packages/kits/economy/Shop/client/Net.luau")).toBe(false)
		expect(GuardStrings.isScanned("packages/framework/client/Net/Generated.luau")).toBe(false)
		expect(GuardStrings.isScanned("packages/ui/Button.luau")).toBe(true)
		expect(GuardStrings.isScanned("packages/ui/README.md")).toBe(false)
	end)
end)

describe("GuardStrings: the defaults it reads", function()
	it("reads keys from a Strings table and a module's strings field", function()
		local keys = {}
		GuardStrings.collectDefaults(
			'local S = {\n\t["ui.a"] = "A",\n\t["ui.b.c"] = "B {x}",\n\t-- ["ui.c"] = "no"\n}',
			keys
		)
		expect(keys["ui.a"]).toBe(true)
		expect(keys["ui.b.c"]).toBe(true)
		expect(keys["ui.c"]).toBeNil()
	end)

	it("a strings function opens the module's namespace", function()
		local keys, spaces = {}, {}
		GuardStrings.collectDefaults(
			'return defineModule({ name = "Leaderboards", strings = function(config) return {} end })',
			keys,
			spaces
		)
		expect(spaces.Leaderboards).toBe(true)
		local _, other = {}, {}
		GuardStrings.collectDefaults(
			'return defineModule({ name = "Mail", strings = { ["Mail.t"] = "T" } })',
			_,
			other
		)
		expect(other.Mail).toBeNil()
	end)
end)

describe("GuardStrings: the check as a whole", function()
	it("its own planted cases all behave", function()
		expect(GuardStrings.selfTest()).toEqual({})
	end)

	it("the tree is clean: no hard-coded English, every key has a default", function()
		expect(GuardStrings.scanAll(fs)).toEqual({})
	end)

	it("a finding has the shape the guardrails parse", function()
		local found = scan('Text = "Close"')
		local path, line, check = string.match(found[1], "^(.-):(%d+): %[([%w_]+)%] ")
		expect(path).toBe("packages/ui/Planted.luau")
		expect(line).toBe("1")
		expect(check).toBe("strings")
	end)
end)
