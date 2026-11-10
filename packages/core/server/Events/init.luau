--!strict
--[[
	Core.Events. OWNED BY AGENT E (core/e-meta). Public API: Types.EventsAPI.

	Live events defined in GameConfig.events[id] = { schedule?, durationSec, data? }.

	  - schedule(id, schedule?, handler): sets the handler and (optionally) overrides the config
	    schedule. Every config event with a schedule runs on the timer even without a handler.
	    Schedules are UTC (Types.EventSchedule: weekday 1 = Sunday..7 or nil = daily, hourUtc,
	    minuteUtc). Windows come from Schedule.luau and depend only on os.time(), so every server
	    agrees: a server that boots mid-window starts the event with the window's real
	    startedAt/endsAt (remaining duration only). A handler registered after its window already
	    started still runs once.
	  - trigger(id, by?): starts the event now for durationSec. Refused (false) for unknown ids or
	    when the event is already active.
	  - isActive(id), onEnded(id, handler).
	  - On start: EventStarted signal, handler (own thread), Blink EventState.FireAll(id, endsAt),
	    activeEvents replicated (ctx.setReplicatedAll("activeEvents", { [id] = endsAt })), "toast"
	    to everyone (and to players who load mid-event). On end: EventState.FireAll(id, 0),
	    replicate, EventEnded signal, onEnded handlers.
	  - AdminTriggerEvent remote: eventId must be a known event id string; player.UserId must be in
	    GameConfig.admins (in Studio everyone is allowed).
	  - Console: `event <id>` triggers now; `event` lists events and their next start.
]]

local Players = game:GetService("Players")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local HandlerList =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("HandlerList"))
local Schedule = require(script.Schedule)

local TICK_SECONDS = 1
local MAX_ID_LENGTH = 64

local Events = {}

local ctx: any = nil
local handlers: { [string]: (Types.EventContext) -> () } = {}
local scheduleOverrides: { [string]: Types.EventSchedule } = {}
local endedHandlers: { [string]: HandlerList.HandlerList } = {}
local active: { [string]: Types.EventContext } = {}
local handlerRan: { [string]: boolean } = {}
local lastWindow: { [string]: number } = {}

local function defs(): Types.EventsConfig
	return ctx.config.events or {}
end

local function scheduleOf(id: string): Types.EventSchedule?
	local s = scheduleOverrides[id]
	if s then
		return s
	end
	local def = defs()[id]
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
	pcall(ctx.setReplicatedAll, "activeEvents", snapshot)
end

local function fireState(id: string, endsAt: number)
	pcall(function()
		ctx.net.events.EventState.FireAll(id, endsAt)
	end)
end

local function runHandler(id: string, ectx: Types.EventContext)
	local handler = handlers[id]
	if handler and not handlerRan[id] then
		handlerRan[id] = true
		task.spawn(handler, ectx)
	end
end

local function toastAll(text: string)
	for _, player in Players:GetPlayers() do
		pcall(ctx.net.feedback, player, "toast", text)
	end
end

local function startEvent(id: string, startedAt: number, endsAt: number, by: Player?)
	local def = defs()[id]
	local ectx: Types.EventContext = {
		id = id,
		startedAt = startedAt,
		endsAt = endsAt,
		data = def and def.data,
		triggeredBy = by,
	}
	active[id] = ectx
	handlerRan[id] = nil
	replicate()
	fireState(id, endsAt)
	ctx.signals.EventStarted:Fire(ectx)
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
	fireState(id, 0)
	ctx.signals.EventEnded:Fire(ectx)
	local list = endedHandlers[id]
	if list then
		list:fire(ectx)
	end
end

local function tick(now: number)
	for id, ectx in table.clone(active) do
		if now >= ectx.endsAt then
			endEvent(id)
		end
	end
	for id, def in defs() do
		if active[id] == nil then
			local s = scheduleOf(id)
			if s then
				local startedAt, endsAt = Schedule.activeWindow(s, def.durationSec, now)
				if startedAt and endsAt and lastWindow[id] ~= startedAt then
					lastWindow[id] = startedAt
					startEvent(id, startedAt, endsAt, nil)
				end
			end
		end
	end
end

local function isAdmin(player: Player): boolean
	if ctx.isStudio then
		return true
	end
	local admins = ctx.config.admins
	return admins ~= nil and table.find(admins, player.UserId) ~= nil
end

local function consoleEvent(id: any): string?
	if type(id) ~= "string" then
		local lines = { "events:" }
		local now = os.time()
		for eventId, def in defs() do
			local s = scheduleOf(eventId)
			local nextText = if s then `next start in {Schedule.nextStart(s, now) - now}s` else "manual only"
			local state = if active[eventId] then `ACTIVE until {active[eventId].endsAt}` else nextText
			table.insert(lines, `  {eventId} ({def.durationSec}s): {state}`)
		end
		return table.concat(lines, "\n")
	end
	if defs()[id] == nil then
		return "unknown event " .. id
	end
	if Events.trigger(id, Players:GetPlayers()[1]) then
		return `started {id} until {active[id].endsAt}`
	end
	return id .. " is already active"
end

function Events.init(context: any)
	ctx = context
end

function Events.start()
	for id, def in defs() do
		if def.schedule and Schedule.validate(def.schedule) ~= nil then
			warn(`[Core.Events] events.{id}.schedule invalid: {Schedule.validate(def.schedule)}`)
		end
	end

	ctx.net.handle("AdminTriggerEvent", function(player: Player, eventId: any)
		if type(eventId) ~= "string" or #eventId == 0 or #eventId > MAX_ID_LENGTH then
			return
		end
		if not isAdmin(player) then
			return
		end
		if defs()[eventId] == nil then
			return
		end
		Events.trigger(eventId, player)
	end)

	ctx.services.Data.onLoaded(function(player: Player)
		for id in active do
			pcall(ctx.net.feedback, player, "toast", id .. " is live!")
		end
	end)

	ctx.console.register("event", "event [id]: trigger an event now (no id = list events)", consoleEvent)

	replicate()
	task.spawn(function()
		task.wait() -- let the game register schedule() handlers first
		while true do
			tick(os.time())
			task.wait(TICK_SECONDS)
		end
	end)
end

function Events.schedule(id: string, schedule: Types.EventSchedule?, handler: (ctx: Types.EventContext) -> ())
	assert(type(id) == "string", "[Core.Events] schedule id must be a string")
	assert(type(handler) == "function", "[Core.Events] schedule handler must be a function")
	if defs()[id] == nil then
		warn(
			`[Core.Events] schedule('{id}'): not in GameConfig.events (needs durationSec); trigger will refuse it`
		)
	end
	if schedule ~= nil then
		local problem = Schedule.validate(schedule)
		assert(problem == nil, `[Core.Events] schedule('{id}'): {problem}`)
		scheduleOverrides[id] = schedule
	end
	handlers[id] = handler
	local ectx = active[id]
	if ectx then
		runHandler(id, ectx) -- window already running (server booted mid-window)
	end
end

function Events.trigger(id: string, by: Player?): boolean
	if type(id) ~= "string" then
		return false
	end
	local def = defs()[id]
	if def == nil or active[id] ~= nil then
		return false
	end
	if type(def.durationSec) ~= "number" or def.durationSec ~= def.durationSec or def.durationSec <= 0 then
		warn(`[Core.Events] events.{id}.durationSec must be > 0`)
		return false
	end
	local now = os.time()
	startEvent(id, now, now + def.durationSec, by)
	return true
end

function Events.isActive(id: string): boolean
	return active[id] ~= nil
end

function Events.onEnded(id: string, handler: (ctx: Types.EventContext) -> ()): Types.Connection
	endedHandlers[id] = endedHandlers[id] or HandlerList.new()
	return endedHandlers[id]:add(handler)
end

return Events
