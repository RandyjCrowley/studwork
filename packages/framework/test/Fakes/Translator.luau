--!strict
--[[
	Fake translator (StudWork.test.fakes.translator, module-api.md §23.9 / §23.10): the player's
	Roblox Translator for harness({ locale = "es", translator = fake }) and the client runtime's
	`translator` option. Never talks to Roblox.

	  local fake = StudWork.test.fakes.translator({ locale = "es", entries = { ["ui.close"] = "Cerrar" } })

	Engine surface: fake.LocaleId; fake:FormatByKey(key, args?) -> string (raises when the locale has no
	entry for the key, like Roblox: the normal "no manual translation" case); fake:GetPropertyChangedSignal("LocaleId").
	Test surface: setLocale(locale) fires the change; setEntries(locale, { [key] = text }); calls; failNext(n).
	`entries` is for the starting locale; setEntries adds or replaces another locale's.
]]

local Signal = (require :: any)(script.Parent.Parent.Parent.shared.Signal)
local Strings = (require :: any)(script.Parent.Parent.Parent.shared.Strings)

local TranslatorFake = {}

function TranslatorFake.new(opts: any?): any
	local o = opts or {}
	local locale: string = if type(o.locale) == "string" then o.locale else "es"
	local tables: { [string]: { [string]: string } } = { [locale] = table.clone(o.entries or {}) }
	local failures = if type(o.failNext) == "number" then o.failNext else 0
	local changed = Signal.new("TranslatorFake.LocaleId")
	local fake: any = { calls = {}, LocaleId = locale }

	function fake.FormatByKey(_self: any, key: string, args: any?): string
		table.insert(fake.calls, { method = "FormatByKey", key = key, args = args })
		if failures > 0 then
			failures -= 1
			error("Translator:FormatByKey failed (injected)", 0)
		end
		local entry = (tables[fake.LocaleId] or {})[key]
		if entry == nil then
			error(`Translator:FormatByKey: no entry for key '{key}' in {fake.LocaleId}`, 0)
		end
		local text = Strings.format(entry, args)
		return text
	end

	function fake.GetPropertyChangedSignal(_self: any, property: string): any
		assert(property == "LocaleId", "TranslatorFake only signals LocaleId")
		return changed
	end

	function fake.setLocale(newLocale: string)
		if fake.LocaleId ~= newLocale then
			fake.LocaleId = newLocale
			changed:Fire()
		end
	end

	function fake.setEntries(forLocale: string, entries: { [string]: string })
		tables[forLocale] = table.clone(entries)
	end

	function fake.failNext(n: number)
		failures += n
	end

	return fake
end

return TranslatorFake
