--!nocheck
--!nolint DeprecatedApi
-- UI.text / UI.useText (module-api.md §23.9, docs/framework/kits/localization.md): the UI kit's
-- defaults, the hook's re-render on a locale change, and the guarantees the kit keeps for text:
-- every key a component uses has an English default, every component that words text re-renders
-- on a locale change, and nothing turns Roblox's automatic translation off.
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FrameworkStrings = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Strings"))
local Odds = require(script.Parent.Odds)
local UIStrings = require(script.Parent.Strings)
local UIText = require(script.Parent.Text)

-- the .luau files under a folder (not specs), recursively
local function sources(dir: string, into: { [string]: string })
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			sources(path, into)
		elseif string.sub(path, -5) == ".luau" and not string.find(path, ".spec.", 1, true) then
			into[path] = fs.readFile(path)
		end
	end
end

local function uiSources(): { [string]: string }
	local out = {}
	sources("packages/ui", out)
	return out
end

-- literal keys in `UIText.text("...")`, `UI.text("...")`, `useText("...")`, `StudWork.text("...")` calls
local function keysIn(source: string): { string }
	local keys = {}
	for _, name in { "Text%.text", "Text%.useText", "UI%.text", "UI%.useText", "StudWork%.text" } do
		for key in string.gmatch(source, name .. "%s*%(%s*[\"']([^\"']+)[\"']") do
			table.insert(keys, key)
		end
	end
	return keys
end

describe("UI.text", function()
	it("returns the English default, formatted, before StudWork has started", function()
		expect(UIText.text("ui.close")).toBe("Close")
		expect(UIText.text("ui.perSecond", { amount = "1.5K" })).toBe("+1.5K/s")
		expect(UIText.text("ui.mail.button", { count = 3 })).toBe("Mailbox (3)")
		expect(UIText.text("ui.leaderboard.outsideTop", { count = 100 })).toBe("Top 100+")
	end)

	it("never returns an empty string: an unknown key is the key", function()
		expect(UIText.text("ui.nothing.here")).toBe("ui.nothing.here")
	end)

	it("registers its defaults with the framework's resolver", function()
		local r = FrameworkStrings.new({ defaults = {} })
		for key, text in UIStrings.DEFAULTS do
			expect(
				r.english(
					key,
					{ amount = "x", count = 1, item = "x", list = "x", tier = "x", luck = 1, rank = 1 }
				)
			).never.toBe("")
			expect(r.has(key)).toBe(true)
			expect(#text > 0).toBe(true)
		end
	end)

	it("the kit's English formatter gives what the framework's does", function()
		local args =
			{ amount = "2", count = 5, item = "Cat", tier = "Epic", luck = 1.5, list = "a, b", rank = 4 }
		for key, template in UIStrings.DEFAULTS do
			expect(UIStrings.english(key, args)).toBe((FrameworkStrings.format(template, args)))
		end
		expect(UIStrings.english("ui.unknown.key")).toBe("ui.unknown.key")
	end)

	it("every ui.* key has a valid shape", function()
		for key in UIStrings.DEFAULTS do
			expect(FrameworkStrings.isKey(key)).toBe(true)
			expect(string.sub(key, 1, 3)).toBe("ui.")
		end
	end)
end)

describe("UI.useLocale / UI.useText", function()
	-- a stand-in for React's two hooks: state cells and effects that run at once
	local function fakeReact()
		local state = { value = 0 }
		local cleanups = {}
		local react = { renders = 0 }
		function react.useState(initial)
			state.value = if state.set then state.value else initial
			state.set = true
			return state.value,
				function(update)
					state.value = if type(update) == "function" then update(state.value) else update
				end
		end
		function react.useEffect(effect)
			table.insert(cleanups, effect())
		end
		return react, state, cleanups
	end

	it("subscribes on mount, bumps the counter on a locale change and unsubscribes on unmount", function()
		local react, state, cleanups = fakeReact()
		local first = UIText.useLocale(react)
		expect(first).toBe(0)
		FrameworkStrings.notifyLocaleChanged("es")
		expect(state.value).toBe(1)
		FrameworkStrings.notifyLocaleChanged("pt")
		expect(state.value).toBe(2)
		cleanups[1]()
		FrameworkStrings.notifyLocaleChanged("fr")
		expect(state.value).toBe(2)
	end)

	it("onLocaleChanged is the same atom the client Text writes", function()
		local seen = {}
		local off = UIText.onLocaleChanged(function(locale)
			table.insert(seen, locale)
		end)
		FrameworkStrings.notifyLocaleChanged("it")
		off()
		FrameworkStrings.notifyLocaleChanged("nl")
		expect(seen).toEqual({ "it" })
	end)
end)

describe("Odds lines take their wording from keys", function()
	local DETAIL = { pity = { threshold = 50, minTier = "Legendary" }, luckDisclosed = true, luck = 1.5 }

	it("uses the English defaults without a resolver", function()
		expect(Odds.pityLine(DETAIL)).toBe("Guaranteed Legendary+ at least every 50 rolls")
		expect(Odds.luckLine(DETAIL)).toBe("Includes your luck x1.5")
	end)

	it("asks the resolver for ui.odds.* keys with the values as arguments", function()
		local asked = {}
		local function text(key, args)
			table.insert(asked, { key = key, args = args })
			return "<" .. key .. ">"
		end
		expect(Odds.pityLine(DETAIL, text)).toBe("<ui.odds.pityEvery>")
		expect(asked[1].args.tier).toBe("Legendary")
		expect(asked[1].args.count).toBe(50)
		expect(Odds.pityLine({ pity = { threshold = 1, minTier = "Epic" } }, text)).toBe(
			"<ui.odds.pityAlways>"
		)
		expect(Odds.luckLine(DETAIL, text)).toBe("<ui.odds.luck>")
		expect(asked[3].args.luck).toBe("1.5")
	end)
end)

describe("the UI kit's text", function()
	it("every literal key a component uses has an English default", function()
		local missing = {}
		local used = 0
		for path, source in uiSources() do
			for _, key in keysIn(source) do
				used += 1
				if UIStrings.DEFAULTS[key] == nil then
					table.insert(missing, `{path}: {key}`)
				end
			end
		end
		expect(used > 10).toBe(true)
		expect(missing).toEqual({})
	end)

	it("every default is used somewhere (a component, a kit client or the Leaderboard)", function()
		local all = {}
		sources("packages/ui", all)
		sources("packages/kits", all)
		local used = {}
		for path, source in all do
			if string.sub(path, -12) == "Strings.luau" then
				continue -- the default tables themselves don't count as a use
			end
			for _, key in keysIn(source) do
				used[key] = true
			end
			for key in string.gmatch(source, "[\"'](ui%.[%w_%.]+)[\"']") do
				used[key] = true
			end
		end
		local unused = {}
		for key in UIStrings.DEFAULTS do
			-- ui.leaderboard.* belong to UI.Leaderboard (its own spec checks those); ui.close is the
			-- documented key for a game's own close button
			local exempt = string.sub(key, 1, 15) == "ui.leaderboard." or key == "ui.close"
			if not used[key] and not exempt then
				table.insert(unused, key)
			end
		end
		table.sort(unused)
		expect(unused).toEqual({})
	end)

	it("a component that words text re-renders on a locale change", function()
		local without = {}
		for path, source in uiSources() do
			local name = string.match(path, "([^/]+)$")
			local wordsText = string.find(source, "UIText.text(", 1, true) ~= nil
			local subscribes = string.find(source, "UIText.useLocale(", 1, true) ~= nil
				or string.find(source, "UIText.useText(", 1, true) ~= nil
			if wordsText and not subscribes and name ~= "Text.luau" then
				table.insert(without, path)
			end
		end
		expect(without).toEqual({})
	end)

	it("nothing turns off Roblox's automatic translation, except a name label", function()
		local offenders = {}
		for path, source in uiSources() do
			local name = string.match(path, "([^/]+)$")
			if string.find(source, "AutoLocalize%s*=%s*false") and name ~= "Leaderboard.luau" then
				table.insert(offenders, path)
			end
		end
		expect(offenders).toEqual({})
	end)

	it(
		"components keep no hard-coded English in text properties (the lint's cases, in a spec too)",
		function()
			local pattern = { 'Text%s*=%s*"%a', 'title%s*=%s*"%a', 'text%s*=%s*"%a' }
			local found = {}
			for path, source in uiSources() do
				if string.sub(path, -12) ~= "Strings.luau" then
					for _, p in pattern do
						for line in string.gmatch(source, "[^\n]+") do
							local code = string.gsub(line, "%-%-.*$", "")
							if string.find(code, p) and not string.find(code, 'e%("', 1) then
								table.insert(found, `{path}: {line}`)
							end
						end
					end
				end
			end
			expect(found).toEqual({})
		end
	)
end)
