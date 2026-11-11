--!strict
--[[
	A module's `api.signals` table (engagement kit). The framework copies plain tables when it wraps a
	module's api (Extensions.wrapApi), so the signals table must exist, by identity, before init;
	the signals themselves are created in init with ctx.signals.new and assigned into it.
	`SignalTable.watch(t, fn(name, signal))` calls fn for every signal already in the table and
	every one assigned later.
]]

local SignalTable = {}

function SignalTable.new(): any
	local watchers: { (string, any) -> () } = {}
	local meta = {}
	function meta.__newindex(t: any, name: any, signal: any)
		rawset(t, name, signal)
		for _, fn in table.clone(watchers) do
			fn(name, signal)
		end
	end
	meta.__watch = function(t: any, fn: (string, any) -> ())
		table.insert(watchers, fn)
		for name, signal in t do
			fn(name, signal)
		end
	end
	return setmetatable({}, meta)
end

function SignalTable.watch(t: any, fn: (string, any) -> ())
	local meta = getmetatable(t)
	if type(meta) == "table" and type(meta.__watch) == "function" then
		meta.__watch(t, fn)
	end
end

return SignalTable
