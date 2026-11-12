--!nocheck
--[[
	Localization (module-api.md §23.9, docs/framework/kits/localization.md): the resolver and
	formatter (shared/Strings), the server's ctx.text (server/Text: translators, retries, locale
	changes), the client's StudWork.text (client/Text: the translator proxy, locale atom), the
	harness's fake translator, and the module `strings` definition rules.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Strings = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Strings"))
local Signal = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Signal"))
local ClientText = require(ReplicatedStorage:WaitForChild("FrameworkClient"):WaitForChild("Text"))
local ServerScripts = game:GetService("ServerScriptService")
local ServerText = require(ServerScripts:WaitForChild("Framework"):WaitForChild("Text"))
local fakes = StudWork.test.fakes

local DEFAULTS = {
	["Probe.hello"] = "Hello {name}",
	["Probe.pair"] = "{1} of {2}",
	["Probe.plain"] = "Plain",
}

local function resolver(extra)
	local o = { defaults = DEFAULTS }
	for k, v in extra or {} do
		o[k] = v
	end
	return Strings.new(o)
end

describe("resolution order", function()
	it("translator > GameConfig.strings > the English default > the key", function()
		local r = resolver({
			overrides = { ["Probe.plain"] = "Reworded" },
			translate = function(key)
				if key == "Probe.hello" then
					return "Hola"
				end
				error("no entry", 0)
			end,
		})
		expect(r.text("Probe.hello", { name = "Ana" })).toBe("Hola")
		expect(r.text("Probe.plain")).toBe("Reworded")
		expect(r.text("Probe.pair", { 1, 2 })).toBe("1 of 2")
		expect(r.text("Probe.unknown")).toBe("Probe.unknown")
	end)

	it("falls back to English when the translator errors, answers nil or answers an empty string", function()
		local mode = "error"
		local r = resolver({
			translate = function()
				if mode == "error" then
					error("FormatByKey failed", 0)
				elseif mode == "empty" then
					return ""
				end
				return nil
			end,
		})
		for _, m in { "error", "nil", "empty" } do
			mode = m
			expect(r.text("Probe.plain")).toBe("Plain")
		end
	end)

	it("never returns an empty string, even for an empty override or an empty key", function()
		local r = resolver({ overrides = { ["Probe.plain"] = "" } })
		expect(r.english("Probe.plain")).toBe("Plain")
		expect(r.english("Probe.nothing")).toBe("Probe.nothing")
		expect(#r.text("x.y") > 0).toBe(true)
	end)

	it("warns once per unknown key and once per missing argument", function()
		local warnings = {}
		local r = resolver({
			warn = function(m)
				table.insert(warnings, m)
			end,
		})
		r.text("Probe.unknown")
		r.text("Probe.unknown")
		expect(#warnings).toBe(1)
		expect(r.english("Probe.hello", {})).toBe("Hello {name}")
		r.english("Probe.hello", {})
		expect(#warnings).toBe(2)
	end)

	it("uses defaults another package registered", function()
		Strings.registerDefaults({ ["ui.stringsSpec"] = "Registered {n}" })
		expect(resolver().english("ui.stringsSpec", { n = 3 })).toBe("Registered 3")
		expect(resolver().has("ui.stringsSpec")).toBe(true)
	end)
end)

describe("format parameters", function()
	it("named, numbered, repeated and non-string values", function()
		expect((Strings.format("{a}-{a}", { a = "x" }))).toBe("x-x")
		expect((Strings.format("{1}/{2}", { 3, 4 }))).toBe("3/4")
		expect((Strings.format("n={n}", { n = 2.5 }))).toBe("n=2.5")
		expect((Strings.format("no params"))).toBe("no params")
	end)

	it("lists the placeholders that had no argument and keeps them as written", function()
		local text, missing = Strings.format("{a} {b} {c}", { a = 1 })
		expect(text).toBe("1 {b} {c}")
		expect(#missing).toBe(2)
	end)

	it("only reads {identifier} placeholders", function()
		expect((Strings.format("{ spaced } {}", { spaced = "x" }))).toBe("{ spaced } {}")
		expect((Strings.format("100%{n}", { n = 5 }))).toBe("100%5")
	end)
end)

describe("a module's strings definition", function()
	local function define(strings)
		return StudWork.defineModule({
			name = "Probe",
			version = "1.0.0",
			framework = "^1.7.0",
			strings = strings,
		})
	end

	it("fails the definition for a key outside <Module>., a bad key or an empty value", function()
		expect(pcall(define, { ["Other.hello"] = "x" })).toBe(false)
		expect(pcall(define, { ["Probe"] = "x" })).toBe(false)
		expect(pcall(define, { ["Probe.hello"] = "" })).toBe(false)
		expect(pcall(define, { ["Probe." .. string.rep("a", 120)] = "x" })).toBe(false)
		expect(pcall(define, { ["Probe.ok"] = "fine" })).toBe(true)
	end)

	it("moduleDefaults runs a strings function with the config and checks its result", function()
		local seen
		local out, errors = Strings.moduleDefaults(function(config)
			seen = config
			return { ["Probe.board." .. config.id] = "Board " .. config.id }
		end, { id = "coins" }, "Probe")
		expect(seen.id).toBe("coins")
		expect(#errors).toBe(0)
		expect(out["Probe.board.coins"]).toBe("Board coins")

		local bad, badErrors = Strings.moduleDefaults(function()
			return { ["Elsewhere.x"] = "no" }
		end, {}, "Probe")
		expect(bad).toBeNil()
		expect(#badErrors > 0).toBe(true)

		local raised, raisedErrors = Strings.moduleDefaults(function()
			error("boom")
		end, {}, "Probe")
		expect(raised).toBeNil()
		expect(#raisedErrors).toBe(1)

		local none = Strings.moduleDefaults(nil, {}, "Probe")
		expect(next(none)).toBeNil()
	end)

	it("a strings function's keys resolve through ctx.text, and GameConfig.strings reword them", function()
		local ref = StudWork.defineModule({
			name = "Probe",
			version = "1.0.0",
			framework = "^1.7.0",
			config = { schema = { id = "string" }, defaults = { id = "coins" } },
			strings = function(config)
				return { ["Probe.board." .. config.id] = "Board " .. config.id }
			end,
		})
		local captured
		StudWork.test.harness({
			modules = { ref },
			servers = { Probe = {
				init = function(ctx)
					captured = ctx
				end,
			} },
			strings = { ["Probe.board.coins"] = "Coin board" },
		})
		expect(captured.text.english("Probe.board.coins")).toBe("Coin board")
	end)
end)

describe("the locale atom", function()
	it("notifies subscribers, remembers the last locale and disconnects", function()
		local seen = {}
		local off = Strings.onLocaleChanged(function(locale)
			table.insert(seen, locale)
		end)
		Strings.notifyLocaleChanged("es")
		Strings.notifyLocaleChanged("pt")
		expect(seen).toEqual({ "es", "pt" })
		expect(Strings.currentLocale()).toBe("pt")
		off()
		Strings.notifyLocaleChanged("fr")
		expect(#seen).toBe(2)
	end)

	it("a subscriber that raises doesn't stop the others", function()
		local ok = false
		local a = Strings.onLocaleChanged(function()
			error("listener failed", 0)
		end)
		local b = Strings.onLocaleChanged(function()
			ok = true
		end)
		Strings.notifyLocaleChanged("de")
		a()
		b()
		expect(ok).toBe(true)
	end)
end)

describe("ctx.text (server)", function()
	local function boot(opts)
		local captured
		local ref = StudWork.defineModule({
			name = "Probe",
			version = "1.0.0",
			framework = "^1.7.0",
			strings = { ["Probe.hello"] = "Hello {name}", ["Probe.bye"] = "Bye" },
		})
		local o = {
			modules = { ref },
			servers = { Probe = {
				init = function(ctx)
					captured = ctx
				end,
			} },
		}
		for k, v in opts or {} do
			o[k] = v
		end
		return StudWork.test.harness(o), captured
	end

	it("speaks the player's language from the translator, English where it has no entry", function()
		local translator = fakes.translator({ locale = "es", entries = { ["Probe.hello"] = "Hola {name}" } })
		local h, ctx = boot({ locale = "es", translator = translator })
		local p = h:addPlayer({ userId = 1 })
		expect(ctx.text.format(p, "Probe.hello", { name = "Ana" })).toBe("Hola Ana")
		expect(ctx.text.format(p, "Probe.bye")).toBe("Bye")
		expect(ctx.text.english("Probe.hello", { name = "Ana" })).toBe("Hello Ana")
	end)

	it("follows the translator's locale: another language without the entry is English again", function()
		local translator = fakes.translator({ locale = "es", entries = { ["Probe.bye"] = "Adios" } })
		translator.setEntries("pt", { ["Probe.bye"] = "Tchau" })
		local h, ctx = boot({ locale = "es", translator = translator })
		local p = h:addPlayer({ userId = 1 })
		expect(ctx.text.format(p, "Probe.bye")).toBe("Adios")
		translator.setLocale("pt")
		expect(ctx.text.format(p, "Probe.bye")).toBe("Tchau")
		translator.setLocale("fr")
		expect(ctx.text.format(p, "Probe.bye")).toBe("Bye")
	end)

	it("useTranslators = false: English plus GameConfig.strings only", function()
		local translator = fakes.translator({ locale = "es", entries = { ["Probe.bye"] = "Adios" } })
		local h, ctx = boot({
			locale = "es",
			translator = translator,
			localization = { useTranslators = false },
			strings = { ["Probe.bye"] = "Farewell" },
		})
		local p = h:addPlayer({ userId = 1 })
		expect(ctx.text.format(p, "Probe.bye")).toBe("Farewell")
		expect(#translator.calls).toBe(0)
	end)

	it("a translator that errors is English, never an error and never blank", function()
		local translator = fakes.translator({ locale = "es", entries = { ["Probe.bye"] = "Adios" } })
		local h, ctx = boot({ locale = "es", translator = translator })
		local p = h:addPlayer({ userId = 1 })
		translator.failNext(1)
		expect(ctx.text.format(p, "Probe.bye")).toBe("Bye")
		expect(ctx.text.format(p, "Probe.bye")).toBe("Adios")
	end)

	it("framework.* kick lines have English defaults and can be reworded", function()
		local _, ctx = boot({ strings = { ["framework.kick.sessionEnded"] = "Logged in elsewhere." } })
		expect(ctx.text.english("framework.kick.sessionEnded")).toBe("Logged in elsewhere.")
		expect(ctx.text.english("framework.kick.saveFailed")).toBe(
			"Your save couldn't be loaded safely, so nothing was changed. Please rejoin in a moment."
		)
	end)
end)

describe("server Text: translator fetch", function()
	local function player()
		local signal = Signal.new("PlayerLocale")
		return {
			GetPropertyChangedSignal = function(_self, _name)
				return signal
			end,
			changeLocale = function()
				signal:Fire()
			end,
		}
	end

	local function build(translatorFor, extra)
		local delays = {}
		local logs = {}
		local o = {
			defaults = DEFAULTS,
			translatorFor = translatorFor,
			delay = function(seconds, fn)
				table.insert(delays, { seconds = seconds, fn = fn })
			end,
			log = function(m)
				table.insert(logs, m)
			end,
		}
		for k, v in extra or {} do
			o[k] = v
		end
		return ServerText.new(o), delays, logs
	end

	it("retries a failed fetch at 5, 30 and 120 s, then adopts the translator", function()
		local attempts = 0
		local translator = fakes.translator({ locale = "es", entries = { ["Probe.plain"] = "Llano" } })
		local t, delays = build(function()
			attempts += 1
			if attempts < 4 then
				error("GetTranslatorForPlayerAsync failed", 0)
			end
			return translator
		end)
		local p = player()
		t.fetch(p)
		expect(t.api.format(p, "Probe.plain")).toBe("Plain")
		expect(delays[1].seconds).toBe(5)
		delays[1].fn()
		expect(delays[2].seconds).toBe(30)
		delays[2].fn()
		expect(delays[3].seconds).toBe(120)
		delays[3].fn()
		expect(attempts).toBe(4)
		expect(t.api.format(p, "Probe.plain")).toBe("Llano")
	end)

	it("gives up after the last retry with one log line and stays English", function()
		local t, delays, logs = build(function()
			error("down", 0)
		end)
		local p = player()
		t.fetch(p)
		for i = 1, 3 do
			delays[i].fn()
		end
		expect(#delays).toBe(3)
		expect(#logs).toBe(1)
		expect(t.api.format(p, "Probe.plain")).toBe("Plain")
	end)

	it("a nil translator means none: no retry", function()
		local t, delays = build(function()
			return nil
		end)
		t.fetch(player())
		expect(#delays).toBe(0)
	end)

	it("forget cancels a pending retry and drops the translator", function()
		local attempts = 0
		local t, delays = build(function()
			attempts += 1
			error("down", 0)
		end)
		local p = player()
		t.fetch(p)
		t.forget(p)
		delays[1].fn()
		expect(attempts).toBe(1)
	end)

	it("fetches again when the player's LocaleId changes", function()
		local current = fakes.translator({ locale = "es", entries = { ["Probe.plain"] = "Llano" } })
		local fetches = 0
		local t = build(function()
			fetches += 1
			return current
		end)
		local p = player()
		t.fetch(p)
		expect(fetches).toBe(1)
		current = fakes.translator({ locale = "pt", entries = { ["Probe.plain"] = "Simples" } })
		p.changeLocale()
		expect(fetches).toBe(2)
		expect(t.api.format(p, "Probe.plain")).toBe("Simples")
		t.forget(p)
		p.changeLocale()
		expect(fetches).toBe(2)
	end)

	it("useTranslators = false never asks for a translator", function()
		local asked = 0
		local t = build(function()
			asked += 1
			return nil
		end, { localization = { useTranslators = false } })
		t.fetch(player())
		expect(asked).toBe(0)
	end)
end)

describe("client Text", function()
	local function client(extra)
		local o = { defaults = DEFAULTS, localization = { sourceLocale = "en" } }
		for k, v in extra or {} do
			o[k] = v
		end
		return ClientText.new(o)
	end

	it("translates in another locale, English in the source locale", function()
		local translator = fakes.translator({ locale = "es", entries = { ["Probe.hello"] = "Hola {name}" } })
		local text = client({ translator = translator })
		expect(text.locale()).toBe("es")
		expect(text.text("Probe.hello", { name = "Ana" })).toBe("Hola Ana")
		expect(text.text("Probe.plain")).toBe("Plain")
		translator.setLocale("en")
		expect(text.text("Probe.hello", { name = "Ana" })).toBe("Hello Ana")
	end)

	it("a locale change fires onLocaleChanged and the shared locale atom", function()
		local translator = fakes.translator({ locale = "es", entries = {} })
		local text = client({ translator = translator })
		local seen, atom = {}, {}
		text.onLocaleChanged(function(locale)
			table.insert(seen, locale)
		end)
		local off = Strings.onLocaleChanged(function(locale)
			table.insert(atom, locale)
		end)
		translator.setLocale("pt")
		translator.setLocale("pt")
		translator.setLocale("fr")
		off()
		expect(seen).toEqual({ "pt", "fr" })
		expect(atom).toEqual({ "pt", "fr" })
	end)

	it("without a translator: the option's locale, English text", function()
		local text = client({ locale = "de" })
		expect(text.locale()).toBe("de")
		expect(text.text("Probe.plain")).toBe("Plain")
		expect(client().locale()).toBe("en")
	end)

	it("useTranslators = false ignores the translator", function()
		local translator = fakes.translator({ locale = "es", entries = { ["Probe.plain"] = "Llano" } })
		local text = client({ translator = translator, localization = { useTranslators = false } })
		expect(text.text("Probe.plain")).toBe("Plain")
		expect(#translator.calls).toBe(0)
	end)

	it("GameConfig.strings reword; an error from FormatByKey falls back", function()
		local translator = fakes.translator({ locale = "es", entries = { ["Probe.plain"] = "Llano" } })
		local text = client({ translator = translator, overrides = { ["Probe.bye"] = "Ta-ta" } })
		expect(text.text("Probe.bye")).toBe("Ta-ta")
		translator.failNext(1)
		expect(text.text("Probe.plain")).toBe("Plain")
	end)

	describe("the live translator proxy", function()
		local function proxy(fetch)
			local delays = {}
			local p = ClientText.proxy({
				fetch = fetch,
				localeId = function()
					return "es"
				end,
				delay = function(seconds, fn)
					table.insert(delays, { seconds = seconds, fn = fn })
				end,
				spawn = function(fn)
					fn()
				end,
			})
			return p, delays
		end

		it("is English until the real translator arrives, without blocking boot", function()
			local real = fakes.translator({ locale = "es", entries = { ["Probe.hello"] = "Hola {name}" } })
			local ready = false
			local p = proxy(function()
				ready = true
				return real
			end)
			expect(ready).toBe(false) -- nothing runs until start()
			local text = client({ translator = p })
			expect(ready).toBe(true) -- ClientText.new started it
			expect(text.text("Probe.hello", { name = "Ana" })).toBe("Hola Ana")
		end)

		it("keeps English while the fetch fails, retries at 5, 30 and 120 s, then translates", function()
			local real = fakes.translator({ locale = "es", entries = { ["Probe.plain"] = "Llano" } })
			local attempts = 0
			local p, delays = proxy(function()
				attempts += 1
				if attempts < 4 then
					error("GetTranslatorForPlayerAsync failed", 0)
				end
				return real
			end)
			local text = client({ translator = p })
			expect(text.text("Probe.plain")).toBe("Plain")
			expect(delays[1].seconds).toBe(5)
			delays[1].fn()
			expect(delays[2].seconds).toBe(30)
			delays[2].fn()
			expect(delays[3].seconds).toBe(120)
			expect(text.text("Probe.plain")).toBe("Plain")
			delays[3].fn()
			expect(attempts).toBe(4)
			expect(text.text("Probe.plain")).toBe("Llano")
		end)

		it("signals a locale change when the translator arrives and when its locale changes", function()
			local real = fakes.translator({ locale = "es", entries = { ["Probe.plain"] = "Llano" } })
			real.setEntries("pt", { ["Probe.plain"] = "Simples" })
			local p = proxy(function()
				return real
			end)
			local seen = {}
			local off = Strings.onLocaleChanged(function(locale)
				table.insert(seen, locale)
			end)
			local text = client({ translator = p }) -- starts the fetch, after the listener is in place
			real.setLocale("pt")
			off()
			expect(seen[#seen]).toBe("pt")
			expect(text.text("Probe.plain")).toBe("Simples")
		end)

		it("stops retrying after the last delay and never raises", function()
			local p, delays = proxy(function()
				error("down", 0)
			end)
			client({ translator = p })
			for i = 1, 3 do
				delays[i].fn()
			end
			expect(#delays).toBe(3)
			expect(p.attempts).toBe(4)
		end)

		it("liveTranslator is nil where there's no LocalizationService (specs, servers)", function()
			expect(ClientText.liveTranslator()).toBeNil()
		end)
	end)
end)

describe("the fake translator", function()
	it("raises for a missing entry like Roblox, formats params and fires the change", function()
		local fake = fakes.translator({ locale = "es", entries = { ["a.b"] = "Hola {n}" } })
		expect(fake:FormatByKey("a.b", { n = 2 })).toBe("Hola 2")
		expect(pcall(function()
			return fake:FormatByKey("a.missing")
		end)).toBe(false)
		local fired = 0
		fake:GetPropertyChangedSignal("LocaleId"):Connect(function()
			fired += 1
		end)
		fake.setLocale("pt")
		fake.setLocale("pt")
		expect(fired).toBe(1)
		expect(pcall(function()
			return fake:FormatByKey("a.b")
		end)).toBe(false)
		fake.setEntries("pt", { ["a.b"] = "Ola {n}" })
		expect(fake:FormatByKey("a.b", { n = 1 })).toBe("Ola 1")
	end)
end)
