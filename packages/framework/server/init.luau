--!strict
--[[
	StudWork server runtime: the boot sequence (module-api.md §3) and the running server.

	  StudWork.start(Config, ServerConfig)   -- the game's one-line server bootstrap

	Boot steps:
	  1. resolve        Loader: refs, hard deps listed, names/data keys unique, framework range,
	                    topo order (ties = list order), cycles named; server parts found by name
	  2. validate       ConfigValidate: per-module config (defaults <- config.<Name>, schema),
	                    items (base fields + enabled modules' itemFields), theme; ALL errors at once
	  3. framework init Data (+ store), Lifecycle, Net (listens now; requests queue until step 6),
	                    Replication, Policy, Analytics, Compliance, Events, Shop, Console; wrapped
	                    module surfaces; one scoped ctx per module
	  4. init(ctx)      every module, boot order; must not yield; other modules' APIs are blocked
	  5. start(ctx)     every module, boot order; dependency APIs allowed; must not yield
	  6. framework start Events start, Net releases its queue, console installed, then Shop
	                    claims ProcessReceipt (the very last step, §7.1); players load, ticker runs
	If any step throws, boot fails closed (N7): Server.start re-raises, and every later call into
	the runtime, any module API, StudWork.use and StudWork.<Name> errors with the boot message.

	opts (all optional; tests and the sim inject them, a live server uses Platform.live()):
	  platform                     the engine adapter (Platform.luau); default Platform.live(),
	                               or Platform.inert() when bindPlatform == false
	  loadServer(ref) -> impl      find a module's server part (default ServerScriptService.Modules)
	  store                        Data store (default platform.makeStore(gameId))
	  shared                       ctx.data.shared backend (SharedStore.luau; default
	                               platform.makeShared(gameId), else SharedStore.memory())
	  now() -> number              unix seconds (default platform.now)
	  isStudio: boolean            default platform.isStudio
	  logSink(level, msg)          default print/warn
	  kick(player, msg)            default platform.kick
	  bindPlatform                 false = don't connect Players/Heartbeat/BindToClose
	  require                      used for migrations folders (default require)
	  gameModule                   the game's implicit module (§7, C4); default platform.gameModule()
	                               (live: ReplicatedStorage.GameModule.module). It is appended to
	                               GameConfig.modules unless already listed; the game never lists
	                               itself. Its data.key must be the gameId (the v1.2 game[gameId]
	                               table splits into that section).
]]

local Shared = require(script.Shared)
local requireShared = require :: any -- see Shared.luau
local ConfigValidate = requireShared(Shared.ConfigValidate)
local Freeze = requireShared(Shared.Freeze)
local Resolve = requireShared(Shared.Resolve)
local Signal = requireShared(Shared.Signal)
local StudWork = requireShared(Shared)
local Admins = require(script.Events.Admins)
local Analytics = require(script.Analytics)
local Boot = require(script.Boot)
local Compliance = require(script.Compliance)
local Context = require(script.Context)
local Data = require(script.Data)
local Events = require(script.Events)
local Extensions = require(script.Extensions)
local Lifecycle = require(script.Lifecycle)
local Loader = require(script.Loader)
local Net = require(script.Net)
local Platform = require(script.Platform)
local Policy = require(script.Policy)
local Replication = require(script.Replication)
local Shop = require(script.Shop)
local SharedStore = require(script.SharedStore)
local Store = require(script.Store)
local Legacy = require(script.Legacy)

local Server = {}

Server.KICK_MESSAGE =
	"Your save couldn't be loaded safely, so nothing was changed. Please rejoin in a moment."
Server.KICK_SESSION_ENDED = "Your save data was opened in another server. Please rejoin."
-- (added in v1.6.0, adopting.md §3) a legacy import failed: nothing was written, the next join retries
Server.KICK_LEGACY_IMPORT =
	"We couldn't bring over your save from the previous version yet. Nothing was lost. Please rejoin in a minute."

Server.memoryStore = Store.memory
-- (added in v1.6.0) StudWork.test.legacyStore: an in-memory, read-only legacy store (Legacy.luau)
Server.legacyStore = Legacy.memory

local function runNoYield(label: string, what: string, fn: any, ...: any)
	local co = coroutine.create(fn)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		error(`{label} failed: {tostring(err)}`, 0)
	end
	if coroutine.status(co) ~= "dead" then
		coroutine.close(co)
		error(`{label} yielded: {what} must not yield (connect events and start loops with task.spawn)`, 0)
	end
end

local function splitWords(...: any): { string }
	local words: { string } = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		for w in string.gmatch(tostring(v), "%S+") do
			table.insert(words, w)
		end
	end
	return words
end

-- (v1.6.0) the console's `adopt status` text: one line per registered import.
function Server.formatAdoptStatus(ids: { string }, markers: { [string]: any }): string
	if #ids == 0 then
		return "no importLegacy registered"
	end
	local lines = {}
	for _, id in ids do
		local m = markers[id]
		if type(m) ~= "table" then
			table.insert(lines, `{id}: no marker (not imported yet)`)
		else
			local parts = {}
			local names = {}
			for name in (if type(m.sources) == "table" then m.sources else {}) :: any do
				table.insert(names, name)
			end
			table.sort(names)
			for _, name in names do
				local src = m.sources[name]
				table.insert(
					parts,
					`{name}={if src.found then "found" else "none"}{if src.updatedAt
						then "@" .. tostring(math.floor(src.updatedAt))
						else ""}`
				)
			end
			table.insert(
				lines,
				`{id}: v={tostring(m.v)} at={tostring(m.at)} found={tostring(m.found)} sources: {table.concat(
					parts,
					", "
				)}`
			)
		end
	end
	return table.concat(lines, "\n")
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
	local function warnLog(msg: string)
		logSink("warn", msg)
	end
	local platform = o.platform or (if o.bindPlatform == false then Platform.inert() else Platform.live())
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
		purchaseOps = {},
		console = {},
		frameworkSignals = table.freeze({
			PlayerLoaded = Signal.new("framework.PlayerLoaded"),
			PlayerRemoving = Signal.new("framework.PlayerRemoving"),
			ProductGranted = Signal.new("framework.ProductGranted"),
			EventStarted = Signal.new("framework.EventStarted"),
			EventEnded = Signal.new("framework.EventEnded"),
		}),
		logSink = logSink,
		serverConfig = serverConfig,
		order = {},
		platform = platform,
		gameModule = nil,
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
	-- May module `callerName` reach `owner` (a ref or a module name)? Itself, or a declared dep.
	function rt.canUse(callerName: string, owner: any): boolean
		local ownerRef = if type(owner) == "string" then byName[owner] else owner
		local caller = byName[callerName]
		if caller == nil or ownerRef == nil then
			return false
		end
		if caller == ownerRef then
			return true
		end
		for _, d in caller.dependsOn do
			if d == ownerRef then
				return true
			end
		end
		for _, d in caller.optional do
			if d == ownerRef then
				return true
			end
		end
		return false
	end

	Boot.attach(rt)

	local impls: { [any]: any } = {}
	local ctxs: { [any]: any } = {}
	-- The signals a module created with ctx.signals.new, by name (framework-internal; the test
	-- harnesses record them, StudWork.test.sim's server:heard).
	function rt.moduleSignals(ref: any): { [string]: any }
		local out: { [string]: any } = {}
		local c = ctxs[ref]
		if c ~= nil then
			for name, signal in c.signals do
				if
					type(name) == "string"
					and type(signal) == "table"
					and type(rawget(signal, "Connect")) == "function"
				then
					out[name] = signal
				end
			end
		end
		return out
	end

	local function kick(player: any, msg: string)
		if o.kick then
			o.kick(player, msg)
		else
			platform.kick(player, msg)
		end
	end

	local function registerFrameworkConsole()
		local function cmd(key: string, help: string, fn: (...string) -> any)
			rt.console[key] = {
				owner = "framework",
				fn = function(_player: any, ...: string)
					return fn(...)
				end,
				help = help,
			}
		end
		local function target(userId: string?): any
			local id = tonumber(userId)
			if id then
				return platform.players.byUserId(id)
			end
			return platform.players.list()[1]
		end
		cmd("modules", "modules: enabled modules in boot order", function()
			local names = {}
			for _, ref in rt.order do
				table.insert(names, ref.name)
			end
			return if #names == 0 then "framework only" else table.concat(names, ", ")
		end)
		-- (added in v1.6.0) adopt status <userId>: every legacy import marker (Studio or an admin)
		rt.console["adopt status"] = {
			owner = "framework",
			help = "adopt status [userId]: the player's legacy import markers (Studio or admin)",
			fn = function(caller: any, userId: string?): string
				local admins = if type(rt.serverConfig) == "table" then rt.serverConfig.admins else nil
				local allowed = rt.isStudio
					or (caller ~= nil and Admins.isAdmin(caller.UserId, rt.isStudio, admins, nil))
				if not allowed then
					return "Studio or admin only"
				end
				local player = target(userId)
				if player == nil or not rt.data.isLoaded(player) then
					return "no loaded player"
				end
				return Server.formatAdoptStatus(rt.data.legacyImports(), rt.data.legacyMarkers(player) or {})
			end,
		}
		cmd("net", "net: framework event owners, dropped and rate-limited request counts", function()
			return rt.net.summary()
		end)
		cmd("data dump", "data dump [userId]: the player's whole save (Studio)", function(userId: string?)
			if not rt.isStudio then
				return "Studio-only"
			end
			local player = target(userId)
			if player == nil or not rt.data.isLoaded(player) then
				return "no loaded player"
			end
			local out = {}
			for _, ref in rt.order do
				if ref.data then
					out[ref.data.key] = rt.data.view(player, ref.data.key)
				end
			end
			out._framework = {
				firstJoin = rt.data.frameworkField(player, "firstJoin"),
				lastSeen = rt.data.frameworkField(player, "lastSeen"),
				stats = rt.data.frameworkField(player, "stats"),
				funnel = rt.data.frameworkField(player, "funnel"),
				purchases = rt.data.frameworkField(player, "purchases"),
			}
			if platform.encode == nil then
				return "data dump: this platform has no JSON encoder (platform.encode)"
			end
			local ok, text = pcall(platform.encode, out)
			if not ok then
				return "data dump: could not encode the save: " .. tostring(text)
			end
			return text
		end)
		cmd(
			"policy restrict",
			"policy restrict <true|false|clear> [userId]: override the paid-random policy (Studio)",
			function(value: string?, userId: string?)
				if not rt.isStudio then
					return "Studio-only"
				end
				local player = target(userId)
				if player == nil then
					return "no player"
				end
				if value == "true" then
					rt.policy.override(player, true)
				elseif value == "false" then
					rt.policy.override(player, false)
				elseif value == "clear" then
					rt.policy.override(player, nil)
				else
					return "usage: policy restrict <true|false|clear> [userId]"
				end
				return `{tostring(player)} paidRandomRestricted = {tostring(
					rt.policy.paidRandomRestricted(player)
				)}`
			end
		)
		cmd(
			"shop receipt",
			"shop receipt <productName> [purchaseId] [userId]: simulate ProcessReceipt twice (Studio)",
			function(name: string?, purchaseId: string?, userId: string?)
				return rt.shop.consoleReceipt(name, purchaseId, userId)
			end
		)
		cmd(
			"events event",
			"events event [id]: trigger an event now (no id = list events)",
			function(id: string?)
				if id == nil then
					return rt.events.consoleList()
				end
				if rt.gameConfigPublic.events[id] == nil then
					return "unknown event " .. id
				end
				if rt.events.trigger(id, platform.players.list()[1]) then
					return `started {id}`
				end
				return id .. " is already active"
			end
		)
	end

	-- The game's implicit module (§7, C4) joins GameConfig.modules here; the game doesn't list it.
	local function withGameModule(config: any): any
		if type(config) ~= "table" then
			return config
		end
		local gm = o.gameModule
		if gm == nil and platform.gameModule then
			gm = platform.gameModule()
		end
		if gm == nil then
			return config
		end
		if not StudWork.isModuleRef(gm) then
			error("the game module (GameModule.module) must return StudWork.defineModule(...)", 0)
		end
		if gm.data ~= nil and gm.data.key ~= config.gameId then
			error(
				`the game module '{gm.name}' must use data.key = gameId ('{tostring(config.gameId)}'), got '{gm.data.key}'`,
				0
			)
		end
		rt.gameModule = gm
		local list = {}
		local listed = false
		for i, ref in (if type(config.modules) == "table" then config.modules else {}) :: { any } do
			list[i] = ref
			if ref == gm then
				listed = true
			end
		end
		if not listed then
			table.insert(list, gm)
		end
		local out = table.clone(config)
		out.modules = list
		return out
	end

	local function boot()
		gameConfig = withGameModule(gameConfig)
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
		rt.isStudio = if o.isStudio ~= nil then o.isStudio else platform.isStudio
		local now = o.now or platform.now
		rt.now = now
		-- (added in v1.6.0, adopting.md §3/§4) the read-only reader of a game's OLD stores
		local legacyBackend = o.legacy or (if platform.makeLegacy then platform.makeLegacy() else nil)
		if legacyBackend == nil and o.platform == nil and o.bindPlatform ~= false then
			-- the live engine: read-only GetAsync / GetSortedAsync, built on first read only
			legacyBackend = Legacy.live(warnLog)
		end
		rt.legacy = Legacy.new({
			backend = legacyBackend or Legacy.memory(),
			now = now,
			wait = platform.wait,
			log = warnLog,
			isStudio = rt.isStudio,
		})
		rt.data = Data.new({
			store = o.store or platform.makeStore(gameConfig.gameId),
			legacy = rt.legacy,
			modules = order,
			gameId = gameConfig.gameId,
			now = now,
			log = warnLog,
			require = o.require,
			onSessionLost = function(player: any)
				kick(player, Server.KICK_SESSION_ENDED)
			end,
			-- (v1.6.0) the legacy import's re-check and analytics
			isPlayer = platform.isPlayer,
			onLegacy = function(player: any, event: string, fields: any)
				if rt.analytics then
					rt.analytics.api.custom(player, event, 1, fields)
				end
			end,
		})
		rt.shared = SharedStore.new({
			backend = o.shared or (if platform.makeShared
				then platform.makeShared(gameConfig.gameId)
				else SharedStore.memory()),
			wait = platform.wait,
			log = warnLog,
		})
		rt.lifecycle = Lifecycle.new(warnLog)
		rt.gameConfigPublic = table.freeze({
			gameId = gameConfig.gameId,
			items = result.items,
			products = Freeze.freezeCopy(gameConfig.products or { passes = {}, devProducts = {} }),
			events = Freeze.freezeCopy(gameConfig.events or {}),
		})
		rt.net = Net.new({
			events = platform.events,
			isPlayer = platform.isPlayer,
			isLoaded = function(player: any): boolean
				return rt.data.isLoaded(player)
			end,
			clock = platform.clock,
			spawn = platform.spawn,
			log = warnLog,
		})
		rt.replication = Replication.new({
			modules = order,
			data = rt.data,
			isPlayer = platform.isPlayer,
			makeSync = platform.makeSync,
			log = warnLog,
		})
		rt.data.onChange(function(player: any)
			rt.replication.markDirty(player)
		end)
		rt.policy = Policy.new({
			lookup = platform.policyLookup,
			isPlayer = platform.isPlayer,
			wait = platform.wait,
			delay = platform.delay,
			publish = function(player: any, value: boolean)
				rt.replication.setFramework(player, "paidRandomRestricted", value)
			end,
			log = warnLog,
		})
		rt.analytics = Analytics.new({
			config = gameConfig.analytics,
			service = platform.analytics,
			data = rt.data,
			now = now,
			log = warnLog,
		})
		local compliance = if type(gameConfig.compliance) == "table" then gameConfig.compliance else {}
		rt.compliance = Compliance.new({
			data = rt.data,
			policy = rt.policy,
			replication = rt.replication,
			paidCurrencies = compliance.paidCurrencies,
			canUse = rt.canUse,
			isPlayer = platform.isPlayer,
			log = warnLog,
		})
		local admins = if type(serverConfig) == "table" then serverConfig.admins else nil
		rt.events = Events.new({
			config = rt.gameConfigPublic.events,
			now = now,
			spawn = platform.spawn,
			log = warnLog,
			feedback = rt.net.feedback,
			players = platform.players.list,
			fireState = function(id: string, endsAt: number)
				rt.net.fireFramework("EventState", nil, id, endsAt)
			end,
			replicateAll = function(snapshot: any)
				rt.replication.setFrameworkAll("activeEvents", snapshot)
			end,
			signals = rt.frameworkSignals,
			isAdmin = function(player: any): boolean
				return Admins.isAdmin(player.UserId, rt.isStudio, admins, nil)
			end,
		})
		rt.shop = Shop.new({
			data = rt.data,
			policy = rt.policy,
			products = Freeze.deepCopy(gameConfig.products or { passes = {}, devProducts = {} }),
			marketplace = platform.marketplace,
			players = platform.players,
			isPlayer = platform.isPlayer,
			feedback = rt.net.feedback,
			analytics = rt.analytics.api,
			signals = rt.frameworkSignals,
			purchaseOps = function(ref: any): any
				return rt.purchaseOps[ref] or {}
			end,
			canUse = rt.canUse,
			isEnabled = rt.isEnabled,
			now = now,
			spawn = platform.spawn,
			wait = platform.wait,
			log = warnLog,
			isStudio = rt.isStudio,
			guid = platform.guid,
			-- (added in v1.6.0, adopting.md §4)
			legacy = rt.legacy,
			hasLegacyImport = function(): boolean
				return #rt.data.legacyImports() > 0
			end,
		})
		-- framework-owned client events
		rt.net.claim("framework", "StateInit", function(player: any)
			rt.replication.subscribe(player)
		end)
		rt.net.claim("framework", "ClientFunnel", function(player: any, step: any)
			rt.analytics.clientFunnel(player, step)
		end)
		rt.net.claim("framework", "AdminTriggerEvent", function(player: any, eventId: any)
			rt.events.adminTrigger(player, eventId)
		end)
		registerFrameworkConsole()

		for _, ref in order do
			local impl = impls[ref]
			rt.apis[ref] = Extensions.wrapApi(rt, ref.name, impl.api)
			rt.txApis[ref] = Extensions.wrapTxApi(rt, ref.name, impl.txApi)
			rt.exts[ref] = Extensions.wrapExtensions(rt, ref.name, impl.extensions)
			rt.purchaseOps[ref] = Extensions.wrapTxApi(rt, ref.name, impl.purchaseOps)
		end
		for _, ref in order do
			ctxs[ref] = Context.build(rt, ref)
		end
		for _, ref in order do
			local impl = impls[ref]
			if impl.actions then
				rt.net.bindActions(ref.name, impl.actions, impl.net) -- listening now; queued until step 6
			end
		end

		-- 4. init(ctx), in order, no yielding, no cross-module API calls
		rt.phase = "init"
		for _, ref in order do
			local impl = impls[ref]
			if impl.init then
				runNoYield(`{ref.name}.init`, "init(ctx)", impl.init, ctxs[ref])
			end
		end

		-- 5. start(ctx), in order (decision 5: start must not yield either)
		rt.phase = "start"
		for _, ref in order do
			local impl = impls[ref]
			if impl.start then
				runNoYield(`{ref.name}.start`, "start(ctx)", impl.start, ctxs[ref])
			end
		end
		rt.compliance.assertSpenders() -- R20: every paid currency has a spender (module-api.md §19.10)

		-- 6. framework start
		rt.events.start()
		rt.net.start() -- releases the queued requests (module handlers run here)
		platform.installConsole(function(...: any): string
			return rt.consoleText(...)
		end)
		rt.shop.claim() -- LAST: no module code that runs during boot can replace it (§7.1)
		rt.phase = "running"
		rt.state = "running"
	end

	function rt.playerAdded(player: any): boolean
		rt.assertUsable()
		platform.spawn(rt.policy.track, player)
		rt.shop.playerAdded(player)
		local ok, err, kind = rt.data.load(player)
		if not ok then
			logSink("warn", `[StudWork] {tostring(err)}`)
			kick(player, if kind == "legacy" then Server.KICK_LEGACY_IMPORT else Server.KICK_MESSAGE)
			return false
		end
		rt.lifecycle.firePlayerLoaded(player)
		rt.frameworkSignals.PlayerLoaded:Fire(player)
		rt.analytics.onLoaded(player)
		rt.compliance.onPlayerLoaded(player)
		rt.events.onPlayerLoaded(player)
		rt.shop.playerLoaded(player)
		rt.replication.markDirty(player)
		return true
	end

	function rt.playerRemoving(player: any)
		rt.assertUsable()
		if rt.data.isLoaded(player) then
			rt.lifecycle.firePlayerRemoving(player)
			rt.frameworkSignals.PlayerRemoving:Fire(player)
			rt.shop.settleOnLeave(player) -- N9: may yield (one confirmed save) before the release
		end
		rt.data.release(player)
		rt.policy.forget(player)
		rt.shop.playerRemoving(player)
		rt.replication.remove(player)
		rt.net.forget(player)
	end

	function rt.passPurchased(player: any, gamePassId: number, wasPurchased: boolean)
		rt.shop.passPurchased(player, gamePassId, wasPurchased)
	end

	function rt.tick(dt: number)
		rt.assertUsable()
		rt.lifecycle.tick(dt)
		rt.events.tick(dt)
		rt.shop.tick(dt) -- §7.1 ProcessReceipt owner check
		rt.replication.step()
	end

	function rt.shutdown()
		rt.assertUsable()
		rt.lifecycle.fireShutdown()
		for _, p in rt.data.players() do
			rt.playerRemoving(p)
		end
	end

	-- Module-declared actions (§9, server.actions): routed by Net (wire: the module's own Blink
	-- events; here: a server-side call, e.g. the harness's h:action). Left / not loaded / rate
	-- limit / pcall all apply. -> (ok, result | reason)
	function rt.action(player: any, ref: any, actionName: string, ...: any): (boolean, any)
		rt.assertUsable()
		if not enabled[ref] then
			error(Resolve.notEnabledMessage(ref.name), 2)
		end
		if not rt.net.hasAction(ref.name, actionName) then
			error(`{ref.name} has no action '{actionName}'`, 2)
		end
		return rt.net.action(ref.name, actionName, player, ...)
	end

	-- Console: `<prefix> <command> args...` (module commands are prefixed with the lower-case
	-- module name) or a framework command (`modules`, `net`, `data dump`, ...).
	function rt.runConsole(player: any, line: string): (boolean, any)
		rt.assertUsable()
		local words = splitWords(line)
		local two = `{words[1] or ""} {words[2] or ""}`
		local cmd = rt.console[two]
		local rest = 3
		if cmd == nil then
			cmd = rt.console[words[1] or ""]
			rest = 2
		end
		if cmd == nil then
			return false, `unknown command '{line}' (try 'help')`
		end
		return pcall(cmd.fn, player, table.unpack(words, rest))
	end

	function rt.consoleText(...: any): string
		local words = splitWords(...)
		if #words == 0 or words[1] == "help" then
			local keys = {}
			for k in rt.console do
				table.insert(keys, k)
			end
			table.sort(keys)
			local lines = { "StudWork console:" }
			for _, k in keys do
				local c = rt.console[k]
				table.insert(lines, `  {k}{if c.help ~= "" then " - " .. c.help else ""}`)
			end
			return table.concat(lines, "\n")
		end
		local ok, res = rt.runConsole(nil, table.concat(words, " "))
		if not ok then
			return "error: " .. tostring(res)
		end
		return if res == nil then "ok" else tostring(res)
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

	if o.bindPlatform ~= false and platform.bind then
		platform.bind(rt)
	end
	return rt
end

Boot.installStarter(Server.start)

return Server
