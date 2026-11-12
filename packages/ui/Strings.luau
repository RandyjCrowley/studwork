--!strict
--[[
	The UI kit's English defaults (module-api.md §23.9, docs/framework/kits/localization.md): every
	user-visible string in packages/ui comes from `UI.text` with a `ui.*` key listed here. Games
	reword any key in GameConfig.strings; translations come from Roblox's localization tables.

	Parameters use Roblox's format-string syntax: `{name}` (args table) or `{1}` (args array).

	  Strings.DEFAULTS                        { [key] = English }
	  Strings.english(key, args?) -> string   the default, formatted (the key itself when unknown): what
	                                          the pure helpers (Odds.pityLine) use when no resolver is passed

	Kits' client parts reuse these keys where the UI kit shows the text (`ui.mail.*`, `ui.inventory.*`);
	a module's own wording lives in its `strings` field.
]]

local Strings = {}

Strings.DEFAULTS = table.freeze({
	-- shared
	["ui.close"] = "Close",
	["ui.modal.closeGlyph"] = "X",
	["ui.perSecond"] = "+{amount}/s",
	-- Odds (OddsTable, the Odds screen, Odds.pityLine / Odds.luckLine)
	["ui.odds.title"] = "Odds",
	["ui.odds.empty"] = "No odds available.",
	["ui.odds.items"] = "Items",
	["ui.odds.mutations"] = "Mutations: {list}",
	["ui.odds.allOutcomes"] = "All outcomes",
	["ui.odds.restricted"] = "Paid random items are restricted in your region. You can still earn these rewards by playing.",
	["ui.odds.pityEvery"] = "Guaranteed {tier}+ at least every {count} rolls",
	["ui.odds.pityAlways"] = "Guaranteed {tier}+ on every roll",
	["ui.odds.luck"] = "Includes your luck x{luck}",
	-- screens
	["ui.inventory.title"] = "Inventory",
	["ui.inventory.empty"] = "Nothing here yet.",
	["ui.mail.title"] = "Mailbox",
	["ui.mail.empty"] = "Your mailbox is empty.",
	["ui.mail.claim"] = "Claim {item}",
	["ui.mail.button"] = "Mailbox ({count})",
	-- Leaderboard
	["ui.leaderboard.empty"] = "No scores yet",
	["ui.leaderboard.you"] = "You",
	["ui.leaderboard.outsideTop"] = "Top {count}+",
	["ui.leaderboard.rank"] = "#{rank}",
})

-- The same `{name}` / `{1}` formatter as the framework's shared/Strings (the UI kit's pure helpers
-- run where the framework isn't loaded, so this is a copy; specs pin the two together).
local function format(template: string, args: { [any]: any }?): string
	local replace = function(name: string): any
		local value = nil
		if args ~= nil then
			value = args[name]
			if value == nil then
				value = args[tonumber(name) :: any]
			end
		end
		if value == nil then
			return nil -- keeps the placeholder as written
		end
		return tostring(value)
	end
	local out = string.gsub(template, "{([%w_]+)}", replace :: any)
	return out
end

function Strings.english(key: string, args: { [any]: any }?): string
	local template = Strings.DEFAULTS[key]
	if template == nil then
		return key
	end
	return format(template, args)
end

return Strings
