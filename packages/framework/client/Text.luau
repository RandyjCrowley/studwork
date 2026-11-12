--!strict
--[[
	The client's strings (module-api.md §23.9): `StudWork.text(key, args?)` in the local player's
	language, and the locale it follows.

	  ClientText.new(opts) -> text
	    opts = { defaults = { [key] = text } (framework + every module's), overrides = GameConfig.strings?,
	             localization = GameConfig.localization?, translator = Translator?, locale = string?, log }
	    text.text(key, args?) -> string        translator (FormatByKey in pcall), GameConfig.strings, the
	                                           English default, the key itself (one warning). Never empty.
	    text.locale() -> string                the translator's LocaleId, else opts.locale, else the source locale
	    text.onLocaleChanged(fn(locale)) -> Connection

	The translator is the local player's. Live, `ClientText.liveTranslator()` returns a proxy at once
	(English until the real one arrives, so boot never waits on LocalizationService): it fetches
	`LocalizationService:GetTranslatorForPlayerAsync(LocalPlayer)` in the background, retries at 5, 30
	and 120 s, and signals a LocaleId change when the translator arrives or its locale changes.
	Client specs and Lune pass one (StudWork.test.fakes.translator).

	A locale change bumps the shared locale atom (Strings.notifyLocaleChanged) that `UI.useText`
	subscribes to, so every keyed label re-renders in the new language.
]]

local Boot = require(script.Parent.Boot)

local Shared: any = Boot.shared
local Strings = (require :: any)(Shared:WaitForChild("Strings"))
local Signal = (require :: any)(Shared:WaitForChild("Signal"))

local ClientText = {}

ClientText.DEFAULT_SOURCE_LOCALE = "en"
-- seconds before each retry of a failed translator fetch (the first attempt is at once)
ClientText.RETRY_SECONDS = table.freeze({ 5, 30, 120 })

-- A translator proxy. deps = { fetch = () -> Translator? (yields, may raise), localeId = () -> string?,
-- delay = (seconds, fn), spawn = (fn) }. `start()` begins the background fetch.
function ClientText.proxy(deps: any): any
	local changed = Signal.new("framework.translatorLocale")
	local real: any = nil
	local proxy: any = { LocaleId = deps.localeId() or ClientText.DEFAULT_SOURCE_LOCALE, attempts = 0 }

	function proxy.FormatByKey(_self: any, key: string, args: any?): string
		if real == nil then
			error("translator not ready", 0)
		end
		return real:FormatByKey(key, args)
	end

	function proxy.GetPropertyChangedSignal(_self: any, _property: string): any
		return changed
	end

	local function adopt(translator: any)
		real = translator
		local id = translator.LocaleId
		if type(id) == "string" and id ~= "" then
			proxy.LocaleId = id
		end
		pcall(function()
			translator:GetPropertyChangedSignal("LocaleId"):Connect(function()
				proxy.LocaleId = translator.LocaleId
				changed:Fire()
			end)
		end)
		changed:Fire()
	end

	local function attempt(n: number)
		proxy.attempts += 1
		local ok, translator = pcall(deps.fetch)
		if ok and translator ~= nil then
			adopt(translator)
			return
		end
		local wait = ClientText.RETRY_SECONDS[n]
		if wait ~= nil then
			deps.delay(wait, function()
				attempt(n + 1)
			end)
		end
	end

	function proxy.start()
		if proxy.started then
			return
		end
		proxy.started = true
		deps.spawn(function()
			attempt(1)
		end)
	end

	return proxy
end

-- The live translator proxy of the local player; nil where there is no LocalizationService or local
-- player (Lune, a server).
function ClientText.liveTranslator(): any
	local ok, service, player = pcall(function(): (any, any)
		return game:GetService("LocalizationService"), game:GetService("Players").LocalPlayer
	end)
	if not ok or service == nil or player == nil then
		return nil
	end
	return ClientText.proxy({
		fetch = function(): any
			return service:GetTranslatorForPlayerAsync(player)
		end,
		localeId = function(): string?
			local found, id = pcall(function(): any
				return player.LocaleId
			end)
			return if found and type(id) == "string" and id ~= "" then id else nil
		end,
		delay = function(seconds: number, fn: () -> ())
			task.delay(seconds, fn)
		end,
		spawn = function(fn: () -> ())
			task.spawn(fn)
		end,
	})
end

function ClientText.new(opts: any): any
	local loc = if type(opts.localization) == "table" then opts.localization else {}
	local sourceLocale: string = if type(loc.sourceLocale) == "string"
		then loc.sourceLocale
		else ClientText.DEFAULT_SOURCE_LOCALE
	local useTranslators = loc.useTranslators ~= false
	local translator: any = if useTranslators then opts.translator else nil
	local changed = Signal.new("framework.localeChanged")
	local self: any = {}

	function self.locale(): string
		if translator ~= nil then
			local ok, id = pcall(function(): any
				return translator.LocaleId
			end)
			if ok and type(id) == "string" and id ~= "" then
				return id
			end
		end
		return if type(opts.locale) == "string" then opts.locale else sourceLocale
	end

	local resolver = Strings.new({
		defaults = opts.defaults,
		overrides = opts.overrides,
		warn = opts.log,
		translate = function(key: string, args: any): string?
			if translator == nil or self.locale() == sourceLocale then
				return nil
			end
			return translator:FormatByKey(key, args)
		end,
	})

	function self.text(key: string, args: { [any]: any }?): string
		return resolver.text(key, args)
	end

	function self.onLocaleChanged(fn: (locale: string) -> ()): any
		return changed:Connect(fn)
	end

	if translator ~= nil then
		pcall(function()
			translator:GetPropertyChangedSignal("LocaleId"):Connect(function()
				local locale = self.locale()
				Strings.notifyLocaleChanged(locale)
				changed:Fire(locale)
			end)
		end)
		if type(translator.start) == "function" then
			translator.start()
		end
	end

	return self
end

return ClientText
