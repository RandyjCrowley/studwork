--!nocheck
--[[
	One simulated Roblox server, booted through StudWork.start: the REAL framework server runtime
	(packages/framework/server: Data + Store.profileStore, Net, Shop, Policy, Compliance,
	Replication, ...) with the REAL vendored ProfileStore 1.0.3 against the World's mock
	DataStore/MessagingService, and the REAL kit modules (packages/kits/<kit>/<Module>/, mapped like Rojo).
	Reached by specs as StudWork.test.sim (module-api.md §15) or this folder's Fixtures.

	What is real vs modelled (see also README.md in this folder):
	  real      packages/framework/{shared,server}, packages/kits/*/<Module> (every module
	            in the config's `modules`), ProfileStore.luau.
	  modelled  Roblox engine services (Players, RunService, DataStoreService, MessagingService,
	            HttpService, MarketplaceService), the framework's engine adapter (a sim Platform:
	            fake Blink events, policy answers from world.restricted, recorded analytics and
	            replication). A module that is not in `modules` is not running.
	The fixture config (Fixtures.config) is a v1.3 GameConfig whose `modules` are kit module
	NAMES (resolved to this server's refs), plus `data` = the fixture game's own module data
	(SimGame, data.key = gameId). Config and item namespaces of modules that are not enabled are
	dropped, so one fixture serves every module subset.

	API used by specs:
	  opts.legacy (v1.6.0)                      a StudWork.test.legacyStore, or "world": the legacy
	                                            reader on the World's mock DataStores (read-only)
	  server:join(userId, opts?) -> player     PlayerAdded (opts.referredBy, opts.name)
	  server:leave(player)                      PlayerRemoving, then Parent = nil
	  server:spawn(fn, ...) -> handle           run fn in a server thread; handle.done/.result/.error
	  server:purchase(receipt) -> handle        MarketplaceService.ProcessReceipt in a thread
	  server:shutdown(opts?) -> handle          BindToClose (players kicked first by default)
	  server:crash()                            the process dies: no saves, no BindToClose
	  server:remote(name, player, ...)          a client -> server framework event (its handler)
	  server:use(ref | name) -> api             the module's API on this server (StudWork.use)
	  server:ref(name) -> ModuleRef             this server's ref (e.g. for a PurchaseTx's tx.use)
	  server:section(player, key) -> view       a loaded player's section (frozen read view)
	  server:sections(player) -> { [key]: view } every section of a loaded player + _framework
	  server:update(player, fn(sections, tx))   one framework tx; sections[key] is the working copy
	                                            -> committed (false when not loaded / session lost)
	  server:save(player) -> boolean            Data.saveAsync (yields: call inside server:spawn)
	  server:onProduct(product, fn(tx))         a product handler of the fixture game module (the
	                                            framework PurchaseTx; tx.use(Ref) = purchase ops)
	  server:heard(name) -> signal              every firing since boot, with .history / :count():
	                                            "<Module>.<Signal>" (ctx.signals.new) or
	                                            "framework.<Signal>"; framework.PlayerLoaded is
	                                            recorded as (player, sections at load)
	  server.runtime                            the framework server runtime
	  server.partPaths[name]                    the source folder of each module's server part
	                                            (ServerScriptService.Modules.<Name>; nil = injected
	                                            or none)
]]

local Loader = require(script.Parent.Loader)

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
	-- (v1.6.0) opts.legacy: a StudWork.test.legacyStore(seed) backend, or "world" / true = read the
	-- World's own mock DataStores (read-only)
	self.legacyMode = if opts.legacy == true or opts.legacy == "world" then "world" else nil
	self.legacyStore = if type(opts.legacy) == "table" then opts.legacy else nil
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
	-- every module folder, mapped like Rojo (Loader.moduleChildren: tools/lune/ModuleDiscovery)
	local rsModules = {}
	for name, parts in Loader.moduleChildren.ReplicatedStorage do
		rsModules[name] = Loader.folder(parts)
	end
	local moduleFolders = {
		ReplicatedStorage = Loader.folder(rsModules),
		ServerScriptService = Loader.folder(Loader.moduleChildren.ServerScriptService),
	}
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
			Packages = Loader.folder({
				Trove = Loader.core("deps/Packages/_Index/sleitnick_trove@1.8.0/trove"),
			}),
			Framework = Loader.core("packages/framework/shared"),
			Modules = moduleFolders.ReplicatedStorage,
		}),
		ServerStorage = Loader.folder({ ServerPackages = Loader.core("deps/ServerPackages") }),
		ServerScriptService = Loader.folder({
			Framework = Loader.core("packages/framework/server"),
			Modules = moduleFolders.ServerScriptService,
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
					local own = base:FindFirstChild(name)
					if name == "Modules" and own ~= nil then
						-- the project's own modules (the game module's server part) next to the
						-- sim's module mapping (the generated kit entries map the same paths)
						local projectModules = extra[name]
						extra[name] = Loader.folder(setmetatable({}, {
							__index = function(_, key)
								return projectModules:FindFirstChild(key) or own:FindFirstChild(key)
							end,
						}))
					elseif own ~= nil then
						extra[name] = nil -- framework/package mapping: the sim's own (same paths)
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
			if className == "DataStoreGetOptions" then
				return { UseCache = true } -- (v1.6.0) the legacy reader sets UseCache = false
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
	local Store = self.require(Loader.core("packages/framework/server/Store.luau"))
	local Net = self.require(Loader.core("packages/framework/server/Net"))
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
		-- (v1.6.0) opts.legacy = "world" (or true): the legacy reader on the World's mock
		-- DataStore, read-only (Legacy.readOnly), so an "old server" writing through the World
		-- (world:seed / world:setOrdered, or a server's own DataStoreService) is what it imports
		makeLegacy = if server.legacyMode == "world"
			then function()
				local Legacy = server.require(Loader.core("packages/framework/server/Legacy.luau"))
				return Legacy.readOnly(game:GetService("DataStoreService"), {
					log = function(msg)
						server.globals.warn(msg)
					end,
				})
			end
			else nil,
		-- ctx.data.shared on the World's mock DataStore: one store shared by every sim server
		-- (failure injection: world:failNext / failFor with store "StudWorkShared_<gameId>")
		makeShared = function(gameId: string)
			local SharedStore = server.require(Loader.core("packages/framework/server/SharedStore.luau"))
			return SharedStore.dataStore(game:GetService("DataStoreService"), "StudWorkShared_" .. gameId, {
				isStudio = server.isStudio,
				log = function(msg)
					server.globals.warn(msg)
				end,
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

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = copy(v)
	end
	return out
end

-- The fixture GameConfig (v1.3 shape, module NAMES) -> (GameConfig with refs, game data).
function Server._fixtureConfig(self): (any, any)
	local fixture = self.config
	local enabled: { [string]: boolean } = {}
	local refs = {}
	for _, name in self.modules do
		enabled[name] = true
		local holder = Loader.moduleChildren.ReplicatedStorage[name]
		assert(holder, "sim: unknown module " .. tostring(name))
		table.insert(refs, self.require(holder.module))
	end
	local config = {}
	for owner, c in fixture.config or {} do
		if enabled[owner] then
			config[owner] = copy(c)
		end
	end
	local items = {}
	for i, item in fixture.items or {} do
		local out = copy(item)
		if not enabled.Economy then
			out.economy = nil
		end
		items[i] = out
	end
	local gameConfig = {
		gameId = fixture.gameId,
		modules = refs,
		config = config,
		items = items,
		products = copy(fixture.products),
		events = copy(fixture.events),
		compliance = copy(fixture.compliance),
		analytics = copy(fixture.analytics),
	}
	local data = fixture.data or {}
	return gameConfig, { default = copy(data.default or {}), version = data.version or 1 }, refs
end

function Server._boot(self, opts: any)
	local server = self
	local StudWork = self.require(Loader.core("packages/framework/shared"))
	local FrameworkServer = self.require(Loader.core("packages/framework/server"))

	local gameConfig, gameModule, serverConfig
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
		self.modules = gameConfig.modules
		self.config = { gameId = gameConfig.gameId, modules = gameConfig.modules }
	else
		local gameData, refs
		gameConfig, gameData, refs = self:_fixtureConfig()
		-- the fixture game's own module: its data is the fixture `data`; every kit module is an
		-- optional dependency, so its product handlers (server:onProduct) can tx.use any of them
		gameModule = StudWork.defineModule({
			name = "SimGame",
			version = "1.0.0",
			framework = "^1.3.0",
			optional = refs,
			data = { key = gameConfig.gameId, version = gameData.version, default = gameData.default },
		})
		serverConfig = opts.serverConfig or {}
	end

	self.partPaths = {}
	local function loadServer(ref: any): any
		-- opts.serverParts[name]: a test's own server part for a kit module (a test double)
		local injected = opts.serverParts and opts.serverParts[ref.name]
		if injected ~= nil then
			return injected
		end
		-- the live lookup (framework Loader.defaultLoadServer, module-api.md §19.9) against this
		-- server's ServerScriptService.Modules: the module folders + the project's own modules
		local folder = self.game:GetService("ServerScriptService"):FindFirstChild("Modules")
		local instance = folder and folder:FindFirstChild(ref.server or ref.name)
		self.partPaths[ref.name] = instance and instance.__path
		-- no Blink wire in the sim (a generated Net.luau needs the engine): Net children are not bound
		return self.require(Loader.core("packages/framework/server/Loader.luau"))
			.defaultLoadServer(ref, nil, { bindNet = false })
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
			legacy = self.legacyStore,
			logSink = function(level: string, msg: string)
				if level == "warn" then
					server.globals.warn(msg)
				else
					server.globals.print(msg)
				end
			end,
		})
		self:_listen()
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

-- Records every module signal (api.signals) and framework signal from boot on (server:heard).
function Server._listen(self)
	local server = self
	local rt = self.runtime
	self._heard = {}
	local function sink(name: string): any
		local s = self._heard[name]
		if s == nil then
			s = self:_signal(name)
			self._heard[name] = s
		end
		return s
	end
	for name, signal in rt.frameworkSignals do
		sink("framework." .. name)
		signal:Connect(function(player: any, ...: any)
			if name == "PlayerLoaded" then
				sink("framework.PlayerLoaded"):Fire(player, server:sections(player))
			else
				sink("framework." .. name):Fire(player, ...)
			end
		end)
	end
	for _, ref in rt.order do
		for signalName, signal in rt.moduleSignals(ref) do
			local key = ref.name .. "." .. signalName
			sink(key)
			signal:Connect(function(...: any)
				sink(key):Fire(...)
			end)
		end
	end
end

function Server.heard(self, name: string): any
	local s = self._heard[name]
	assert(s, `sim: no signal '{name}' on this server (use "<Module>.<Signal>" or "framework.<Signal>")`)
	return s
end

local function refOf(self: any, refOrName: any): any
	local name = if type(refOrName) == "table" then refOrName.name else refOrName
	local ref = self.runtime.byName(name)
	assert(ref, "sim: no module " .. tostring(name) .. " on this server")
	return ref
end

-- This server's ModuleRef of a module (refs are per server: each server loads its own copy).
function Server.ref(self, name: string): any
	return refOf(self, name)
end

function Server.use(self, refOrName: any): any
	return self.runtime.use(refOf(self, refOrName))
end

-- Section keys of this server's save: _framework + every enabled module's data.key.
function Server.sectionKeys(self): { string }
	local keys = { "_framework" }
	for _, ref in self.runtime.order do
		if ref.data ~= nil then
			table.insert(keys, ref.data.key)
		end
	end
	return keys
end

function Server.section(self, player: any, key: string): any
	return self.runtime.data.view(player, key)
end

function Server.sections(self, player: any): { [string]: any }
	local out = {}
	for _, key in self:sectionKeys() do
		out[key] = self.runtime.data.view(player, key)
	end
	return out
end

function Server.update(self, player: any, fn: (any, any) -> ()): boolean
	local data = self.runtime.data
	local committed = data.runTx(player, function(tx)
		fn(
			setmetatable({}, {
				__index = function(_, key: string): any
					return data.section(tx, key)
				end,
			}),
			tx
		)
	end)
	return committed == true
end

function Server.save(self, player: any): boolean
	return self.runtime.data.saveAsync(player)
end

function Server.onProduct(self, product: any, fn: (any) -> ())
	local owner = if self.runtime.gameModule then self.runtime.gameModule.name else "SimGame"
	self.runtime.shop.forModule(owner).onProduct(product, fn)
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
	-- the client: once the save is loaded it subscribes (StateInit) and is sent its state, odds
	-- included, before it can buy (v1.3.0). opts.noClient skips it.
	if not o.noClient then
		self.scheduler:spawn(self, function()
			for _ = 1, 600 do
				if player.Parent == nil then
					return
				end
				if server.runtime.data.isLoaded(player) then
					server.runtime.replication.subscribe(player)
					return
				end
				server.scheduler:wait(0.1)
			end
		end)
	end
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
