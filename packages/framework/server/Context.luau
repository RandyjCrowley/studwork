--!strict
--[[
	Builds each module's scoped ctx at boot (module-api.md §5, §5.2). A module gets exactly this
	table and nothing else; every field is scoped to the module (its config, its section, its
	declared dependencies, its console prefix, its log tag).

	Full implementations: name, config, gameConfig, deps, depsTx, depsExt, isEnabled, data
	(ScopedData), tx, section, framework, signals, console, lifecycle, log, theme (read-only
	merged tree), isStudio, serverConfig.
	Minimal stubs (server/Stubs.luau): net, replicate, compliance, policy, analytics, events, shop.
]]

local Shared = require(script.Parent.Shared)
local requireShared = require :: any -- see Shared.luau
local Freeze = requireShared(Shared.Freeze)
local Resolve = requireShared(Shared.Resolve)
local Signal = requireShared(Shared.Signal)
local StudWork = requireShared(Shared)
local Stubs = require(script.Parent.Stubs)

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

	local stubs = Stubs.build(rt, name)
	local ctx = {
		name = name,
		config = rt.configs[name],
		gameConfig = rt.gameConfigPublic,
		deps = refTable(rt, name, declared, function(r)
			return rt.apis[r]
		end),
		depsTx = refTable(rt, name, declared, function(r)
			return rt.txApis[r]
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
		}),

		net = stubs.net,
		replicate = stubs.replicate,
		compliance = stubs.compliance,
		policy = stubs.policy,
		analytics = stubs.analytics,
		events = stubs.events,
		shop = stubs.shop,

		signals = signals,
		console = console,
		lifecycle = rt.lifecycle.api(name),
		log = log,
		theme = rt.theme,
		isStudio = rt.isStudio,
		serverConfig = Freeze.freezeCopy(
			if type(rt.serverConfig) == "table" then rt.serverConfig[name] else nil
		),
	}
	return table.freeze(ctx)
end

Context.notEnabledMessage = Resolve.notEnabledMessage

return Context
