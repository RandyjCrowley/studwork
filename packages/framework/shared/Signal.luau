--!strict
--[[
	Tiny synchronous signal (pure). Handlers run in connection order inside pcall, so one failing
	listener never stops the others. State lives in a closure, so the object itself can be frozen.
]]

local Signal = {}

export type Connection = { Disconnect: (self: Connection) -> (), Connected: boolean }
export type Signal = {
	Connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	Once: (self: Signal, fn: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	name: string,
}

function Signal.new(name: string): Signal
	local handlers: { { fn: (...any) -> (), alive: boolean } } = {}
	local self: any = { name = name }
	function self.Connect(_: any, fn: (...any) -> ()): Connection
		assert(type(fn) == "function", `{name}:Connect expects a function`)
		local h = { fn = fn, alive = true }
		table.insert(handlers, h)
		local conn: any = { Connected = true }
		function conn.Disconnect(c: any)
			h.alive = false
			c.Connected = false
			local i = table.find(handlers, h)
			if i then
				table.remove(handlers, i)
			end
		end
		return conn
	end
	function self.Once(s: any, fn: (...any) -> ()): Connection
		local conn: any
		conn = s:Connect(function(...)
			conn:Disconnect()
			fn(...)
		end)
		return conn
	end
	function self.Fire(_: any, ...: any)
		for _, h in table.clone(handlers) do
			if h.alive then
				local ok, err = pcall(h.fn :: any, ...)
				if not ok then
					warn(`[StudWork] signal {name} handler failed: {tostring(err)}`)
				end
			end
		end
	end
	return table.freeze(self) :: Signal
end

return Signal
