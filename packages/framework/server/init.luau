--!strict
--[[
	StudWork server runtime: the boot sequence (module-api.md §3) and the running server.

	  local FrameworkServer = require(ServerScriptService.FrameworkServer)
	  FrameworkServer.start(Config, ServerConfig)      -- or StudWork.start(Config, ServerConfig)

	Boot steps:
	  1. resolve        Loader: refs, hard deps listed, names/data keys unique, framework range,
	                    topo order (ties = list order), cycles named; server parts found by name
	  2. validate       ConfigValidate: per-module config (defaults <- config.<Name>, schema),
	                    items (base fields + enabled modules' itemFields), theme; ALL errors at once
	  3. framework init Data, Lifecycle, theme, gameConfig view, wrapped module surfaces, ctx per
	                    module; (the real Shop claims ProcessReceipt last here, H4 — later step)
	  4. init(ctx)      every module, boot order; must not yield; other modules' APIs are blocked
	  5. start(ctx)     every module, boot order; dependency APIs allowed
	  6. framework start players load (Data), ticker runs, (Net releases its queue — later step)
	If any step throws, boot fails closed (N7): Server.start re-raises, and every later call into
	the runtime, any module API, StudWork.use and StudWork.<Name> errors with the boot message.

	opts (all optional; tests inject them, a live server uses the defaults):
	  loadServer(ref) -> impl     find a module's server part (default ServerScriptService.Modules)
	  store                        { load(userId), save(userId, root) } (default: in-memory; the
	                               ProfileStore adapter is the later Data step)
	  now() -> number              unix seconds (default os.time)
	  isStudio: boolean            default RunService:IsStudio()
	  logSink(level, msg)          default print/warn
	  kick(player, msg)            default player:Kick(msg)
	  bindPlatform(rt)             default wires Players / Heartbeat / BindToClose; false = none
	  require                      used for migrations folders (default require)
]]

local Shared = require(script.Shared)
local requireShared = require :: any -- see Shared.luau
local ConfigValidate = requireShared(Shared.ConfigValidate)
local Freeze = requireShared(Shared.Freeze)
local Resolve = requireShared(Shared.Resolve)
local Signal = requireShared(Shared.Signal)
local StudWork = requireShared(Shared)
local Context = require(script.Context)
local Data = require(script.Data)
local Extensions = require(script.Extensions)
local Lifecycle = require(script.Lifecycle)
local Loader = require(script.Loader)

local Server = {}

Server.KICK_MESSAGE =
	"Your save couldn't be loaded safely, so nothing was changed. Please rejoin in a moment."

local function memoryStore()
	local saves: { [any]: any } = {}
	return {
		saves = saves,
		load = function(userId: any): any
			return Freeze.deepCopy(saves[userId])
		end,
		save = function(userId: any, root: any)
			saves[userId] = Freeze.deepCopy(root)
		end,
	}
end
Server.memoryStore = memoryStore

local function defaultBind(rt: any)
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	Players.PlayerAdded:Connect(rt.playerAdded)
	Players.PlayerRemoving:Connect(rt.playerRemoving)
	for _, p in Players:GetPlayers() do
		task.spawn(rt.playerAdded, p)
	end
	RunService.Heartbeat:Connect(rt.tick)
	game:BindToClose(rt.shutdown)
end

local function runNoYield(label: string, fn: any, ...: any)
	local co = coroutine.create(fn)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		error(`{label} failed: {tostring(err)}`, 0)
	end
	if coroutine.status(co) ~= "dead" then
		coroutine.close(co)
		error(`{label} yielded: init(ctx) must not yield (connect events and start loops in start)`, 0)
	end
end

function Server.start(gameConfig: any, serverConfig: any?, opts: any?): any
	local o = opts or {}
	local logSink = o.logSink
		or function(level: string, msg: string)
			if level == "warn" then
				warn(msg)
			else
				print(msg)
			end
		end
	local enabled: { [any]: boolean } = {}
	local byName: { [string]: any } = {}

	local rt: any = {
		state = "booting",
		phase = "resolve",
		bootError = nil,
		configs = {},
		apis = {},
		txApis = {},
		exts = {},
		console = {},
		netLog = {},
		analyticsLog = {},
		replicated = {},
		randomSources = {},
		products = {},
		passHandlers = {},
		frameworkSignals = table.freeze({
			PlayerLoaded = Signal.new("framework.PlayerLoaded"),
			PlayerRemoving = Signal.new("framework.PlayerRemoving"),
		}),
		logSink = logSink,
		serverConfig = serverConfig,
		order = {},
	}

	function rt.assertUsable()
		if rt.state == "failed" then
			error(rt.bootError, 3)
		end
	end
	function rt.isEnabled(ref: any): boolean
		return enabled[ref] == true
	end
	function rt.api(ref: any): any
		return rt.apis[ref]
	end
	function rt.byName(name: any): any
		return byName[name]
	end
	function rt.use(ref: any): any
		rt.assertUsable()
		if enabled[ref] then
			return rt.apis[ref]
		end
		return StudWork._notEnabledProxy(if type(ref) == "table" then tostring(ref.name) else tostring(ref))
	end

	StudWork._attach(rt)

	local impls: { [any]: any } = {}
	local ctxs: { [any]: any } = {}

	local function boot()
		-- 1. resolve
		local order, found = Loader.load(gameConfig, StudWork.VERSION, o.loadServer)
		impls = found
		rt.order = order
		for _, ref in order do
			enabled[ref] = true
			byName[ref.name] = ref
		end

		-- 2. validate config / items / theme (all errors together)
		rt.phase = "config"
		local result = ConfigValidate.validate(order, gameConfig)
		for _, w in result.warnings do
			logSink("warn", "[StudWork] " .. w)
		end
		if #result.errors > 0 then
			error("invalid GameConfig:\n  - " .. table.concat(result.errors, "\n  - "), 0)
		end
		rt.configs = result.configs
		rt.theme = result.theme

		-- 3. framework init
		rt.phase = "framework-init"
		rt.isStudio = if o.isStudio ~= nil then o.isStudio else game:GetService("RunService"):IsStudio()
		local now = o.now or os.time
		rt.now = now
		rt.data = Data.new({
			store = o.store or memoryStore(),
			modules = order,
			gameId = gameConfig.gameId,
			now = now,
			log = function(msg: string)
				logSink("warn", msg)
			end,
			require = o.require,
		})
		rt.lifecycle = Lifecycle.new(function(msg: string)
			logSink("warn", msg)
		end)
		rt.gameConfigPublic = table.freeze({
			gameId = gameConfig.gameId,
			items = result.items,
			products = Freeze.freezeCopy(gameConfig.products or {}),
			events = Freeze.freezeCopy(gameConfig.events or {}),
		})
		for _, ref in order do
			local impl = impls[ref]
			rt.apis[ref] = Extensions.wrapApi(rt, ref.name, impl.api)
			rt.txApis[ref] = Extensions.wrapTxApi(rt, ref.name, impl.txApi)
			rt.exts[ref] = Extensions.wrapExtensions(rt, ref.name, impl.extensions)
		end
		for _, ref in order do
			ctxs[ref] = Context.build(rt, ref)
		end

		-- 4. init(ctx), in order, no yielding, no cross-module API calls
		rt.phase = "init"
		for _, ref in order do
			local impl = impls[ref]
			if impl.init then
				runNoYield(`{ref.name}.init`, impl.init, ctxs[ref])
			end
		end

		-- 5. start(ctx), in order
		rt.phase = "start"
		for _, ref in order do
			local impl = impls[ref]
			if impl.start then
				local ok, err = pcall(impl.start, ctxs[ref])
				if not ok then
					error(`{ref.name}.start failed: {tostring(err)}`, 0)
				end
			end
		end

		-- 6. framework start
		rt.phase = "running"
		rt.state = "running"
	end

	local function kick(player: any, msg: string)
		if o.kick then
			o.kick(player, msg)
		else
			pcall(function()
				player:Kick(msg)
			end)
		end
	end

	function rt.playerAdded(player: any): boolean
		rt.assertUsable()
		local ok, err = rt.data.load(player)
		if not ok then
			logSink("warn", `[StudWork] {tostring(err)}`)
			kick(player, Server.KICK_MESSAGE)
			return false
		end
		rt.lifecycle.firePlayerLoaded(player)
		rt.frameworkSignals.PlayerLoaded:Fire(player)
		return true
	end

	function rt.playerRemoving(player: any)
		rt.assertUsable()
		if rt.data.isLoaded(player) then
			rt.lifecycle.firePlayerRemoving(player)
			rt.frameworkSignals.PlayerRemoving:Fire(player)
		end
		rt.data.release(player)
	end

	function rt.tick(dt: number)
		rt.assertUsable()
		rt.lifecycle.tick(dt)
	end

	function rt.shutdown()
		rt.assertUsable()
		rt.lifecycle.fireShutdown()
		for _, p in rt.data.players() do
			rt.playerRemoving(p)
		end
	end

	-- Client action routing (minimal until per-module Blink lands): drops calls from players
	-- whose data isn't loaded, pcalls the handler. No rate limit yet.
	function rt.action(player: any, ref: any, actionName: string, ...: any): (boolean, any)
		rt.assertUsable()
		if not enabled[ref] then
			error(Resolve.notEnabledMessage(ref.name), 2)
		end
		local actions = impls[ref].actions
		local action = actions and actions[actionName]
		if action == nil then
			error(`{ref.name} has no action '{actionName}'`, 2)
		end
		if not rt.data.isLoaded(player) then
			return false, "not_loaded"
		end
		local handler = if type(action) == "function" then action else action.handler
		return pcall(handler, player, ...)
	end

	function rt.runConsole(player: any, line: string): (boolean, any)
		rt.assertUsable()
		local words = string.split(line, " ")
		local cmd = rt.console[`{words[1]} {words[2] or ""}`]
		if cmd == nil then
			return false, `unknown command '{line}'`
		end
		return pcall(cmd.fn, player, table.unpack(words, 3))
	end

	local ok, err = pcall(boot :: any)
	if not ok then
		rt.state = "failed"
		rt.phase = "failed"
		rt.bootError = "[StudWork] boot failed; the server refuses every call until it restarts:\n"
			.. tostring(err)
		logSink("warn", rt.bootError)
		error(rt.bootError, 0)
	end

	if o.bindPlatform ~= false then
		(o.bindPlatform or defaultBind)(rt)
	end
	return rt
end

StudWork._installStarter(Server.start)

return Server
