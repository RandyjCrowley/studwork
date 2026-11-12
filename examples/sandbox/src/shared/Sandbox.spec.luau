--!nocheck
--!nolint DeprecatedApi
--[[
	v1.7.0 polish: what the sandbox shows of the new modules, checked in Lune.
	  - flags gate the HUD (HudRules): the Leaderboards button, and a testOnly debug element
	  - the notifications opt-in is reachable in a first session (`sandbox optin`), never on join
	  - the localization table has a real row (English default + es) for each sandbox key
	  - the Leaderboards board the button opens exists
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(script.Parent.Config)
local HudRules = require(script.Parent.HudRules)
local GameModule = require(ReplicatedStorage:WaitForChild("GameModule"):WaitForChild("module"))
local ServerConfig = require("examples/sandbox/src/server/ServerConfig.luau")
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")

-- the flag values as the `flags` console command lists them (the client reads the same ones)
local function flagReader(h)
	return function(name)
		return string.find(h:console("flags"), name .. " = true", 1, true) ~= nil
	end
end

local function boot(overrides)
	local modules = {}
	for _, ref in Config.modules do
		if ref.name ~= "Plot" then -- builds instances in the world: Boot.spec covers it in the sim
			table.insert(modules, ref)
		end
	end
	table.insert(modules, GameModule)
	local options = {
		gameId = Config.gameId,
		modules = modules,
		config = Config.config,
		items = Config.items,
		products = Config.products,
		events = Config.events,
		compliance = Config.compliance,
		flags = Config.flags,
		strings = Config.strings,
		serverConfig = { admins = ServerConfig.admins, openCloud = ServerConfig.openCloud },
		isStudio = true,
	}
	for k, v in overrides or {} do
		options[k] = v
	end
	local h, err = StudWork.test.harness(options)
	assert(h, err)
	return h
end

describe("sandbox HUD: flag-gated elements", function()
	it("shows the Leaderboards button by default and hides the debug label in live", function()
		local live = HudRules.visible(function(name)
			return Config.flags[name].default == true and Config.flags[name].testOnly ~= true
		end)
		expect(live.leaderboards).toBe(true)
		expect(live.debug).toBe(false)
	end)

	it(
		"flags set leaderboardButton false hides the button without a restart, clear brings it back",
		function()
			local h = boot({ env = "studio" })
			local function visible()
				return HudRules.visible(flagReader(h))
			end
			expect(visible().leaderboards).toBe(true)
			h:console("flags set leaderboardButton false")
			expect(visible().leaderboards).toBe(false)
			h:console("flags set leaderboardButton clear")
			expect(visible().leaderboards).toBe(true)
		end
	)

	it("the testOnly debug element is on in Studio and off in live", function()
		local studio = boot({ env = "studio" })
		expect(HudRules.visible(flagReader(studio)).debug).toBe(true)
		local live = boot({ env = "live", isStudio = false })
		expect(HudRules.visible(flagReader(live)).debug).toBe(false)
	end)

	it("the board the button opens is configured", function()
		expect(Config.config.Leaderboards.boards[HudRules.BOARD] ~= nil).toBe(true)
	end)
end)

describe("sandbox notifications opt-in", function()
	it(
		"is reachable in the first session: asked after minSessionSeconds by the loop, never on join",
		function()
			local rules = Config.config.Notifications.optIn
			expect(rules.minSessions).toBe(0) -- the default (1) refuses a first-session player for ever
			local h = boot()
			h:addPlayer({ userId = 1 })
			expect(#h:sent("Notifications", "PromptOptIn")).toBe(0) -- never on join
			h:tick(rules.minSessionSeconds - 1)
			expect(#h:sent("Notifications", "PromptOptIn")).toBe(0) -- too early
			h:tick(rules.minSessionSeconds + 1)
			expect(#h:sent("Notifications", "PromptOptIn")).toBe(1) -- the sandbox's 30 s loop asked
			-- `sandbox optin` never asks twice in a session
			local reply = h:console("sandbox", "optin")
			expect(string.find(reply, "not allowed yet", 1, true) ~= nil).toBe(true)
			expect(#h:sent("Notifications", "PromptOptIn")).toBe(1)
		end
	)

	it("`sandbox optin` asks now when the rules allow it, and says why when they don't", function()
		local early = boot()
		early:addPlayer({ userId = 1 })
		expect(string.find(early:console("sandbox", "optin"), "not allowed yet", 1, true) ~= nil).toBe(true)
		expect(#early:sent("Notifications", "PromptOptIn")).toBe(0)

		local balance = table.clone(Config.config)
		balance.Notifications = table.clone(balance.Notifications)
		balance.Notifications.optIn = { minSessionSeconds = 0, minSessions = 0 }
		local h = boot({ config = balance })
		local p = h:addPlayer({ userId = 2 })
		expect(#h:sent("Notifications", "PromptOptIn")).toBe(0)
		expect(string.find(h:console("sandbox", "optin"), "prompt requested", 1, true) ~= nil).toBe(true)
		expect(#h:sent("Notifications", "PromptOptIn")).toBe(1)
		expect(h:sent("Notifications", "PromptOptIn")[1].player).toBe(p)
	end)
end)

describe("sandbox localization table", function()
	local function rows(path)
		local out = {}
		local header
		for line in string.gmatch(fs.readFile(path), "[^\r\n]+") do
			-- a CSV line with quoted fields: split on commas outside quotes
			local fields, field, quoted = {}, "", false
			for ch in string.gmatch(line, ".") do
				if ch == '"' then
					quoted = not quoted
				elseif ch == "," and not quoted then
					table.insert(fields, field)
					field = ""
				else
					field ..= ch
				end
			end
			table.insert(fields, field)
			if header == nil then
				header = fields
			else
				local row = {}
				for i, name in header do
					row[name] = fields[i]
				end
				table.insert(out, row)
			end
		end
		return out, header
	end

	it("has English and es for a real sandbox key, and every key has an English default", function()
		local table_, header = rows("examples/sandbox/src/shared/Localization/game.csv")
		expect(header[1]).toBe("Key")
		expect(header[5]).toBe("es")
		local byKey = {}
		for _, row in table_ do
			byKey[row.Key] = row
			expect(Config.strings[row.Key]).toBe(row.Source) -- the English default the CSV mirrors
			expect(row.es ~= nil and row.es ~= "").toBe(true)
		end
		expect(byKey["game.leaderboards"].es).toBe("Clasificaciones")
	end)

	it("the template's game.csv has an example row whose key has an English default", function()
		local table_ = rows("templates/new-game/src/shared/Localization/game.csv")
		expect(#table_ >= 1).toBe(true)
		local TemplateConfig = fs.readFile("templates/new-game/src/shared/Config/init.luau")
		for _, row in table_ do
			expect(string.find(TemplateConfig, '["' .. row.Key .. '"]', 1, true) ~= nil).toBe(true)
		end
	end)
end)
