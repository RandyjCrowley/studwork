--!nocheck
--[[
	FakeSignal for the simulation: every connected handler runs in its OWN scheduler thread
	(owned by the signal's server), like RBXScriptSignal. Firing never runs handlers on the
	firing thread's stack, so "shutdown while a save is in flight" style races stay observable.
	Each signal keeps a history of fired argument packs for assertions.
]]

local Signal = {}
Signal.__index = Signal

function Signal.new(scheduler: any, owner: any, name: string?)
	return setmetatable({
		scheduler = scheduler,
		owner = owner,
		name = name or "Signal",
		handlers = {},
		waiting = {},
		history = {},
	}, Signal)
end

function Signal.Connect(self, fn: (...any) -> ())
	local connection = { Connected = true }
	local entry = { fn = fn, connection = connection }
	table.insert(self.handlers, entry)
	function connection.Disconnect(conn)
		conn.Connected = false
		local index = table.find(self.handlers, entry)
		if index then
			table.remove(self.handlers, index)
		end
	end
	return connection
end

function Signal.Once(self, fn: (...any) -> ())
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal.Fire(self, ...)
	table.insert(self.history, table.pack(...))
	for _, entry in table.clone(self.handlers) do
		if entry.connection.Connected then
			self.scheduler:spawn(self.owner, entry.fn, ...)
		end
	end
	local waiting = self.waiting
	self.waiting = {}
	for _, thread in waiting do
		self.scheduler:spawn(self.owner, thread, ...)
	end
end

function Signal.Wait(self)
	table.insert(self.waiting, coroutine.running())
	return coroutine.yield()
end

function Signal.count(self): number
	return #self.history
end

return Signal
