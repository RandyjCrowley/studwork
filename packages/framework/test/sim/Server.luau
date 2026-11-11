--!nocheck
--[[
	One simulated Roblox server, booted through StudWork.start (core-v1.3.0 step 4b-IIa): the REAL
	framework server runtime (packages/framework/server: Data + Store.profileStore, Net, Shop,
	Policy, Compliance, Replication, ...) with the REAL vendored ProfileStore 1.0.3 against the
	World's mock DataStore/MessagingService, and the REAL kit modules: their defineModule wrappers
	and the unchanged v1.2 services behind the compat bridge (packages/kits/compat/Bridge.luau).

	What is real vs modelled (see also README.md in this folder):
	  real      packages/framework/{shared,server}, packages/kits/*/{shared,server} (every module
	            in the config's `modules`), packages/kits/compat, packages/core/shared (Types,
	            Validate, HandlerList, ConfigValidate), ProfileStore.luau.
	  modelled  Roblox engine services (Players, RunService, DataStoreService, MessagingService,
	            HttpService, MarketplaceService), the framework's engine adapter (a sim Platform:
	            fake Blink events, policy answers from world.restricted, recorded analytics and
	            replication). A module that is not in `modules` is not running (the v1.2 sim
	            booted fakes of Policy/Plot/Upgrades/Rebirth; v1.3 boots exactly what is listed).
	The fixtures stay v1.2-shaped (Fixtures.config): V12Config.fromV12 turns them into a v1.3
	GameConfig + the game's own module (data = the v1.2 game table).

	API used by specs:
	  server:join(userId, opts?) -> player     PlayerAdded (opts.referredBy, opts.name)
	  server:leave(player)                      PlayerRemoving, then Parent = nil
	  server:spawn(fn, ...) -> handle           run fn in a server thread; handle.done/.result/.error
	  server:purchase(receipt) -> handle        MarketplaceService.ProcessReceipt in a thread
	  server:shutdown(opts?) -> handle          BindToClose (players kicked first by default)
	  server:crash()                            the process dies: no saves, no BindToClose
	  server:remote(name, player, ...)          a client -> server framework event: its handler
	                                            (the v1.2 service's), like v1.2's sim (no Net limiter)
	  server.services.<Name>                    the v1.2 services as ctx.services saw them (Data =
	                                            the compat flat Data, Shop = v1.2 Shop over the
	                                            framework Shop)
	  server.signals.<Name>                     the v1.2 signals (with .history)
	  server.runtime                            the framework server runtime
	  server:data(player)                       Data.get(player)
]]

local Loader = require(script.Parent.Loader)

-- Kit of each v1.2 module (packages/kits/<kit>/{shared,server}).
local KIT_OF = {
	Items = "collection",
	Inventory = "collection",
	Rarity = "collection",
	Economy = "economy",
	Upgrades = "economy",
	Rebirth = "economy",
	Offline = "economy",
	Plot = "base",
	Friends = "social",
	Mail = "social",
	Streak = "engagement",
}
local KITS = { "collection", "economy", "base", "social", "engagement" }
local Signal = require(script.Parent.Signal)

local Server = {}
Server.__index = Server

local guidCounter = 0
local function guid(jobId: string): string
	guidCounter += 1
	local n = guidCounter
	local job = tonumber(string.match(jobId, "%d+")) or 0
	return string.format("%08X-%04X-4%03X-8%03X-%012X", n, job % 0x10000, n % 0x1000, job % 0x1000, n)
end

function Server.new(world: any, jobId: string, opts: any)
	local self = setmetatable({}, Server)
	self.world = world
	self.scheduler = world.scheduler
	self.jobId = jobId
	self.name = opts.name or jobId
	self.alive = true
	assert(opts.config, "sim: server needs opts.config")
	self.config = world.deepCopy(opts.config)
	self.modules = opts.modules or self.config.modules
	self.warnings = {}
	self.feedback = {} -- { { player, kind, text } }
	self.replicated = {} -- player -> key -> value
	self.calls = {} -- recorded fake-service calls
	self.kicks = {} -- { { userId, message } }
	self.synced = {} -- player -> last replicated state handed to the transport
	self.closers = {}
	self.players = {}
	self.isStudio = opts.isStudio == true
	self.project = opts.project -- Loader.readProject(...) for a real game boot (Fixtures.gameServer)
	self:_buildEngine()
	self:_boot(opts)
	return self
end

--------------------------------------------------------------------------------
-- Engine fakes
--------------------------------------------------------------------------------

function Server._signal(self, name: string)
	return Signal.new(self.scheduler, self, name)
end

function Server._buildEngine(self)
	local server = self
	local scheduler = self.scheduler

	-- Players
	local Players = {
		Name = "Players",
		PlayerAdded = self:_signal("PlayerAdded"),
		PlayerRemoving = self:_signal("PlayerRemoving"),
	}
	function Players.GetPlayers(_self)
		return table.clone(server.players)
	end
	function Players.GetPlayerByUserId(_self, userId: number)
		for _, p in server.players do
			if p.UserId == userId then
				return p
			end
		end
		return nil
	end
	self.Players = Players

	local Heartbeat = self:_signal("Heartbeat")
	scheduler:addHook(self, function(dt)
		Heartbeat:Fire(dt)
	end)
	local RunService = {
		Heartbeat = Heartbeat,
		IsStudio = function()
			return server.isStudio
		end,
		IsServer = function()
			return true
		end,
	}

	local serde = (getmetatable(getfenv(1)) :: any).__index.require("@lune/serde")
	local HttpService = {
		GenerateGUID = function(_self, wrap: boolean?)
			local g = guid(server.jobId)
			return if wrap then "{" .. g .. "}" else g
		end,
		JSONEncode = function(_self, value)
			return serde.encode("json", value)
		end,
		JSONDecode = function(_self, text)
			return serde.decode("json", text)
		end,
	}

	local MarketplaceService = {
		ProcessReceipt = nil,
		PromptGamePassPurchaseFinished = self:_signal("PromptGamePassPurchaseFinished"),
		UserOwnsGamePassAsync = function(_self, userId: number, passId: number)
			scheduler:wait(0.05)
			local owned = server.world.passes[userId]
			return owned ~= nil and owned[passId] == true
		end,
	}
	self.MarketplaceService = MarketplaceService

	self.RunService = RunService
	local services = {
		Players = Players,
		RunService = RunService,
		CollectionService = {
			GetInstanceAddedSignal = function()
				return self:_signal("CollectionAdded")
			end,
			GetInstanceRemovedSignal = function()
				return self:_signal("CollectionRemoved")
			end,
			GetTagged = function()
				return {}
			end,
		},
		HttpService = HttpService,
		MarketplaceService = MarketplaceService,
		DataStoreService = self.world:dataStoreService(self),
		MessagingService = self.world:messagingService(self),
		Workspace = Loader.folder({}),
		ReplicatedStorage = Loader.folder({
			-- wally packages the kit services require (Plot: Trove)
			Packages = Loader.folder({ Trove = "deps/Packages/_Index/sleitnick_trove@1.8.0/trove" }),
			Core = "packages/core/shared",
			Framework = "packages/framework/shared",
			CompatShared = "packages/kits/compat/shared",
			Kits = Loader.folder({
				Collection = "packages/kits/collection/shared",
				Economy = "packages/kits/economy/shared",
				Base = "packages/kits/base/shared",
				Social = "packages/kits/social/shared",
				Engagement = "packages/kits/engagement/shared",
			}),
		}),
		ServerStorage = Loader.folder({ ServerPackages = "deps/ServerPackages" }),
		ServerScriptService = Loader.folder({
			Compat = "packages/kits/compat",
			Framework = "packages/framework/server",
			Kits = Loader.folder({
				Collection = "packages/kits/collection/server",
				Economy = "packages/kits/economy/server",
				Base = "packages/kits/base/server",
				Social = "packages/kits/social/server",
				Engagement = "packages/kits/engagement/server",
			}),
		}),
	}

	-- Fixtures.gameServer: a real game's Rojo project adds its own children (Game, GameModule,
	-- Modules, ...) next to the framework/kit mapping above (paths outside the game are the same).
	if self.project then
		local function children(node: any): { [string]: any }
			local out: { [string]: any } = {}
			for name, child in node do
				if string.sub(name, 1, 1) ~= "$" and type(child) == "table" then
					if child["$path"] then
						out[name] = Loader.normalize(self.project.dir .. "/" .. child["$path"])
					else
						out[name] = Loader.folder(children(child))
					end
				end
			end
			return out
		end
		for _, serviceName in { "ReplicatedStorage", "ServerScriptService" } do
			local tree = self.project.tree[serviceName]
			if tree then
				local base = services[serviceName]
				local extra = children(tree)
				for name in table.clone(extra) do
					if base:FindFirstChild(name) ~= nil then
						extra[name] = nil -- framework/kit/package mapping: the sim's own (same paths)
					end
				end
				services[serviceName] = Loader.folder(setmetatable(extra, {
					__index = function(_, key)
						return base:FindFirstChild(key)
					end,
				}))
			end
		end
	end

	local game = {
		JobId = self.jobId,
		PlaceId = 1,
		GameId = 1,
		PrivateServerId = "",
		PrivateServerOwnerId = 0,
	}
	function game.GetService(_self, name: string)
		local s = services[name]
		if s == nil then
			error("sim: game:GetService('" .. tostring(name) .. "') is not simulated", 2)
		end
		return s
	end
	function game.BindToClose(_self, fn: () -> ())
		table.insert(server.closers, fn)
	end
	self.game = game

	local taskLib = {
		wait = function(seconds)
			return scheduler:wait(seconds)
		end,
		spawn = function(fn, ...)
			return scheduler:spawn(server, fn, ...)
		end,
		defer = function(fn, ...)
			return scheduler:defer(server, fn, ...)
		end,
		delay = function(seconds, fn, ...)
			return scheduler:delay(server, seconds, fn, ...)
		end,
		cancel = function(thread)
			scheduler:cancel(thread)
		end,
	}
	local osLib = {
		time = function(t)
			if t ~= nil then
				return os.time(t)
			end
			return scheduler:time()
		end,
		clock = function()
			return scheduler.now
		end,
		date = os.date,
		difftime = os.difftime,
	}
	local function simTypeof(value: any): string
		if type(value) == "table" and rawget(value, "__simInstance") then
			return "Instance"
		end
		return typeof(value)
	end
	local Instance = {
		new = function(className: string)
			if className == "DataStoreOptions" then
				return { SetExperimentalFeatures = function() end }
			end
			error("sim: Instance.new('" .. className .. "') is not simulated", 2)
		end,
	}
	local Enum = {
		ProductPurchaseDecision = {
			PurchaseGranted = "PurchaseGranted",
			NotProcessedYet = "NotProcessedYet",
		},
	}
	local function simWarn(...)
		local parts = {}
		for i = 1, select("#", ...) do
			table.insert(parts, tostring((select(i, ...))))
		end
		local text = table.concat(parts, " ")
		table.insert(server.warnings, text)
		if server.world.verbose then
			print("[" .. server.name .. " warn] " .. text)
		end
	end
	local function simPrint(...)
		if server.world.verbose then
			print("[" .. server.name .. "]", ...)
		end
	end

	local simDebug = table.clone(debug)
	simDebug.profilebegin = function() end
	simDebug.profileend = function() end

	-- Roblox's Random, deterministic per server (the kit Rarity service rolls with it)
	local seed = 0
	local SimRandom = {
		new = function(_seed: number?)
			seed += 1
			local state = (seed * 2654435761) % 4294967296
			local function nextUnit(): number
				state = (1103515245 * state + 12345) % 2147483648
				return state / 2147483648
			end
			return {
				NextNumber = function(_self, lo: number?, hi: number?): number
					local u = nextUnit()
					if lo ~= nil and hi ~= nil then
						return lo + (hi - lo) * u
					end
					return u
				end,
				NextInteger = function(_self, lo: number, hi: number): number
					return lo + math.floor(nextUnit() * (hi - lo + 1))
				end,
			}
		end,
	}

	self.globals = {
		game = game,
		Random = SimRandom,
		task = taskLib,
		os = osLib,
		typeof = simTypeof,
		Instance = Instance,
		Enum = Enum,
		warn = simWarn,
		print = simPrint,
		error = error,
		assert = assert,
		type = type,
		tostring = tostring,
		tonumber = tonumber,
		pairs = pairs,
		ipairs = ipairs,
		next = next,
		select = select,
		pcall = pcall,
		xpcall = xpcall,
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		rawget = rawget,
		rawset = rawset,
		rawequal = rawequal,
		rawlen = rawlen,
		unpack = table.unpack,
		table = table,
		string = string,
		math = math,
		coroutine = coroutine,
		debug = simDebug,
		buffer = buffer,
		bit32 = bit32,
		utf8 = utf8,
		newproxy = newproxy,
	}
	self.require = Loader.newRequire(self.globals)
end

--------------------------------------------------------------------------------
-- StudWork boot (the framework server runtime on a sim Platform)
--------------------------------------------------------------------------------

-- A fake framework Blink event: client -> server listeners (On), server -> client recorded.
local function fakeEvent(server: any, name: string): any
	local ev = { name = name, listeners = {} }
	function ev.On(fn)
		table.insert(ev.listeners, fn)
	end
	function ev.Fire(player, ...)
		if name == "Feedback" then
			local msg = ...
			table.insert(server.feedback, { player = player, kind = msg.Kind, text = msg.Text })
		end
		table.insert(server.calls, { service = "Net", fn = name, args = table.pack(player, ...) })
	end
	function ev.FireAll(...)
		table.insert(server.calls, { service = "Net", fn = name .. ":all", args = table.pack(...) })
	end
	return ev
end

-- The engine adapter (packages/framework/server/Platform.luau) on this server's fakes.
function Server._platform(self): any
	local server = self
	local scheduler = self.scheduler
	local Players = self.Players
	local Store = self.require("packages/framework/server/Store.luau")
	local Net = self.require("packages/framework/server/Net")
	local events = {}
	for _, name in Net.CLIENT_EVENTS do
		events[name] = fakeEvent(server, name)
	end
	for _, name in Net.FRAMEWORK_SERVER_EVENTS do
		events[name] = fakeEvent(server, name)
	end
	self.events = events
	local function isPlayer(p: any): boolean
		return type(p) == "table" and rawget(p, "__simInstance") == true and p.Parent == Players
	end
	local game = self.game
	local function analytics(kind: string)
		return function(...)
			table.insert(server.calls, { service = "Analytics", fn = kind, args = table.pack(...) })
		end
	end
	return {
		isStudio = self.isStudio,
		now = function()
			return scheduler:time()
		end,
		clock = function()
			return scheduler.now
		end,
		spawn = function(fn, ...)
			return scheduler:spawn(server, fn, ...)
		end,
		delay = function(seconds, fn)
			return scheduler:delay(server, seconds, fn)
		end,
		wait = function(seconds)
			return scheduler:wait(seconds)
		end,
		guid = function()
			return game:GetService("HttpService"):GenerateGUID(false)
		end,
		isPlayer = isPlayer,
		players = {
			list = function()
				return Players:GetPlayers()
			end,
			byUserId = function(id: number)
				return Players:GetPlayerByUserId(id)
			end,
		},
		kick = function(player: any, msg: string)
			if isPlayer(player) then
				player:Kick(msg)
			end
		end,
		events = events,
		marketplace = {
			setProcessReceipt = function(fn)
				server.MarketplaceService.ProcessReceipt = fn
			end,
			getProcessReceipt = function()
				return true, server.MarketplaceService.ProcessReceipt
			end,
			decision = function(name: string)
				return name
			end,
			ownsPass = function(userId: number, id: number)
				return server.MarketplaceService:UserOwnsGamePassAsync(userId, id)
			end,
			onPassPurchaseFinished = function(fn)
				server.MarketplaceService.PromptGamePassPurchaseFinished:Connect(fn)
			end,
		},
		policyLookup = function(player: any)
			return { ArePaidRandomItemsRestricted = server.world.restricted[player.UserId] == true }
		end,
		analytics = {
			funnel = analytics("funnel"),
			economy = analytics("economy"),
			custom = analytics("custom"),
		},
		makeSync = function(hooks: any)
			return {
				subscribe = function(player, state)
					server.synced[player] = state
				end,
				set = function(player, state)
					server.synced[player] = state
				end,
				remove = function(player)
					server.synced[player] = nil
				end,
				flush = function()
					for player in server.synced do
						hooks.sent(player)
					end
				end,
			}
		end,
		makeStore = function(gameId: string)
			return Store.profileStore({
				gameId = gameId,
				isStudio = server.isStudio,
				serverPackages = game:GetService("ServerStorage"):WaitForChild("ServerPackages"),
				wait = function(seconds)
					return scheduler:wait(seconds)
				end,
				clock = function()
					return scheduler.now
				end,
				spawn = function(fn, ...)
					return scheduler:spawn(server, fn, ...)
				end,
				log = function(msg)
					server.globals.warn(msg)
				end,
				isPlayer = isPlayer,
			})
		end,
		installConsole = function(run)
			server.console = run
		end,
		encode = function(value: any): string
			return game:GetService("HttpService"):JSONEncode(value)
		end,
		bind = function(rt: any)
			Players.PlayerAdded:Connect(function(player)
				rt.playerAdded(player)
			end)
			Players.PlayerRemoving:Connect(function(player)
				rt.playerRemoving(player)
			end)
			server.RunService.Heartbeat:Connect(function(dt)
				rt.tick(dt)
			end)
			game:BindToClose(function()
				rt.shutdown()
			end)
			server.MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, id, purchased)
				rt.passPurchased(player, id, purchased)
			end)
		end,
	}
end

function Server._boot(self, opts: any)
	local server = self
	local StudWork = self.require("packages/framework/shared")
	local V12Config = self.require("packages/kits/compat/shared/V12Config.luau")
	local FrameworkServer = self.require("packages/framework/server")
	local Bridge = self.require("packages/kits/compat/Bridge.luau")

	local gameConfig, gameModule, serverConfig
	local projectModules: any = nil
	if self.project then
		-- a real game (Fixtures.gameServer): its own Config, game module and ServerConfig, required
		-- inside this server through its Rojo project mapping, exactly what StudWork.start gets live
		local RS = self.game:GetService("ReplicatedStorage")
		local SSS = self.game:GetService("ServerScriptService")
		gameConfig = self.require(RS:WaitForChild("Game"):WaitForChild("Config"))
		gameModule = self.require(RS:WaitForChild("GameModule"):WaitForChild("module"))
		local gameServer = SSS:FindFirstChild("Game")
		local serverConfigNode = gameServer and gameServer:FindFirstChild("ServerConfig")
		serverConfig = if serverConfigNode then self.require(serverConfigNode) else {}
		projectModules = SSS:FindFirstChild("Modules")
		self.modules = gameConfig.modules
		self.config = { gameId = gameConfig.gameId, modules = gameConfig.modules }
	else
		local v12 = table.clone(self.config)
		v12.modules = self.modules
		local gameData
		gameConfig, gameData = V12Config.fromV12(v12, function(name: string)
			return self.require(`packages/kits/{KIT_OF[name]}/shared/{name}.luau`)
		end)
		gameModule = StudWork.defineModule({
			name = "SimGame",
			version = "1.0.0",
			framework = "^1.3.0",
			data = { key = gameConfig.gameId, version = gameData.version, default = gameData.defaults },
		})
		serverConfig = opts.serverConfig or {}
	end

	local signals = setmetatable({}, {
		__index = function(t, key)
			local s = server:_signal(key)
			rawset(t, key, s)
			return s
		end,
	})
	self.signals = signals

	local function loadServer(ref: any): any
		-- opts.serverParts[name]: a test's REAL server part for a kit module (Phase 1 adapters)
		local injected = opts.serverParts and opts.serverParts[ref.name]
		if injected ~= nil then
			return injected
		end
		local part = projectModules and projectModules:FindFirstChild(ref.server or ref.name)
		if part then
			return self.require(part)
		end
		for _, kit in KITS do
			local impl = self.require(`packages/kits/{kit}/server/ModuleServers.luau`).loadServer(ref)
			if impl ~= nil then
				return impl
			end
		end
		return nil
	end

	if opts.beforeStart then
		opts.beforeStart(self)
	end
	local booted = false
	self.scheduler:spawn(self, function()
		self.runtime = FrameworkServer.start(gameConfig, serverConfig, {
			platform = self:_platform(),
			loadServer = loadServer,
			gameModule = gameModule,
			isStudio = self.isStudio,
			logSink = function(level: string, msg: string)
				if level == "warn" then
					server.globals.warn(msg)
				else
					server.globals.print(msg)
				end
			end,
			compat = {
				signals = function()
					return signals
				end,
				-- opts.compatAdapters[Kit]: overrides packages/kits/compat/adapters/<Kit>.luau
				adapters = opts.compatAdapters,
			},
		})
		local hasKits = false
		for _ in self.modules do
			hasKits = true
		end
		if hasKits then
			self.services = Bridge.compatServices(self.runtime)
		else
			self.services = {}
		end
		-- world.restricted changes reach this server's Policy (it caches the answer per session)
		table.insert(self.world.restrictedListeners, function(userId: number, value: any)
			local player = self.Players:GetPlayerByUserId(userId)
			if player and self.alive then
				self.runtime.policy.override(player, if value == true then true else nil)
			end
		end)
		booted = true
	end)
	self.scheduler:_runDeferred()
	assert(booted, "sim: StudWork boot yielded or errored: " .. table.concat(self.world:errors(), "\n"))
end

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

function Server.join(self, userId: number, opts: any?)
	assert(self.alive, "sim: server " .. self.name .. " is down")
	local o = opts or {}
	local server = self
	local player = {
		__simInstance = true,
		ClassName = "Player",
		UserId = userId,
		Name = o.name or ("Player" .. userId),
		DisplayName = o.name or ("Player" .. userId),
		Parent = self.Players,
		server = self,
	}
	function player.IsA(_self, className: string)
		return className == "Player" or className == "Instance"
	end
	function player.Kick(p, message: string?)
		table.insert(server.kicks, { userId = p.UserId, message = message })
		server.scheduler:defer(server, function()
			if p.Parent ~= nil then
				server:leave(p)
			end
		end)
	end
	function player.IsFriendsWithAsync(p, otherId: number)
		local world = server.world
		server.scheduler:wait(world.friendLatency)
		if world.friendFailures > 0 then
			world.friendFailures -= 1
			error("sim: IsFriendsWithAsync failed (injected)", 0)
		end
		return world:areFriends(p.UserId, otherId)
	end
	function player.GetJoinData(_p)
		return { ReferredByPlayerId = o.referredBy }
	end
	setmetatable(player, {
		__tostring = function()
			return "SimPlayer(" .. userId .. "@" .. server.name .. ")"
		end,
	})
	table.insert(self.players, player)
	self.Players.PlayerAdded:Fire(player)
	return player
end

function Server.leave(self, player: any)
	if player.Parent == nil then
		return
	end
	-- Roblox fires PlayerRemoving while the player is still parented, then removes it.
	self.Players.PlayerRemoving:Fire(player)
	player.Parent = nil
	local index = table.find(self.players, player)
	if index then
		table.remove(self.players, index)
	end
end

function Server.data(self, player: any)
	return self.services.Data.get(player)
end

function Server.isLoaded(self, player: any): boolean
	return self.runtime.data.isLoaded(player)
end

-- Runs fn(...) in a server thread; the handle fills in when it returns.
function Server.spawn(self, fn: (...any) -> ...any, ...)
	local handle = { done = false, result = nil, error = nil }
	local args = table.pack(...)
	handle.thread = self.scheduler:spawn(self, function()
		local packed = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
		handle.done = true
		if packed[1] then
			handle.result = packed[2]
			handle.results = table.pack(table.unpack(packed, 2, packed.n))
		else
			handle.error = packed[2]
		end
	end)
	return handle
end

-- Roblox calls ProcessReceipt in its own thread and retries NotProcessedYet later.
function Server.purchase(self, receipt: any)
	local callback = self.MarketplaceService.ProcessReceipt
	assert(callback, "sim: ProcessReceipt not set (Shop not started?)")
	return self:spawn(callback, receipt)
end

function Server.remote(self, eventName: string, player: any, ...)
	local handler = self.runtime.net.handlerFor(eventName)
	assert(handler, "sim: no net handler for " .. eventName)
	return self:spawn(handler, player, ...)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Server shutdown: players are kicked (PlayerRemoving), every BindToClose callback runs in its
-- own thread; Roblox allows them 30 s. The handle reports whether every callback returned in
-- time (`completed`) and `elapsed`. After the limit (or completion) the process stops.
function Server.shutdown(self, opts: any?)
	local o = opts or {}
	local limit = o.limit or 30
	local handle = { done = false, completed = false, elapsed = 0, threads = {} }
	if o.kickPlayers ~= false then
		for _, p in table.clone(self.players) do
			self:leave(p)
		end
	end
	local start = self.scheduler.now
	for _, fn in self.closers do
		table.insert(handle.threads, self.scheduler:spawn(self, fn))
	end
	local function allDead()
		for _, thread in handle.threads do
			if coroutine.status(thread) ~= "dead" then
				return false
			end
		end
		return true
	end
	handle.allDead = allDead
	-- Watchdog in the scheduler itself (not a server thread: it must outlive the server).
	local server = self
	local watchdog = {}
	self.scheduler:addHook(watchdog, function()
		if handle.done then
			return
		end
		local elapsed = server.scheduler.now - start
		if allDead() or elapsed >= limit then
			handle.done = true
			handle.completed = allDead()
			handle.elapsed = elapsed
			server:crash()
			server.scheduler:kill(watchdog)
		end
	end)
	return handle
end

function Server.crash(self)
	self.alive = false
	for _, p in self.players do
		p.Parent = nil
	end
	table.clear(self.players)
	self.scheduler:kill(self)
end

return Server
