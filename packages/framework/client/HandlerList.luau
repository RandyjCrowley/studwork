--!strict
--[[
	Tiny handler list used by on*/onReturn/onDaily style registration APIs. Pure.
	add() returns a Types.Connection; fire() runs each handler in its own thread (task.spawn
	when available, so one failing handler never blocks the others).
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"):WaitForChild("Types"))

export type HandlerList = {
	add: (self: HandlerList, fn: (...any) -> ()) -> Types.Connection,
	fire: (self: HandlerList, ...any) -> (),
	count: (self: HandlerList) -> number,
}

local HandlerList = {}

function HandlerList.new(): HandlerList
	local handlers: { (...any) -> () } = {}
	local list = {}

	function list.add(_self: HandlerList, fn: (...any) -> ()): Types.Connection
		table.insert(handlers, fn)
		local connection = { Connected = true }
		function connection.Disconnect(conn: any)
			if not conn.Connected then
				return
			end
			conn.Connected = false
			local index = table.find(handlers, fn)
			if index then
				table.remove(handlers, index)
			end
		end
		return (connection :: any) :: Types.Connection
	end

	function list.fire(_self: HandlerList, ...: any)
		for _, fn in table.clone(handlers) do
			task.spawn(fn, ...)
		end
	end

	function list.count(_self: HandlerList): number
		return #handlers
	end

	return (list :: any) :: HandlerList
end

return HandlerList
