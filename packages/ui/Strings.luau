--!strict
--[[
	The UI kit's English defaults (module-api.md §23.9, docs/framework/kits/localization.md): every
	user-visible string in packages/ui comes from `UI.text` with a `ui.*` key listed here. Games
	reword any key in GameConfig.strings; translations come from Roblox's localization tables.

	Parameters use Roblox's format-string syntax: `{name}` (args table) or `{1}` (args array).

	FOUNDATION: the keys the Leaderboard component needs. The localization builder (B3) moves every
	existing component's text here and adds the keys.
]]

local Strings = {}

Strings.DEFAULTS = table.freeze({
	["ui.close"] = "Close",
	["ui.leaderboard.empty"] = "No scores yet",
	["ui.leaderboard.you"] = "You",
	["ui.leaderboard.outsideTop"] = "Top {count}+",
	["ui.leaderboard.rank"] = "#{rank}",
})

return Strings
