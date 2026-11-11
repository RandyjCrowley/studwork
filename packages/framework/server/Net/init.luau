--!strict
--[[
	Framework Net (module-api.md §9), ported from v1.2 core/server/Net + GameNet. Framework
	internal: modules only ever see the scoped `ctx.net` that Net.forModule builds.

	What it owns:
	  - every listener of the framework's own Blink client events (shared/net/framework.blink;
	    Blink allows one listener per event), registered when the runtime is created, so early
	    requests are parked in a bounded PendingQueue (L3) instead of Blink's unbounded queue;
	  - a per-player token-bucket rate limit per event BEFORE any handler sees a request;
	  - dropping calls from players who left, and from players whose data isn't loaded yet
	    (except events flagged `beforeLoad`, e.g. StateInit), with counters for the console;
	  - pcall around every handler (one failing handler never breaks Net).

	ctx.net (per module, scoped):
	  handle(eventName, fn(player, ...))   serve one FRAMEWORK client event (framework.blink). Each
	                                       event has exactly one owner: a second module (or the
	                                       framework itself) claiming it is an error naming both.
	  handleEvent(name, blinkEvent, { rate, burst }, fn)
	                                       serve one of the module's / game's OWN generated Blink
	                                       server events (v1.2 Core.Net.handle). Same rate limit,
	                                       left/not-loaded drop and pcall. Names are unique per server.
	  feedback(player, kind, text, rarity?, position?)   cosmetic pop/toast (Blink Feedback)
	  fire(player, blinkEvent, ...) / fireAll(blinkEvent, ...)
	                                       the module's own Blink server -> client events. Firing a
	                                       FRAMEWORK event (StateSync, Feedback, EventState) errors:
	                                       those belong to Replication / feedback / Events.
	Blink validates wire types; handlers still validate ownership, ranges and game rules.

	Net.new(opts): opts.events (generated Blink server module; nil = no transport), opts.isPlayer
	(player) -> boolean (still in the game), opts.isLoaded(player) -> boolean, opts.clock,
	opts.spawn(fn, ...), opts.log(msg).
]]

local PendingQueue = require(script.PendingQueue)
local RateLimit = require(script.RateLimit)

local Net = {}

-- Anti-spam rails (tokens/s, burst) per player per event, not balance numbers.
Net.LIMITS = table.freeze({
	StateInit = { rate = 0.2, burst = 2 },
	AdminTriggerEvent = { rate = 1, burst = 3 },
	ClientFunnel = { rate = 2, burst = 10 },
})

-- Client -> server events of framework.blink, in a stable order.
Net.CLIENT_EVENTS = table.freeze({
	"StateInit",
	"AdminTriggerEvent",
	"ClientFunnel",
})

-- Server -> client events of framework.blink: modules can't fire these directly.
Net.FRAMEWORK_SERVER_EVENTS = table.freeze({ "StateSync", "Feedback", "EventState" })

-- Requests (all players, all events) held before Net.start.
Net.PENDING_CAP = 256

-- Rate limit of a module action declared without one (a bare function).
Net.DEFAULT_ACTION_LIMIT = table.freeze({ rate = 4, burst = 8 })

local BEFORE_LOAD = { StateInit = true }

type Handler = (player: any, ...any) -> ()

function Net.new(opts: any): any
	local events: any = opts.events
	local isPlayer: (any) -> boolean = opts.isPlayer
	local isLoaded: (any) -> boolean = opts.isLoaded
	local spawn: (...any) -> () = opts.spawn
	local log: (string) -> () = opts.log
	local limiter = RateLimit.new(opts.clock)

	local handlers: { [string]: { owner: string, fn: Handler } } = {}
	local custom: { [string]: { owner: string } } = {}
	local frameworkEvents: { [any]: string } = {}
	local stats = { unhandled = {} :: { [string]: number }, notLoaded = 0, limited = 0, errors = 0 }
	local started = false
	local pending = PendingQueue.new(Net.PENDING_CAP, function(cap: number)
		log(
			`[StudWork.Net] {cap} client requests arrived before boot finished; dropping further early requests`
		)
	end)

	if events ~= nil then
		for _, name in Net.FRAMEWORK_SERVER_EVENTS do
			local ev = events[name]
			if ev ~= nil then
				frameworkEvents[ev] = name
			end
		end
	end

	local net: any = {}
	net.stats = stats

	local function run(
		label: string,
		fn: Handler?,
		player: any,
		args: { n: number, [number]: any },
		needsLoad: boolean
	)
		if not isPlayer(player) then
			return -- left while queued
		end
		if fn == nil then
			stats.unhandled[label] = (stats.unhandled[label] or 0) + 1 -- module off: drop quietly
			return
		end
		if needsLoad and not isLoaded(player) then
			stats.notLoaded += 1
			return
		end
		local ok, err = pcall(function()
			fn(player, table.unpack(args, 1, args.n))
		end)
		if not ok then
			stats.errors += 1
			log(`[StudWork.Net] {label} handler error: {tostring(err)}`)
		end
	end

	-- One entry point for every client request (framework and custom events).
	local function receive(
		label: string,
		limit: RateLimit.Limit,
		resolve: () -> Handler?,
		needsLoad: boolean,
		player: any,
		...: any
	)
		if not isPlayer(player) then
			return
		end
		if not limiter:allow(player.UserId, label, limit) then
			stats.limited += 1
			return -- silently drop spam
		end
		local args = table.pack(...)
		if not started then
			pending:push(label, player, function()
				run(label, resolve(), player, args, needsLoad)
			end)
			return
		end
		run(label, resolve(), player, args, needsLoad)
	end

	-- Listen to every framework client event now (L3).
	if events ~= nil then
		for _, name in Net.CLIENT_EVENTS do
			local ev = events[name]
			if ev ~= nil and type(ev.On) == "function" then
				ev.On(function(player: any, ...: any)
					receive(name, Net.LIMITS[name], function(): Handler?
						local h = handlers[name]
						return if h then h.fn else nil
					end, not BEFORE_LOAD[name], player, ...)
				end)
			end
		end
	end

	-- Framework services and modules claim framework events through this.
	function net.claim(owner: string, eventName: string, fn: Handler)
		if Net.LIMITS[eventName] == nil then
			error(
				`unknown framework client event '{tostring(eventName)}' (framework.blink has: {table.concat(
					Net.CLIENT_EVENTS,
					", "
				)})`,
				3
			)
		end
		assert(type(fn) == "function", "net.handle: handler must be a function")
		local existing = handlers[eventName]
		if existing ~= nil then
			error(
				`framework event '{eventName}' already has a handler (owned by {existing.owner}); {owner} can't claim it too`,
				3
			)
		end
		handlers[eventName] = { owner = owner, fn = fn }
	end

	-- Test-only (the multi-server sim drives a framework event's handler directly, as v1.2's sim
	-- did, so scenario specs test the module's own validation, not Net's rate limit).
	function net.handlerFor(eventName: string): Handler?
		local h = handlers[eventName]
		return if h then h.fn else nil
	end

	function net.owner(eventName: string): string?
		local h = handlers[eventName]
		return if h then h.owner else nil
	end

	local function checkLimit(limit: any): RateLimit.Limit
		if
			type(limit) ~= "table"
			or type(limit.rate) ~= "number"
			or type(limit.burst) ~= "number"
			or not (limit.rate > 0 and limit.rate < math.huge)
			or not (limit.burst >= 1 and limit.burst < math.huge)
		then
			error("net.handleEvent: limit must be { rate > 0, burst >= 1 } (finite)", 3)
		end
		return { rate = limit.rate, burst = limit.burst }
	end

	function net.handleCustom(owner: string, name: string, event: any, limit: any, fn: Handler)
		if type(name) ~= "string" or not string.match(name, "^[%w_%-%.:]+$") or #name > 64 then
			error("net.handleEvent: name must be a short id string", 3)
		end
		if type(event) ~= "table" or type(event.On) ~= "function" then
			error("net.handleEvent: event must be a generated Blink server event (with .On)", 3)
		end
		if frameworkEvents[event] ~= nil then
			error(`net.handleEvent: '{name}' is a framework Blink event; use ctx.net.handle`, 3)
		end
		assert(type(fn) == "function", "net.handleEvent: handler must be a function")
		local lim = checkLimit(limit)
		local existing = custom[name]
		if existing ~= nil then
			error(`event '{name}' is already handled (by {existing.owner})`, 3)
		end
		custom[name] = { owner = owner }
		local label = "custom:" .. name
		event.On(function(player: any, ...: any)
			receive(label, lim, function(): Handler?
				return fn
			end, true, player, ...)
		end)
	end

	-- Module actions (§9): server part `actions = { name = { limit = { rate, burst }, handler =
	-- fn(player, ...), event = <Blink server event>? } }` (a bare function is { handler = fn } with
	-- DEFAULT_ACTION_LIMIT). An action is bound to the wire through `event`, or the event of the same
	-- name (or PascalCase name) in the module's own generated Blink module (server part `net`).
	-- Every call (wire or net.action) takes the same path as any client request: dropped for a
	-- player who left, rate-limited, queued until Net.start, blocked until data loads, pcall'd.
	local actions: { [string]: { [string]: { limit: RateLimit.Limit, handler: Handler } } } = {}

	local function pascal(name: string): string
		return string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
	end

	function net.bindActions(owner: string, specs: any, moduleNet: any?)
		local mine: { [string]: { limit: RateLimit.Limit, handler: Handler } } = {}
		actions[owner] = mine
		for name, spec in specs or {} do
			if type(name) ~= "string" or not string.match(name, "^[%a_][%w_]*$") then
				error(`{owner}: action names must be identifiers, got '{tostring(name)}'`, 0)
			end
			local handler: any, limit: any, event: any
			if type(spec) == "function" then
				handler, limit = spec, Net.DEFAULT_ACTION_LIMIT
			elseif type(spec) == "table" and type(spec.handler) == "function" then
				handler = spec.handler
				limit = if spec.limit == nil then Net.DEFAULT_ACTION_LIMIT else spec.limit
				event = spec.event
			else
				error(`{owner}.actions.{name}: expected a function or {"{"} limit, handler {"}"}`, 0)
			end
			local ok, lim = pcall(checkLimit, limit)
			if not ok then
				error(`{owner}.actions.{name}: limit must be {"{"} rate > 0, burst >= 1 {"}"} (finite)`, 0)
			end
			if event == nil and type(moduleNet) == "table" then
				event = moduleNet[name] or moduleNet[pascal(name)]
			end
			mine[name] = { limit = lim, handler = handler }
			if event == nil and type(moduleNet) == "table" then
				-- the module ships a wire but no event backs this action, so a
				-- client can never reach it; say so instead of binding it silently wire-less
				log(
					`[StudWork.Net] {owner}.actions.{name}: no Blink event '{name}' or '{pascal(name)}' in the module's net.blink; the action is only callable server-side`
				)
			end
			if event ~= nil then
				if type(event) ~= "table" or type(event.On) ~= "function" then
					error(
						`{owner}.actions.{name}: event must be a generated Blink server event (with .On)`,
						0
					)
				end
				if frameworkEvents[event] ~= nil then
					error(`{owner}.actions.{name}: '{frameworkEvents[event]}' is a framework event`, 0)
				end
				local label = `action:{owner}.{name}`
				event.On(function(player: any, ...: any)
					receive(label, lim, function(): Handler?
						return handler
					end, true, player, ...)
				end)
			end
		end
	end

	function net.hasAction(owner: string, name: string): boolean
		local mine = actions[owner]
		return mine ~= nil and mine[name] ~= nil
	end

	-- A server-side call of a module action (StudWork.test harness h:action, console): the same
	-- checks as a wire call, but synchronous and with the result. -> (ok, result | reason)
	function net.action(owner: string, name: string, player: any, ...: any): (boolean, any)
		local mine = actions[owner]
		local action = mine and mine[name]
		if action == nil then
			error(`{owner} has no action '{name}'`, 2)
		end
		if not isPlayer(player) then
			return false, "left"
		end
		if not isLoaded(player) then
			stats.notLoaded += 1
			return false, "not_loaded"
		end
		if not limiter:allow(player.UserId, `action:{owner}.{name}`, action.limit) then
			stats.limited += 1
			return false, "rate_limited"
		end
		local args = table.pack(...)
		local handler: any = action.handler
		local ok, res = pcall(function(): any
			return handler(player, table.unpack(args, 1, args.n))
		end)
		if not ok then
			stats.errors += 1
			log(`[StudWork.Net] action {owner}.{name} handler error: {tostring(res)}`)
		end
		return ok, res
	end

	function net.feedback(player: any, kind: string, text: string, rarity: string?, position: any?)
		if events == nil or events.Feedback == nil or not isPlayer(player) then
			return
		end
		events.Feedback.Fire(player, {
			Kind = string.sub(tostring(kind), 1, 32),
			Text = string.sub(tostring(text), 1, 120),
			Tier = rarity,
			Position = position,
		})
	end

	-- Framework-internal fire of its own server events (Replication, Events).
	function net.fireFramework(name: string, player: any, ...: any)
		if events == nil or events[name] == nil then
			return
		end
		if player == nil then
			events[name].FireAll(...)
		elseif isPlayer(player) then
			events[name].Fire(player, ...)
		end
	end

	function net.start()
		assert(not started, "[StudWork.Net] already started")
		started = true
		for _, entry in pending:drain() do
			spawn(entry.args[1])
		end
	end

	function net.isStarted(): boolean
		return started
	end

	function net.forget(player: any)
		limiter:forget(player.UserId)
	end

	function net.allow(player: any, label: string, limit: RateLimit.Limit): boolean
		return limiter:allow(player.UserId, label, limit)
	end

	function net.summary(): string
		local lines = {
			`pending dropped (before start): {pending.dropped}`,
			`dropped (not loaded): {stats.notLoaded}`,
			`rate limited: {stats.limited}`,
			`handler errors: {stats.errors}`,
		}
		for _, name in Net.CLIENT_EVENTS do
			local h = handlers[name]
			if h == nil then
				table.insert(lines, `{name}: no handler (module off), dropped {stats.unhandled[name] or 0}`)
			else
				table.insert(lines, `{name}: {h.owner}`)
			end
		end
		for name, c in custom do
			table.insert(lines, `{name}: {c.owner} (custom)`)
		end
		return table.concat(lines, "\n")
	end

	-- The scoped ctx.net for one module.
	function net.forModule(owner: string): any
		return table.freeze({
			handle = function(eventName: string, fn: Handler)
				net.claim(owner, eventName, fn)
			end,
			handleEvent = function(name: string, event: any, limit: any, fn: Handler)
				net.handleCustom(owner, name, event, limit, fn)
			end,
			feedback = function(player: any, kind: string, text: string, rarity: string?, position: any?)
				net.feedback(player, kind, text, rarity, position)
			end,
			fire = function(player: any, event: any, ...: any)
				if type(event) ~= "table" or type(event.Fire) ~= "function" then
					error("ctx.net.fire(player, event, ...): event must be a generated Blink server event", 2)
				end
				if frameworkEvents[event] ~= nil then
					error(
						`ctx.net.fire: '{frameworkEvents[event]}' is a framework event; modules can't fire it`,
						2
					)
				end
				if isPlayer(player) then
					event.Fire(player, ...)
				end
			end,
			fireAll = function(event: any, ...: any)
				if type(event) ~= "table" or type(event.FireAll) ~= "function" then
					error("ctx.net.fireAll(event, ...): event must be a generated Blink server event", 2)
				end
				if frameworkEvents[event] ~= nil then
					error(
						`ctx.net.fireAll: '{frameworkEvents[event]}' is a framework event; modules can't fire it`,
						2
					)
				end
				event.FireAll(...)
			end,
		})
	end

	return net
end

return Net
