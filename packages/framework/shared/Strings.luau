--!strict
--[[
	Strings (module-api.md §23.9, docs/framework/kits/localization.md): the pure resolver and
	formatter, both sides. Keys are `<namespace>.<name>`; every key has an English default.

	  Strings.FRAMEWORK                      the `framework.*` English defaults
	  Strings.registerDefaults(defaults)     another package's English defaults (the UI kit's `ui.*`)
	  Strings.isKey(key) -> boolean          `^[%a][%w_]*%.[%w_.]+$`, at most 100 characters
	  Strings.format(template, args?) -> (string, { string })   `{name}` / `{1}`; the second value
	                                         lists placeholders that had no argument (left as written)
	  Strings.check(strings, ownerName, errors)   definition check for a module's `strings` table
	  Strings.new(opts) -> resolver
	    opts = { defaults = { [key] = text }, overrides = GameConfig.strings?,
	             translate = (key, args?) -> string?  (the player's translator; nil = none), warn? }
	    resolver.english(key, args?) -> string     override > default > the key itself (one warning)
	    resolver.text(key, args?) -> string        translator first, then english. Never empty.
]]

local Strings = {}

Strings.MAX_KEY = 100

-- Defaults another package registers at require time (the UI kit's `ui.*` table, so the client's
-- text resolver knows them without the framework naming the package). Module-level on purpose.
local registered: { [string]: string } = {}

function Strings.registerDefaults(defaults: { [string]: string })
	for key, text in defaults do
		registered[key] = text
	end
end

-- The framework's own player-facing text. B3 (localization) moves the kick lines here.
Strings.FRAMEWORK = table.freeze({
	["framework.kick.saveFailed"] = "Your save couldn't be loaded safely, so nothing was changed. Please rejoin in a moment.",
	["framework.kick.sessionEnded"] = "Your save data was opened in another server. Please rejoin.",
	["framework.kick.legacyImport"] = "We couldn't bring over your save from the previous version yet. Nothing was lost. Please rejoin in a minute.",
})

function Strings.isKey(key: any): boolean
	return type(key) == "string"
		and #key <= Strings.MAX_KEY
		and string.match(key, "^[%a][%w_]*%.[%w_.]+$") ~= nil
end

function Strings.format(template: string, args: { [any]: any }?): (string, { string })
	local missing: { string } = {}
	local out = string.gsub(
		template,
		"{([%w_]+)}",
		(
				function(name: string): string?
					local value = nil
					if args ~= nil then
						value = args[name]
						if value == nil then
							value = args[tonumber(name) :: any]
						end
					end
					if value == nil then
						table.insert(missing, name)
						return nil -- keeps the placeholder as written
					end
					return tostring(value)
				end
			) :: any
	)
	return out, missing
end

-- A module definition's `strings`: keys start with `<Name>.`, values are non-empty strings.
function Strings.check(strings: any, ownerName: string, errors: { string })
	if type(strings) ~= "table" then
		table.insert(errors, "strings must be a table of key = English text, or a function(config) -> table")
		return
	end
	for key, text in strings do
		if type(key) ~= "string" or string.sub(key, 1, #ownerName + 1) ~= ownerName .. "." then
			table.insert(errors, `strings.{tostring(key)}: keys must start with '{ownerName}.'`)
		elseif not Strings.isKey(key) then
			table.insert(
				errors,
				`strings.{key}: not a valid string key (<namespace>.<name>, at most {Strings.MAX_KEY} characters)`
			)
		end
		if type(text) ~= "string" or text == "" then
			table.insert(errors, `strings.{tostring(key)} must be a non-empty string`)
		end
	end
end

function Strings.new(opts: any): any
	local defaults: { [string]: string } = opts.defaults or {}
	local overrides: { [string]: string } = opts.overrides or {}
	local translate: ((string, any) -> string?)? = opts.translate
	local warn: (string) -> () = opts.warn or function(_m: string) end
	local warned: { [string]: boolean } = {}
	local function warnOnce(id: string, message: string)
		if not warned[id] then
			warned[id] = true
			warn(message)
		end
	end

	local r: any = {}

	function r.english(key: string, args: { [any]: any }?): string
		local template = overrides[key]
		if type(template) ~= "string" or template == "" then
			template = defaults[key]
		end
		if type(template) ~= "string" or template == "" then
			template = registered[key]
		end
		if type(template) ~= "string" or template == "" then
			warnOnce(
				"key:" .. tostring(key),
				`[StudWork] string key '{tostring(key)}' has no English default`
			)
			return tostring(key)
		end
		local text, missing = Strings.format(template, args)
		if #missing > 0 then
			warnOnce("args:" .. key, `[StudWork] string '{key}': no value for {table.concat(missing, ", ")}`)
		end
		return text
	end

	function r.text(key: string, args: { [any]: any }?): string
		if translate ~= nil then
			local ok, translated = pcall(translate, key, args)
			if ok and type(translated) == "string" and translated ~= "" then
				return translated
			end
		end
		return r.english(key, args)
	end

	function r.has(key: string): boolean
		return type(overrides[key]) == "string"
			or type(defaults[key]) == "string"
			or type(registered[key]) == "string"
	end

	return r
end

return table.freeze(Strings)
