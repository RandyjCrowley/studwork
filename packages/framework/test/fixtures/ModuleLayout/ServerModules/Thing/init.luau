--!nocheck
-- A server part (has init): used as is; its Net child becomes `net`.
return {
	init = function() end,
	actions = { ping = { handler = function() end } },
}
