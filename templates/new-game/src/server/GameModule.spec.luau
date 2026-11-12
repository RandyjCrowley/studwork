--!nocheck
-- How to spec the game's own module against the kit modules, with StudWork.test.harness
-- (docs/framework/testing.md). Pure Lune: no Studio, no Roblox services. Run: tools/test
-- Copy this shape for your own gameplay specs; the harness boots the REAL kit modules.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local GameModule = require(ReplicatedStorage:WaitForChild("GameModule"):WaitForChild("module"))
local ServerConfig = require(script.Parent.ServerConfig)

-- The game's module list = GameConfig.modules + the game's own module (the framework adds it by
-- itself at boot; a spec lists it). Its server part is found like a live game finds it, through
-- default.project.json (ServerScriptService.Modules.<Name>), so no `servers` table is needed.
local function boot(overrides: { [string]: any }?): any
	local modules = {}
	for _, ref in Config.modules do
		-- Plot builds instances in the world, which Lune doesn't have: Boot.spec boots it in the
		-- multi-server sim instead. Every other kit runs here for real.
		if ref.name ~= "Plot" then
			table.insert(modules, ref)
		end
	end
	table.insert(modules, GameModule)
	local options: { [string]: any } = {
		gameId = Config.gameId,
		modules = modules,
		config = Config.config, -- the game's own balance numbers
		items = Config.items,
		products = Config.products,
		events = Config.events,
		compliance = Config.compliance,
		serverConfig = ServerConfig,
		isStudio = true, -- the game's Studio-only console commands are registered
	}
	for key, value in overrides or {} do
		options[key] = value
	end
	return StudWork.test.harness(options)
end

describe("the game module", function()
	it("boots with the kit modules and loads a joining player", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(true)
		h:tick(5) -- advance the fake clock and every timer, 5 seconds
	end)

	it("keeps a player's data across a rejoin", function()
		local h = boot()
		local p = h:addPlayer({ userId = 2 })
		h:rejoin(p, { secondsAway = 3600 }) -- save, leave, return an hour later
		expect(p.loaded).toBe(true)
	end)

	-- @if Inventory|Mail
	it("lists its console commands under its own lower-case name", function()
		local h = boot()
		local help = h:console("help")
		expect(string.find(help, string.lower(GameModule.name) .. " ", 1, true) ~= nil).toBe(true)
	end)
	-- @end

	-- @if Inventory
	it("runs a console command through h:console, as a player in the game", function()
		local h = boot()
		h:addPlayer({ userId = 3 }) -- the command acts on Players:GetPlayers()[1], the harness's players
		-- h:console("<module> <command> args...") returns the command's reply text
		local reply = h:console(string.lower(GameModule.name), "fill")
		expect(string.find(reply, "inventory ", 1, true)).toBe(1)
	end)
	-- @end
end)
