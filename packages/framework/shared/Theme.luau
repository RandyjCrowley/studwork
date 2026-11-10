--!strict
--[[
	Theme merge (module-api.md §13), minimal: framework defaults -> each enabled module's `theme`
	(in boot order) -> GameConfig.theme. Maps deep-merge. The result is frozen (ctx.theme is
	read-only). HUD slots, presets beyond "framework-default" and the rarity tier list are later
	work (Collection owns theme.rarity).
]]

local Freeze = require(script.Parent.Freeze)

local Theme = {}

Theme.DEFAULT = Freeze.freezeCopy({
	preset = "framework-default",
	colors = {
		panel = "#1B2340",
		accent = "#FF8A3D",
		secondary = "#2EC4B6",
		currency = "#FFD23F",
		text = "#FFFFFF",
	},
	fonts = {
		display = "rbxasset://fonts/families/FredokaOne.json",
		body = "rbxasset://fonts/families/BuilderSans.json",
	},
	metrics = { cornerRadius = 12, padding = 12, outline = 2, minTouch = 44 },
	sounds = {},
})

local function checkColors(colors: any, where: string, errors: { string })
	if type(colors) ~= "table" then
		return
	end
	for name, hex in colors do
		if type(hex) ~= "string" or string.match(hex, "^#%x%x%x%x%x%x$") == nil then
			table.insert(errors, `{where}.colors.{tostring(name)} must be '#RRGGBB'`)
		end
	end
end

function Theme.merge(order: { any }, gameTheme: any, errors: { string }): any
	local merged = Freeze.deepCopy(Theme.DEFAULT)
	for _, ref in order do
		if ref.theme then
			merged = Freeze.deepMerge(merged, ref.theme)
		end
	end
	if gameTheme ~= nil then
		if type(gameTheme) ~= "table" then
			table.insert(errors, "theme must be a table")
		else
			checkColors(gameTheme.colors, "theme", errors)
			merged = Freeze.deepMerge(merged, gameTheme)
		end
	end
	return Freeze.deepFreeze(merged)
end

return Theme
