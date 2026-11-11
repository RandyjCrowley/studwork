--!nocheck
-- Stand-in for a generated Blink module (Lune has no Blink wire): one event per action.
local log = {}
return {
	log = log,
	Ping = {
		Fire = function(...)
			table.insert(log, table.pack(...))
		end,
	},
}
