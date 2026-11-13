-- v1.7.0 client runtime additions (module-api.md §23.1, §23.2, §23.9, §23.10): StudWork.env,
-- StudWork.flags and StudWork.text on the client, from the test options env / placeId / locale /
-- translator / flags and the replicated state.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FrameworkClient = ReplicatedStorage:WaitForChild("FrameworkClient")
local Runtime = require(FrameworkClient:WaitForChild("Runtime"))
local Boot = require(FrameworkClient:WaitForChild("Boot"))
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local function start(config: any, opts: any?): any
	Boot.attach(nil)
	local o = opts or {}
	o.ui = false
	return Runtime.start(config, nil, o)
end

describe("client runtime: version", function()
	it("is 1.8.0, the same as the facade", function()
		expect(Runtime.VERSION).toBe("1.8.0")
		expect(StudWork.VERSION).toBe("1.8.0")
	end)
end)

describe("client runtime: env and flags", function()
	local config = {
		gameId = "t",
		modules = {},
		environments = { test = { placeIds = { 5 } } },
		flags = {
			shop = { default = false, test = true },
			secret = { default = true, serverOnly = true },
		},
	}

	it("resolves the environment and flags with the same resolver as the server", function()
		start(config, { placeId = 5 })
		expect(StudWork.env.name()).toBe("test")
		expect(StudWork.env.placeId()).toBe(5)
		expect(StudWork.flags.isOn("shop")).toBe(true)
		expect(StudWork.flags.source("shop")).toBe("config")
		expect(StudWork.flags.all().secret).toBe(nil)
		expect((pcall(StudWork.flags.isOn, "secret"))).toBe(false)
		start(config, { env = "live" })
		expect(StudWork.env.name()).toBe("live")
		expect(StudWork.flags.isOn("shop")).toBe(false)
	end)

	it("takes the server's values from the replicated state and fires onChanged", function()
		local state = { framework = { flags = {} } }
		local rt = start(config, {
			env = "live",
			state = function()
				return state
			end,
		})
		local seen = {}
		StudWork.flags.onChanged("shop", function(on)
			table.insert(seen, on)
		end)
		state = { framework = { flags = { shop = true, secret = false } } }
		rt.syncFramework()
		expect(StudWork.flags.isOn("shop")).toBe(true)
		expect(StudWork.flags.source("shop")).toBe("override")
		expect(seen[1]).toBe(true)
		expect(StudWork.flags.all().secret).toBe(nil) -- a serverOnly flag is never taken from the wire
	end)

	it("takes the harness `flags` option as the replicated values", function()
		start(config, { env = "live", flags = { shop = true } })
		expect(StudWork.flags.isOn("shop")).toBe(true)
	end)
end)

describe("client runtime: strings", function()
	local fakes = StudWork.test.fakes

	it("resolves a framework key, GameConfig.strings and falls back to the key", function()
		start({ gameId = "t", modules = {}, strings = { ["game.hello"] = "Hello {name}" } })
		expect(StudWork.text("framework.kick.sessionEnded")).toBe(
			"Your save data was opened in another server. Please rejoin."
		)
		expect(StudWork.text("game.hello", { name = "Ada" })).toBe("Hello Ada")
		expect(StudWork.text("game.nothing")).toBe("game.nothing")
	end)

	it("uses the translator for a non-source locale and follows a locale change", function()
		local translator = fakes.translator({ locale = "es", entries = { ["game.hello"] = "Hola {name}" } })
		start(
			{ gameId = "t", modules = {}, strings = { ["game.hello"] = "Hello {name}" } },
			{ translator = translator }
		)
		expect(StudWork.text("game.hello", { name = "Ana" })).toBe("Hola Ana")
		translator.setLocale("en")
		expect(StudWork.text("game.hello", { name = "Ana" })).toBe("Hello Ana") -- the source locale: English
	end)

	it("useTranslators = false keeps English", function()
		local translator = fakes.translator({ locale = "es", entries = { ["game.hello"] = "Hola {name}" } })
		start({
			gameId = "t",
			modules = {},
			strings = { ["game.hello"] = "Hello {name}" },
			localization = { useTranslators = false },
		}, { translator = translator })
		expect(StudWork.text("game.hello", { name = "Ana" })).toBe("Hello Ana")
	end)
end)

describe("client runtime: bad v1.7.0 config fails the boot", function()
	it("reports a testOnly flag that would be on in live", function()
		Boot.attach(nil)
		local ok, err = pcall(Runtime.start, {
			gameId = "t",
			modules = {},
			flags = { dbg = { default = false, live = true, testOnly = true } },
		}, nil, { ui = false })
		expect(ok).toBe(false)
		expect(string.find(tostring(err), "testOnly", 1, true) ~= nil).toBe(true)
	end)
end)
