--!nocheck
--!nolint DeprecatedApi
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local layers = require(script.Parent.ModalLayers)
local modal = fs.readFile("packages/ui/Modal.luau")
local panel = fs.readFile("packages/ui/Panel.luau")

-- Under ZIndexBehavior.Sibling, a higher sibling receives the hit before its children.
local function hit(x, y, panelRect)
	if
		x < panelRect.x
		or x > panelRect.x + panelRect.w
		or y < panelRect.y
		or y > panelRect.y + panelRect.h
	then
		return "backdrop"
	end
	local siblings = { { key = "sink", z = layers.sink }, { key = "panel button", z = layers.panel } }
	table.sort(siblings, function(a, b)
		return a.z > b.z
	end)
	return siblings[1].key
end

describe("UI.Modal hit order", function()
	it("panel button wins above the sink, backdrop outside panel", function()
		local rect = { x = 100, y = 100, w = 300, h = 250 }
		expect(layers.panel > layers.sink).toBe(true)
		expect(hit(200, 200, rect)).toBe("panel button")
		expect(hit(20, 20, rect)).toBe("backdrop")
		expect(layers.close > layers.panel).toBe(true)
	end)
	it("Modal and Panel use the tested sibling layers", function()
		expect(modal).toContain("ZIndex = ModalLayers.sink")
		expect(modal).toContain("zIndex = ModalLayers.panel")
		expect(panel).toContain("ZIndex = props.zIndex")
	end)
	-- v1.6.2 Studio finding: the sandbox's ScreenGui was ZIndexBehavior.Global (Instance.new's
	-- default), so the backdrop (ZIndex 50) covered the whole panel and the odds modal was blank.
	it("every example and template ScreenGui that renders UI.Modal is ZIndexBehavior.Sibling", function()
		local checked = 0
		local function walk(dir)
			for _, name in fs.readDir(dir) do
				local path = dir .. "/" .. name
				if fs.isDir(path) then
					walk(path)
				elseif string.match(name, "%.luau$") or string.match(name, "%.luau%.tmpl$") then
					local source = fs.readFile(path)
					if
						string.find(source, "UI.Modal", 1, true)
						and string.find(source, 'Instance.new("ScreenGui")', 1, true)
					then
						checked += 1
						if
							not string.find(source, "ZIndexBehavior = Enum.ZIndexBehavior.Sibling", 1, true)
						then
							error(path .. ": a ScreenGui hosting UI.Modal must set ZIndexBehavior = Sibling")
						end
					end
				end
			end
		end
		walk("examples")
		walk("templates")
		expect(checked >= 7).toBe(true) -- sandbox, the new-game template, ov-a/b/c/d/f
	end)
	it("Modal warns once when its ScreenGui is Global", function()
		expect(modal).toContain("ZIndexBehavior.Global")
		expect(modal).toContain("needs ZIndexBehavior = Sibling")
	end)
	-- v1.6.2 Studio finding: a content ScrollingFrame with AutomaticSize Y and a UISizeConstraint
	-- grew the panel past the screen (the content was laid out above its top edge). The height is
	-- now set from ModalFit.contentHeight.
	it("Modal sets its content height explicitly from ModalFit.contentHeight", function()
		local content = string.match(modal, 'Content = e%("ScrollingFrame", (%b{})')
		expect(content).never.toBeNil()
		expect(string.find(content, "AutomaticSize = Enum.AutomaticSize.Y", 1, true)).toBeNil()
		expect(content).toContain("UDim2.new(1, 0, 0, scrollHeight)")
		expect(modal).toContain("ModalFit.contentHeight(")
		expect(string.find(modal, 'UISizeConstraint", { MaxSize = Vector2.new(math.huge', 1, true)).toBeNil()
	end)
end)
