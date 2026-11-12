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

	The translator is the local player's (live: LocalizationService:GetTranslatorForPlayerAsync);
	client specs and Lune pass one (StudWork.test.fakes.translator).

	FIRST CUT (foundation): resolution is real (shared/Strings.luau); the live translator fetch (retries
	at 5, 30 and 120 s) is a stub that leaves English in place, and `UI.useText` re-rendering on a
	locale change is wired by the localization builder (B3).
]]

local Boot = require(script.Parent.Boot)

local Shared: any = Boot.shared
local Strings = (require :: any)(Shared:WaitForChild("Strings"))
local Signal = (require :: any)(Shared:WaitForChild("Signal"))

local ClientText = {}

ClientText.DEFAULT_SOURCE_LOCALE = "en"

-- STUB (B3): the local player's translator. Nil = English only.
function ClientText.liveTranslator(): any
	return nil
end

function ClientText.new(opts: any): any
	local loc = if type(opts.localization) == "table" then opts.localization else {}
	local sourceLocale: string = if type(loc.sourceLocale) == "string"
		then loc.sourceLocale
		else ClientText.DEFAULT_SOURCE_LOCALE
	local useTranslators = loc.useTranslators ~= false
	local translator: any = opts.translator
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
			if not useTranslators or translator == nil or self.locale() == sourceLocale then
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
				changed:Fire(self.locale())
			end)
		end)
	end

	return self
end

return ClientText
