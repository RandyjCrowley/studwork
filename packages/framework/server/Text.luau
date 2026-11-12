--!strict
--[[
	`ctx.text` (module-api.md §23.9): strings on the server, in the player's language.

	  Text.new(opts) -> { api = TextAPI, forget(player), fetch(player) }
	    opts = { defaults = { [key] = text } (framework + every module's), overrides = GameConfig.strings?,
	             localization = GameConfig.localization?, translatorFor = (player) -> translator? (yields),
	             spawn, log }
	  api.format(player, key, args?) -> string   the player's translator (FormatByKey in pcall), then
	                                             GameConfig.strings, then the English default, then the key
	  api.english(key, args?) -> string          the English text (logs, analytics)

	FIRST CUT (foundation): resolution and formatting are real (shared/Strings.luau). The translator
	is fetched by `fetch(player)` (the runtime spawns it at join) and cached; the retry schedule
	(5, 30, 120 s) and the locale-change handling are the localization builder's (B3).
]]

local Shared = require(script.Parent.Shared)
local requireShared = require :: any -- see Shared.luau
local Strings = requireShared(Shared.Strings)

local Text = {}

function Text.new(opts: any): any
	local loc = if type(opts.localization) == "table" then opts.localization else {}
	local useTranslators = loc.useTranslators ~= false
	local translators: { [any]: any } = {}
	local english = Strings.new({ defaults = opts.defaults, overrides = opts.overrides, warn = opts.log })
	local self: any = {}

	function self.fetch(player: any)
		if not useTranslators or opts.translatorFor == nil then
			return
		end
		local ok, translator = pcall(opts.translatorFor, player)
		if ok and translator ~= nil then
			translators[player] = translator
		end
	end

	function self.forget(player: any)
		translators[player] = nil
	end

	self.api = table.freeze({
		format = function(player: any, key: string, args: { [any]: any }?): string
			local translator = translators[player]
			if translator ~= nil then
				local ok, text = pcall(function(): any
					return translator:FormatByKey(key, args)
				end)
				if ok and type(text) == "string" and text ~= "" then
					return text
				end
			end
			return english.english(key, args)
		end,
		english = function(key: string, args: { [any]: any }?): string
			return english.english(key, args)
		end,
	}) :: any

	return self
end

return Text
