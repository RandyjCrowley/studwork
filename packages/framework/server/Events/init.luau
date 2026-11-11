--!strict
--[[
	Framework Events (ported from v1.2 core/server/Events). Framework internal; modules see
	ctx.events = { schedule, trigger, isActive, onEnded }.

	Live events are defined in GameConfig.events[id] = { schedule?, durationSec, data? }.
	  - schedule(id, schedule?, handler): sets the handler and optionally overrides the config
	    schedule. One handler per event id, owned by the module that registered it: a second module
	    scheduling the same id errors (per-module scoping). Every config event with a schedule runs
	    on the timer even without a handler. Schedules are UTC (Schedule.luau), derived only from
	    the clock, so every server agrees; a server booting mid-window starts the event with the
	    window's real startedAt/endsAt. A handler registered after its window started runs once.
	  - trigger(id, by?) -> boolean: start now for durationSec; false for unknown ids or when active.
	  - isActive(id), onEnded(id, fn) -> connection.
	  - On start: framework signal EventStarted, the handler (own thread), Blink EventState(id,
	    endsAt), framework replicated field activeEvents = { [id] = endsAt }, a toast to everyone
	    (and to players who load mid-event). On end: EventState(id, 0), activeEvents, EventEnded,
	    onEnded handlers.
	  - AdminTriggerEvent (framework Blink event): ServerConfig.admins only (everyone in Studio).
	  - Console: `events event [id]` triggers now; no id lists events and their next start.

	Events.new(opts): opts.config (GameConfig.events), opts.now, opts.spawn, opts.log,
	opts.feedback(player, kind, text), opts.players() -> { Player }, opts.fireState(id, endsAt),
	opts.replicateAll(snapshot), opts.signals ({ EventStarted, EventEnded }), opts.isAdmin(player).
]]

local Schedule = require(script.Schedule)

local Events = {}

Events.TICK_SECONDS = 1
Events.MAX_ID_LENGTH = 64

function Events.new(opts: any): any
	local defsTable: { [string]: any } = opts.config or {}
	local now: () -> number = opts.now
	local spawn: (...any) -> () = opts.spawn
	local log: (string) -> () = opts.log

	local handlers: { [string]: { owner: string, fn: (any) -> () } } = {}
	local overrides: { [string]: any } = {}
	local ended: { [string]: { (any) -> () } } = {}
	local active: { [string]: any } = {}
	local handlerRan: { [string]: boolean } = {}
	local lastWindow: { [string]: number } = {}
	local acc = 0
	local running = false

	local e: any = {}

	local function scheduleOf(id: string): any
		local s = overrides[id]
		if s then
			return s
		end
		local def = defsTable[id]
		if def and def.schedule and Schedule.validate(def.schedule) == nil then
			return def.schedule
		end
		return nil
	end

	local function replicate()
		local snapshot: { [string]: number } = {}
		for id, ectx in active do
			snapshot[id] = ectx.endsAt
		end
		opts.replicateAll(snapshot)
	end

	local function runHandler(id: string, ectx: any)
		local h = handlers[id]
		if h and not handlerRan[id] then
			handlerRan[id] = true
			spawn(h.fn, ectx)
		end
	end

	local function toastAll(text: string)
		for _, player in opts.players() do
			pcall(opts.feedback, player, "toast", text)
		end
	end

	local function startEvent(id: string, startedAt: number, endsAt: number, by: any?)
		local def = defsTable[id]
		local ectx = table.freeze({
			id = id,
			startedAt = startedAt,
			endsAt = endsAt,
			data = def and def.data,
			triggeredBy = by,
		})
		active[id] = ectx
		handlerRan[id] = nil
		replicate()
		pcall(opts.fireState, id, endsAt)
		opts.signals.EventStarted:Fire(ectx)
		runHandler(id, ectx)
		toastAll(id .. " is live!")
	end

	local function endEvent(id: string)
		local ectx = active[id]
		if ectx == nil then
			return
		end
		active[id] = nil
		handlerRan[id] = nil
		replicate()
		pcall(opts.fireState, id, 0)
		opts.signals.EventEnded:Fire(ectx)
		for _, fn in table.clone(ended[id] or {}) do
			spawn(fn, ectx)
		end
	end

	function e.check(t: number)
		for id, ectx in table.clone(active) do
			if t >= ectx.endsAt then
				endEvent(id)
			end
		end
		for id, def in defsTable do
			if active[id] == nil then
				local s = scheduleOf(id)
				if s then
					local startedAt, endsAt = Schedule.activeWindow(s, def.durationSec, t)
					if startedAt and endsAt and lastWindow[id] ~= startedAt then
						lastWindow[id] = startedAt
						startEvent(id, startedAt, endsAt, nil)
					end
				end
			end
		end
	end

	-- Framework start: validate schedules, publish the (empty) active set, first check now.
	function e.start()
		for id, def in defsTable do
			if def.schedule and Schedule.validate(def.schedule) ~= nil then
				log(`[StudWork.Events] events.{id}.schedule invalid: {Schedule.validate(def.schedule)}`)
			end
		end
		replicate()
		running = true
		e.check(now())
	end

	function e.tick(dt: number)
		if not running then
			return
		end
		acc += dt
		if acc >= Events.TICK_SECONDS then
			acc = 0
			e.check(now())
		end
	end

	function e.trigger(id: string, by: any?): boolean
		if type(id) ~= "string" then
			return false
		end
		local def = defsTable[id]
		if def == nil or active[id] ~= nil then
			return false
		end
		if
			type(def.durationSec) ~= "number"
			or def.durationSec ~= def.durationSec
			or def.durationSec <= 0
		then
			log(`[StudWork.Events] events.{id}.durationSec must be > 0`)
			return false
		end
		local t = now()
		startEvent(id, t, t + def.durationSec, by)
		return true
	end

	function e.isActive(id: string): boolean
		return active[id] ~= nil
	end

	function e.activeList(): { [string]: any }
		return table.clone(active)
	end

	function e.onPlayerLoaded(player: any)
		for id in active do
			pcall(opts.feedback, player, "toast", id .. " is live!")
		end
	end

	function e.adminTrigger(player: any, eventId: any)
		if type(eventId) ~= "string" or #eventId == 0 or #eventId > Events.MAX_ID_LENGTH then
			return
		end
		if not opts.isAdmin(player) then
			return
		end
		if defsTable[eventId] == nil then
			return
		end
		e.trigger(eventId, player)
	end

	function e.consoleList(): string
		local lines = { "events:" }
		local t = now()
		for id, def in defsTable do
			local s = scheduleOf(id)
			local nextText = if s then `next start in {Schedule.nextStart(s, t) - t}s` else "manual only"
			local state = if active[id] then `ACTIVE until {active[id].endsAt}` else nextText
			table.insert(lines, `  {id} ({def.durationSec}s): {state}`)
		end
		return table.concat(lines, "\n")
	end

	function e.forModule(owner: string): any
		return table.freeze({
			schedule = function(id: string, schedule: any?, handler: (any) -> ())
				if type(id) ~= "string" then
					error("ctx.events.schedule: id must be a string", 2)
				end
				if type(handler) ~= "function" then
					error("ctx.events.schedule: handler must be a function", 2)
				end
				local existing = handlers[id]
				if existing ~= nil and existing.owner ~= owner then
					error(`ctx.events.schedule('{id}'): already scheduled by {existing.owner}`, 2)
				end
				if defsTable[id] == nil then
					log(
						`[StudWork.Events] schedule('{id}'): not in GameConfig.events (needs durationSec); trigger will refuse it`
					)
				end
				if schedule ~= nil then
					local problem = Schedule.validate(schedule)
					if problem ~= nil then
						error(`ctx.events.schedule('{id}'): {problem}`, 2)
					end
					overrides[id] = schedule
				end
				handlers[id] = { owner = owner, fn = handler }
				local ectx = active[id]
				if ectx then
					runHandler(id, ectx) -- window already running (server booted mid-window)
				end
			end,
			trigger = e.trigger,
			isActive = e.isActive,
			onEnded = function(id: string, fn: (any) -> ()): any
				assert(type(fn) == "function", "ctx.events.onEnded: handler must be a function")
				ended[id] = ended[id] or {}
				table.insert(ended[id], fn)
				local conn: any = { Connected = true }
				function conn.Disconnect(c: any)
					c.Connected = false
					local list = ended[id]
					local i = list and table.find(list, fn)
					if i then
						table.remove(list, i)
					end
				end
				return conn
			end,
		})
	end

	return e
end

return Events
