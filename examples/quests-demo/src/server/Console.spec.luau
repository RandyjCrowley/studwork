--!nocheck
--[[
	The quests demo's Studio-only console commands, through the console's real argument path
	(h:console splits nothing: each word is one argument, exactly as StudWorkConsole:Invoke gets
	them). Outside Studio every one is refused; in Studio each reaches the kit API. The kit's own
	Studio-only commands the demo README lists are registered too.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local GameModule = require(ReplicatedStorage:WaitForChild("GameModule"):WaitForChild("module"))
local ServerConfig = require(script.Parent.ServerConfig)

local function boot(isStudio: boolean): any
	local modules = table.clone(Config.modules)
	table.insert(modules, GameModule)
	return StudWork.test.harness({
		gameId = Config.gameId,
		modules = modules,
		config = Config.config,
		items = Config.items,
		products = Config.products,
		events = Config.events,
		compliance = Config.compliance,
		analytics = Config.analytics,
		strings = Config.strings,
		flags = Config.flags,
		serverConfig = ServerConfig,
		isStudio = isStudio,
	})
end

local COMMANDS = {
	{ "progress", "coinTouched", "3", "1" },
	{ "finishchain", "1" },
	{ "event" },
	{ "grant", "1" },
}

describe("quests-demo console", function()
	it("lists the demo's and the kit's Studio commands", function()
		local h = boot(true)
		local help = h:console("help")
		for _, cmd in
			{
				"questsdemo progress",
				"questsdemo finishchain",
				"questsdemo event",
				"questsdemo grant",
				"quests complete",
				"quests timeshift",
				"goals complete",
				"goals reset",
			}
		do
			expect(cmd .. ":" .. tostring(string.find(help, cmd, 1, true) ~= nil)).toBe(cmd .. ":true")
		end
	end)

	it("refuses every demo command outside Studio", function()
		local h = boot(false)
		h:addPlayer({ userId = 1 })
		for _, c in COMMANDS do
			local reply = h:console("questsdemo", table.unpack(c))
			expect(c[1] .. ":" .. tostring(string.find(reply, "Studio-only", 1, true) ~= nil)).toBe(
				c[1] .. ":true"
			)
		end
	end)

	it("runs every demo command in Studio (each reaches the kit API)", function()
		local h = boot(true)
		h:addPlayer({ userId = 1 })
		for _, c in COMMANDS do
			local reply = h:console("questsdemo", table.unpack(c))
			expect(c[1] .. ":" .. tostring(string.find(reply, "Studio-only", 1, true) == nil)).toBe(
				c[1] .. ":true"
			)
			expect(string.find(reply, "no loaded player", 1, true)).toBe(nil)
		end
		expect(h:warnings()).toEqual({})
	end)

	it("questsdemo event starts demoEvent (the event quest's window)", function()
		local h = boot(true)
		h:addPlayer({ userId = 1 })
		expect(h:console("questsdemo", "event")).toBe("demoEvent: started")
		expect(h:console("questsdemo", "event")).toBe("demoEvent: not started (unknown or already running)")
	end)
end)
