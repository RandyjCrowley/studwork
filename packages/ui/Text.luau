--!strict
--[[
	UI.text / UI.useText (module-api.md §23.9): a string by key in the local player's language.

	  Text.text(key, args?) -> string      the framework's client resolver (StudWork.text: translator,
	                                       GameConfig.strings, English default); before StudWork.start,
	                                       the UI kit's own English default. Never empty.
	  Text.useText(key, args?) -> string   the same, as a React hook (re-renders on a locale change)

	Registers the `ui.*` defaults (UI/Strings.luau) with the framework's resolver at require time.

	FOUNDATION STUB: both resolve; `useText` doesn't yet subscribe to locale changes. The localization
	builder (B3) wires the re-render and the framework client's locale atom.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Framework = ReplicatedStorage:WaitForChild("Framework")
local FrameworkStrings = require(Framework:WaitForChild("Strings")) :: any
local UIStrings = require(script.Parent.Strings)

FrameworkStrings.registerDefaults(UIStrings.DEFAULTS)

local Text = {}

function Text.text(key: string, args: { [any]: any }?): string
	local ok, facade = pcall(function(): any
		return (require :: any)(Framework)
	end)
	if ok and type(facade) == "table" then
		local resolved, text = pcall(function(): string
			return facade.text(key, args)
		end)
		if resolved and type(text) == "string" and text ~= "" then
			return text
		end
	end
	local template = UIStrings.DEFAULTS[key] or key
	local formatted = FrameworkStrings.format(template, args)
	return formatted
end

function Text.useText(key: string, args: { [any]: any }?): string
	return Text.text(key, args) -- STUB (B3): subscribe to the locale atom
end

return Text
