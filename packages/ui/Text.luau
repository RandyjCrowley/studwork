--!strict
--[[
	UI.text / UI.useText (module-api.md §23.9): a string by key in the local player's language.

	  Text.text(key, args?) -> string      the framework's client resolver (StudWork.text: translator,
	                                       GameConfig.strings, English default); before StudWork.start,
	                                       the UI kit's own English default. Never empty.
	  Text.useText(key, args?) -> string   the same, as a React hook: re-renders when the locale changes
	  Text.useLocale() -> number           the hook alone, for a component with several labels (then Text.text)
	  Text.onLocaleChanged(fn) -> () -> () the locale atom the hook subscribes to (a disconnect function)

	Registers the `ui.*` defaults (UI/Strings.luau) with the framework's resolver at require time.
	The locale atom lives in the framework's shared Strings module (the client Text bumps it when the
	translator's LocaleId changes), so the UI kit never reaches into the client runtime.
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
	return UIStrings.english(key, args)
end

function Text.onLocaleChanged(fn: (locale: string) -> ()): () -> ()
	return FrameworkStrings.onLocaleChanged(fn)
end

-- Subscribes the calling component to locale changes (it re-renders on one) and returns a counter
-- that changes with each. A component with several keyed labels calls this once at the top, then
-- `Text.text` anywhere; `useText` is this plus one lookup.
-- (`react` is for specs, which pass a stand-in; a component never does.)
function Text.useLocale(react: any?): number
	local React = react or require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
	local tick, setTick = React.useState(0)
	React.useEffect(function()
		return Text.onLocaleChanged(function()
			setTick(function(n: number): number
				return n + 1
			end)
		end)
	end, {})
	return tick
end

function Text.useText(key: string, args: { [any]: any }?): string
	Text.useLocale()
	return Text.text(key, args)
end

return Text
