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
	-- The Roblox services a listed kit calls, faked (nothing reaches Roblox): Badges BadgeService,
	-- Leaderboards UserService (display names), TextFilter TextService. Notifications needs
	-- `openCloud`, `secrets` and the allow-list in ServerConfig instead (kits/notifications.md, Tests).
	local fakeFor = { Badges = "badgeService", Leaderboards = "userService", TextFilter = "textService" }
	local serviceName = { Badges = "BadgeService", Leaderboards = "UserService", TextFilter = "TextService" }
	local services = {}
	for _, ref in Config.modules do
		-- Plot builds instances in the world, which Lune doesn't have: Boot.spec boots it in the
		-- multi-server sim instead. Every other kit runs here for real.
		if ref.name ~= "Plot" then
			table.insert(modules, ref)
		end
		if fakeFor[ref.name] then
			services[serviceName[ref.name]] = (StudWork.test.fakes :: any)[fakeFor[ref.name]]()
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
		services = services, -- boot({ services = ... }) replaces them (a fake with a script)
		isStudio = true, -- the game's Studio-only console commands are registered
	}
	-- Every other GameConfig key the kits read, forwarded as the game declares it, so a kit's
	-- `flag`, a string table or a store budget added later works here without editing this spec.
	for _, key in
		{
			"theme",
			"analytics",
			"storeBudgets",
			"flags",
			"flagOverride",
			"environments",
			"strings",
			"localization",
		}
	do
		if (Config :: any)[key] ~= nil then
			options[key] = (Config :: any)[key]
		end
	end
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
end)
