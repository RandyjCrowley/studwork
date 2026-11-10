--!strict
--[[
	Core.Events. OWNED BY AGENT E (core/e-meta). Public API: Types.EventsAPI.

	PHASE 0 STUB: schedule() stores the handler; trigger() runs it now for durationSec and
	replicates activeEvents; AdminTriggerEvent checks GameConfig.admins. No time-based scheduler
	yet. Agent E: UTC weekday/hour scheduler (pure "next start" math + tests), console trigger
	(_G / BindableFunction for the Studio command bar), Studio admin allowance, EventState fires.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local HandlerList =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("HandlerList"))

local Events = {}

local ctx: any = nil
local handlers: { [string]: (Types.EventContext) -> () } = {}
local schedules: { [string]: Types.EventSchedule? } = {}
local endedHandlers: { [string]: HandlerList.HandlerList } = {}
local active: { [string]: Types.EventContext } = {}

local function replicate()
	local snapshot = {}
	for id, ectx in active do
		snapshot[id] = ectx.endsAt
	end
	ctx.setReplicatedAll("activeEvents", snapshot)
end

function Events.init(context: any)
	ctx = context
end

function Events.start()
	ctx.net.handle("AdminTriggerEvent", function(player: Player, eventId: string)
		local admins = ctx.config.admins or {}
		if table.find(admins, player.UserId) == nil then
			return
		end
		Events.trigger(eventId, player)
	end)
	replicate()
end

function Events.schedule(id: string, schedule: Types.EventSchedule?, handler: (ctx: Types.EventContext) -> ())
	handlers[id] = handler
	schedules[id] = schedule or (ctx.config.events[id] and ctx.config.events[id].schedule)
end

function Events.trigger(id: string, by: Player?): boolean
	local def = ctx.config.events[id]
	if def == nil or active[id] then
		return false
	end
	local now = os.time()
	local ectx: Types.EventContext = {
		id = id,
		startedAt = now,
		endsAt = now + def.durationSec,
		data = def.data,
		triggeredBy = by,
	}
	active[id] = ectx
	replicate()
	ctx.signals.EventStarted:Fire(ectx)
	local handler = handlers[id]
	if handler then
		task.spawn(handler, ectx)
	end
	task.delay(def.durationSec, function()
		active[id] = nil
		replicate()
		ctx.signals.EventEnded:Fire(ectx)
		if endedHandlers[id] then
			endedHandlers[id]:fire(ectx)
		end
	end)
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
