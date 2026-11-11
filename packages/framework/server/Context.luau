--!strict
--[[
	Builds each module's scoped ctx at boot (module-api.md §5, §5.2). A module gets exactly this
	table and nothing else; every field is scoped to the module (its config, its section, its
	declared dependencies, its console prefix, its log tag).

	name, config, gameConfig, deps, depsTx (v1.6.0: import-guarded, Context.importGuard), depsExt, isEnabled, data (ScopedData, incl.
	saveAsync, the cross-server `messages` channel and, v1.6.0,
	importLegacy / legacyStatus / isImport), tx, section, framework (firstJoin,
	lastSeen, sessions), now (the framework clock, unix seconds; v1.3.0), data.shared (the
	cross-server shared store, SharedStore.luau; v1.3.0), signals, console, lifecycle, log, theme (read-only merged tree), isStudio,
	serverConfig, and the framework services, each scoped to this module (v1.3.0):
	  net         Net.forModule          handle / handleEvent / feedback / fire / fireAll
	  replicate   Replication.forModule  set / setAll / sent  (state.modules[<Name>].extra)
	  compliance  Compliance.forModule   registerRandomSource / roll / spendForRoll / ...
	  policy      Policy.api             paidRandomRestricted / isKnown (read-only)
	  analytics   Analytics.api          funnel / economy / custom
	  events      Events.forModule       schedule / trigger / isActive / onEnded
	  shop        Shop.forModule         onProduct / onPassOwned / ownsPass
]]

local Shared = require(script.Parent.Shared)
local requireShared = require :: any -- see Shared.luau
local Freeze = requireShared(Shared.Freeze)
local Resolve = requireShared(Shared.Resolve)
local Signal = requireShared(Shared.Signal)
local StudWork = requireShared(Shared)

local Context = {}

local function refTable(rt: any, owner: string, declared: { any }, pick: (ref: any) -> any): any
	local t = {}
	for _, ref in declared do
		if rt.isEnabled(ref) then
			t[ref] = pick(ref)
		else
			t[ref] = StudWork._notEnabledProxy(ref.name)
		end
	end
	return table.freeze(setmetatable(
		t,
		table.freeze({
			__index = function(_, ref: any)
				local name = if type(ref) == "table" and type(ref.name) == "string"
					then ref.name
					else tostring(ref)
				error(
					`{owner}: '{name}' is not a declared dependency; add it to dependsOn or optional in {owner}'s module.luau`,
					2
				)
			end,
		})
	) :: any)
end

function Context.build(rt: any, ref: any): any
	local name: string = ref.name
	local declared: { any } = {}
	for _, d in ref.dependsOn do
		table.insert(declared, d)
	end
	for _, d in ref.optional do
		table.insert(declared, d)
	end
	local key: string? = if ref.data then ref.data.key else nil
	local data = rt.data

	local function needKey(what: string): string
		if key == nil then
			error(`{name}: {what} needs a save section; declare data = {"{"} key, version, default {"}"}`, 3)
		end
		return key :: string
	end

	local scoped = table.freeze({
		get = function(player: any): any
			rt.assertUsable()
			return data.view(player, needKey("ctx.data.get"))
		end,
		update = function(player: any, fn: (section: any) -> ()): boolean
			rt.assertUsable()
			local k = needKey("ctx.data.update")
			local ok = data.runTx(player, function(tx)
				fn(data.section(tx, k))
			end)
			return ok
		end,
		isLoaded = function(player: any): boolean
			return data.isLoaded(player)
		end,
		onLoaded = function(fn: (player: any) -> ())
			data.onLoaded(needKey("ctx.data.onLoaded"), fn)
		end,
		sectionVersion = function(player: any): number
			return data.sectionVersion(player, needKey("ctx.data.sectionVersion"))
		end,
		-- Yields until this player's save (every section) is confirmed written.
		saveAsync = function(player: any): boolean
			rt.assertUsable()
			return data.saveAsync(player)
		end,
		-- Cross-server messages to another user's save, delivered to THIS module on the server
		-- where that user next loads (ProfileStore messages; at-least-once: handlers call
		-- processed() once the message is consumed, otherwise it is delivered again).
		messages = table.freeze({
			send = function(userId: number, payload: any): boolean
				rt.assertUsable()
				return data.sendMessage(name, userId, payload)
			end,
			onReceive = function(fn: (player: any, payload: any, processed: () -> ()) -> ())
				data.onMessage(name, fn)
			end,
			nudge = function(userId: number)
				data.nudge(userId)
			end,
		}),
		-- Durable, atomic, cross-server key-value store; keys are this module's own (prefixed with
		-- its name). update(key, fn(old) -> new) -> (ok, new); yields (SharedStore.luau).
		shared = rt.shared.forModule(name, rt.assertUsable),
		-- (added in v1.6.0, adopting.md §3) a one-time import of the player's OLD save; init only
		importLegacy = function(spec: any)
			if rt.phase ~= "init" then
				error(`{name}: ctx.data.importLegacy must be called in init (now: {tostring(rt.phase)})`, 2)
			end
			data.registerImport(name, spec)
		end,
		legacyStatus = function(player: any, id: string): any
			return data.legacyStatus(player, id)
		end,
		isImport = function(tx: any): boolean
			return data.isImport(tx)
		end,
	})

	local signals: any = {
		framework = rt.frameworkSignals,
	}
	function signals.new(signalName: string): any
		assert(type(signalName) == "string", "ctx.signals.new(name)")
		assert(rawget(signals, signalName) == nil, `{name}: signal '{signalName}' already exists`)
		local s = Signal.new(`{name}.{signalName}`)
		rawset(signals, signalName, s)
		return s
	end

	local prefix = string.lower(name)
	local console = table.freeze({
		register = function(command: string, fn: (player: any, ...string) -> any, help: string?)
			assert(
				type(command) == "string" and string.match(command, "^[%w_%-]+$"),
				"console command must be a word"
			)
			local full = prefix .. " " .. command
			assert(rt.console[full] == nil, `console command '{full}' already registered`)
			rt.console[full] = { owner = name, fn = fn, help = help or "" }
		end,
	})

	local function tagged(level: string): (...any) -> ()
		return function(...: any)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			rt.logSink(level, `[{name}] {table.concat(parts, " ")}`)
		end
	end
	local log = table.freeze({ info = tagged("info"), warn = tagged("warn"), debug = tagged("debug") })

	local ctx = {
		name = name,
		config = rt.configs[name],
		gameConfig = rt.gameConfigPublic,
		deps = refTable(rt, name, declared, function(r)
			return rt.apis[r]
		end),
		depsTx = refTable(rt, name, declared, function(r)
			return Context.importGuard(data, r.name, rt.txApis[r])
		end),
		depsExt = refTable(rt, name, declared, function(r)
			return rt.exts[r]
		end),
		isEnabled = function(r: any): boolean
			return rt.isEnabled(r)
		end,

		data = scoped,
		tx = function(player: any, fn: (tx: any) -> any): (boolean, any)
			rt.assertUsable()
			return data.runTx(player, fn)
		end,
		section = function(tx: any): any
			return data.section(tx, needKey("ctx.section"))
		end,
		framework = table.freeze({
			firstJoin = function(player: any): number
				return data.frameworkField(player, "firstJoin")
			end,
			lastSeen = function(player: any): number
				return data.frameworkField(player, "lastSeen")
			end,
			sessions = function(player: any): number
				local stats = data.frameworkField(player, "stats")
				return if type(stats) == "table" then stats.sessions or 0 else 0
			end,
		}),

		net = rt.net.forModule(name),
		replicate = rt.replication.forModule(name),
		compliance = rt.compliance.forModule(name),
		policy = rt.policy.api,
		analytics = rt.analytics.api,
		events = rt.events.forModule(name),
		shop = rt.shop.forModule(name),

		signals = signals,
		console = console,
		lifecycle = rt.lifecycle.api(name),
		log = log,
		theme = rt.theme,
		isStudio = rt.isStudio,
		-- the framework clock (unix seconds): the same clock that stamps lastSeen; tests drive it
		now = function(): number
			return rt.now()
		end,
		serverConfig = Freeze.freezeCopy(
			if type(rt.serverConfig) == "table" then rt.serverConfig[name] else nil
		),
	}
	return table.freeze(ctx)
end

-- (v1.6.0, adopting.md §3) inside a legacy import tx, a txApi call whose first return value is
-- nil or false raises, so an import fails closed instead of committing a partial save. Outside an
-- import the wrapper is one isImport lookup and a tail call.
function Context.importGuard(data: any, owner: string, txApi: any): any
	if type(txApi) ~= "table" then
		return txApi
	end
	local out = {}
	for key, fn in txApi do
		if type(fn) ~= "function" then
			out[key] = fn
			continue
		end
		out[key] = function(tx: any, ...: any): ...any
			if not data.isImport(tx) then
				return fn(tx, ...)
			end
			local res = table.pack(fn(tx, ...))
			if res[1] == nil or res[1] == false then
				error(`legacy import: {owner}.{tostring(key)} refused ({tostring(res[1])})`, 2)
			end
			return table.unpack(res, 1, res.n)
		end
	end
	return table.freeze(out)
end

Context.notEnabledMessage = Resolve.notEnabledMessage

return Context
