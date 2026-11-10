--!nocheck
--[[
	One simulated Roblox server. Boots the REAL core services named in opts.real (default:
	Data, Items, Economy, Inventory, Offline, Friends, Shop, Mail) with the REAL vendored
	ProfileStore 1.0.3 against the World's mock DataStore/MessagingService, and small recorded
	fakes for everything else (Policy, Plot, Upgrades, Rebirth, Analytics, Net, Replication).

	What is real vs modelled (see also README.md in this folder):
	  real      packages/core/server/<Service>/init.luau for every name in opts.real, their
	            private modules (Load, Schema, Transaction, Receipt, OfflineMath, CoPlay, ...),
	            packages/core/shared (Types, Validate, HandlerList), ProfileStore.luau, and
	            packages/core/server/Tx.luau.
	  modelled  Roblox engine services (Players, RunService, DataStoreService, MessagingService,
	            HttpService, MarketplaceService), Context wiring (ctx.signals, ctx.net,
	            ctx.setReplicated, console), and the services not in opts.real.
	The boot order mirrors server/init.luau's contract (init all, then start all) but is NOT
	server/init.luau itself (that needs Blink remotes and Instances).

	API used by specs:
	  server:join(userId, opts?) -> player     PlayerAdded (opts.referredBy, opts.name)
	  server:leave(player)                      PlayerRemoving, then Parent = nil
	  server:spawn(fn, ...) -> handle           run fn in a server thread; handle.done/.result/.error
	  server:purchase(receipt) -> handle        MarketplaceService.ProcessReceipt in a thread
	  server:shutdown(opts?) -> handle          BindToClose (players kicked first by default)
	  server:crash()                            the process dies: no saves, no BindToClose
	  server:remote(name, player, ...)          a client -> server event through ctx.net.handle
	  server.services.<Name>                    the loaded service modules
	  server:data(player)                       Data.get(player)
]]

local Loader = require(script.Parent.Loader)
local Signal = require(script.Parent.Signal)

local Server = {}
Server.__index = Server

local FOUNDATION = { Data = true, Policy = true, Analytics = true, Events = true, Shop = true, Net = true }
local DEFAULT_REAL = { "Items", "Data", "Economy", "Inventory", "Offline", "Friends", "Shop", "Mail" }
local DEFAULT_MODULES = { "Items", "Inventory", "Economy", "Offline", "Friends", "Mail" }
-- Boot order: foundation first (Data before its users), then modules in Modules.MODULE_ORDER.
local BOOT_ORDER = {
	"Policy",
	"Analytics",
	"Data",
	"Events",
	"Shop",
	"Net",
	"Items",
	"Inventory",
	"Rarity",
	"Economy",
	"Upgrades",
	"Rebirth",
	"Offline",
	"Streak",
	"Friends",
	"Mail",
	"Plot",
}

local function recorder(log: { any }, name: string)
	return setmetatable({}, {
		__index = function(_, fnName)
			return function(...)
				table.insert(log, { service = name, fn = fnName, args = table.pack(...) })
				return nil
			end
		end,
	})
end

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
	self.modules = opts.modules or DEFAULT_MODULES
	self.real = {}
	for _, n in opts.real or DEFAULT_REAL do
		self.real[n] = true
	end
	self.warnings = {}
	self.feedback = {} -- { { player, kind, text } }
	self.replicated = {} -- player -> key -> value
	self.calls = {} -- recorded fake-service calls
	self.kicks = {} -- { { userId, message } }
	self.netHandlers = {}
	self.closers = {}
	self.players = {}
	self.isStudio = opts.isStudio == true
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

	local services = {
		Players = Players,
		RunService = RunService,
		HttpService = HttpService,
		MarketplaceService = MarketplaceService,
		DataStoreService = self.world:dataStoreService(self),
		MessagingService = self.world:messagingService(self),
		ReplicatedStorage = Loader.folder({
			Core = "packages/core/shared",
		}),
		ServerStorage = Loader.folder({ ServerPackages = "deps/ServerPackages" }),
		ServerScriptService = Loader.folder({ CoreServer = "packages/core/server" }),
	}

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

	self.globals = {
		game = game,
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
-- Core boot (init all, then start all)
--------------------------------------------------------------------------------

function Server._fakeService(self, name: string): any
	local server = self
	local world = self.world
	if name == "Policy" then
		return {
			paidRandomRestricted = function(player)
				return world.restricted[player.UserId] == true
			end,
			isKnown = function()
				return true
			end,
			init = function() end,
			start = function() end,
		}
	elseif name == "Upgrades" then
		return {
			level = function()
				return 0
			end,
		}
	elseif name == "Rebirth" then
		return {
			multiplier = function()
				return 1
			end,
			addResetStep = function() end,
		}
	elseif name == "Plot" then
		return {
			clearDisplay = function() end,
		}
	end
	return recorder(server.calls, name)
end

function Server._boot(self, opts: any)
	local server = self
	local enabled = {}
	for name in FOUNDATION do
		enabled[name] = true
	end
	for _, name in self.modules do
		enabled[name] = true
	end
	self.enabled = enabled

	local signals = setmetatable({}, {
		__index = function(t, key)
			local s = server:_signal(key)
			rawset(t, key, s)
			return s
		end,
	})
	self.signals = signals

	local services = {}
	self.services = services
	local ctx = {
		config = self.config,
		services = services,
		signals = signals,
		net = {
			handle = function(eventName: string, handler)
				server.netHandlers[eventName] = handler
			end,
			events = {},
			feedback = function(player, kind, text)
				table.insert(server.feedback, { player = player, kind = kind, text = text })
			end,
			handleGame = function() end,
		},
		setReplicated = function(player, key, value)
			server.replicated[player] = server.replicated[player] or {}
			server.replicated[player][key] = value
		end,
		setReplicatedAll = function() end,
		sentReplicated = function()
			return nil
		end,
		console = { register = function() end },
		isStudio = self.isStudio,
		serverConfig = {},
		modules = self.modules,
		isEnabled = function(name: string): boolean
			return enabled[name] == true
		end,
	}
	self.ctx = ctx

	local order = {}
	for _, name in BOOT_ORDER do
		if enabled[name] or name == "Upgrades" or name == "Rebirth" or name == "Plot" then
			table.insert(order, name)
		end
	end
	for _, name in order do
		if self.real[name] and enabled[name] then
			services[name] = self.require("packages/core/server/" .. name)
		else
			services[name] = self:_fakeService(name)
		end
	end
	if opts.beforeStart then
		opts.beforeStart(self)
	end
	-- init must not yield; start may spawn. Both run inside a server thread like Core.start.
	local booted = false
	self.scheduler:spawn(self, function()
		for _, name in order do
			local s = services[name]
			if self.real[name] and enabled[name] and s.init then
				s.init(ctx)
			end
		end
		for _, name in order do
			local s = services[name]
			if self.real[name] and enabled[name] and s.start then
				s.start()
			end
		end
		booted = true
	end)
	self.scheduler:_runDeferred()
	assert(booted, "sim: core boot yielded or errored: " .. table.concat(self.world:errors(), "\n"))
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
	return self.services.Data.isLoaded(player)
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
	local handler = self.netHandlers[eventName]
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
