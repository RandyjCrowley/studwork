--!strict
--[[
	`ctx.text` (module-api.md §23.9): strings on the server, in the player's language.

	  Text.new(opts) -> { api = TextAPI, forget(player), fetch(player) }
	    opts = { defaults = { [key] = text } (framework + every module's), overrides = GameConfig.strings?,
	             localization = GameConfig.localization?, translatorFor = (player) -> translator? (yields;
	             raises when the fetch failed), delay = (seconds, fn)? (default task.delay), log }
	  api.format(player, key, args?) -> string   the player's translator (FormatByKey in pcall), then
	                                             GameConfig.strings, then the English default, then the key
	  api.english(key, args?) -> string          the English text (logs, analytics)

	`fetch(player)` (the runtime spawns it at join) gets the player's translator and caches it; until it
	arrives, and for a player whose fetch keeps failing, every call is English. A fetch that raises is
	retried at 5, 30 and 120 s (Text.RETRY_SECONDS); one that returns nil means "no translator" and isn't
	retried. When the player's `LocaleId` changes the translator is fetched again. `forget(player)` drops
	the cache and cancels pending retries (the runtime calls it when the player leaves).
]]

local Shared = require(script.Parent.Shared)
local requireShared = require :: any -- see Shared.luau
local Strings = requireShared(Shared.Strings)

local Text = {}

-- seconds before each retry of a failed translator fetch (the first attempt is at once)
Text.RETRY_SECONDS = table.freeze({ 5, 30, 120 })

function Text.new(opts: any): any
	local loc = if type(opts.localization) == "table" then opts.localization else {}
	local useTranslators = loc.useTranslators ~= false
	local translators: { [any]: any } = {}
	-- bumped by every fetch/forget: a retry or a late reply from an older fetch does nothing
	local generation: { [any]: number } = {}
	local localeConnections: { [any]: any } = {}
	local english = Strings.new({ defaults = opts.defaults, overrides = opts.overrides, warn = opts.log })
	local delay: (number, () -> ()) -> () = opts.delay
		or function(seconds: number, fn: () -> ())
			task.delay(seconds, fn)
		end
	local self: any = {}

	local function attempt(player: any, mine: number, n: number)
		local ok, translator = pcall(opts.translatorFor, player)
		if generation[player] ~= mine then
			return
		end
		if ok then
			translators[player] = translator
			return
		end
		local wait = Text.RETRY_SECONDS[n]
		if wait ~= nil then
			delay(wait, function()
				if generation[player] == mine then
					attempt(player, mine, n + 1)
				end
			end)
		elseif opts.log ~= nil then
			opts.log(
				`[StudWork] no translator for a player after {#Text.RETRY_SECONDS + 1} attempts; using English`
			)
		end
	end

	local function watchLocale(player: any)
		if localeConnections[player] ~= nil then
			return
		end
		local ok, signal = pcall(function(): any
			return player:GetPropertyChangedSignal("LocaleId")
		end)
		if ok and signal ~= nil then
			localeConnections[player] = signal:Connect(function()
				translators[player] = nil
				self.fetch(player)
			end)
		end
	end

	function self.fetch(player: any)
		if not useTranslators or opts.translatorFor == nil then
			return
		end
		local mine = (generation[player] or 0) + 1
		generation[player] = mine
		watchLocale(player)
		attempt(player, mine, 1)
	end

	function self.forget(player: any)
		generation[player] = (generation[player] or 0) + 1
		translators[player] = nil
		local connection = localeConnections[player]
		localeConnections[player] = nil
		if connection ~= nil then
			pcall(function()
				connection:Disconnect()
			end)
		end
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
