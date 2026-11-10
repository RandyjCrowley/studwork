--!strict
--[[
	Bounded FIFO for client requests that arrive before Core.start registered the handlers (L3).
	Pure. Blink's own pre-listener queue is unbounded, so Net listens from require time and parks
	early requests here instead. When full, new requests are dropped and onFull fires ONCE.
]]

local PendingQueue = {}
PendingQueue.__index = PendingQueue

export type Entry = { eventName: string, player: any, args: { n: number, [number]: any } }

export type PendingQueue = typeof(setmetatable(
	{} :: { cap: number, items: { Entry }, dropped: number, warned: boolean, onFull: (cap: number) -> () },
	PendingQueue
))

function PendingQueue.new(cap: number, onFull: (cap: number) -> ()): PendingQueue
	assert(type(cap) == "number" and cap >= 0, "[Core.Net] PendingQueue cap must be >= 0")
	return setmetatable({ cap = cap, items = {}, dropped = 0, warned = false, onFull = onFull }, PendingQueue)
end

-- Returns false when the request was dropped because the queue is full.
function PendingQueue.push(self: PendingQueue, eventName: string, player: any, ...: any): boolean
	if #self.items >= self.cap then
		self.dropped += 1
		if not self.warned then
			self.warned = true
			self.onFull(self.cap)
		end
		return false
	end
	table.insert(self.items, { eventName = eventName, player = player, args = table.pack(...) })
	return true
end

-- Removes and returns every queued entry in arrival order.
function PendingQueue.drain(self: PendingQueue): { Entry }
	local items = self.items
	self.items = {}
	return items
end

function PendingQueue.size(self: PendingQueue): number
	return #self.items
end

return PendingQueue
