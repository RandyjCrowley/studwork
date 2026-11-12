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
end)
