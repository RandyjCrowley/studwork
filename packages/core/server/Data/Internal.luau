--!strict
--[[
	Private bridge between Core.Data and Core.Mail (both owned by agent A). NOT a public API:
	other services must use ctx.services.Data / ctx.services.Mail.

	Data publishes the ProfileStore it chose (real or Mock) and calls Internal.deliver for every
	ProfileStore message of a loaded profile; Mail installs Internal.deliver and uses getStore().
]]

local Internal = {}

Internal.store = nil :: any -- ProfileStore (or its .Mock) once chosen by Data.start
Internal.isMock = false

-- Mail sets this. Return true when the message was consumed (marks it processed).
Internal.deliver = nil :: ((player: Player, message: any) -> boolean)?

-- Yields until Data has chosen a store (or `timeout` seconds pass). Returns nil on timeout.
function Internal.waitStore(timeout: number): any
	local deadline = os.clock() + timeout
	while Internal.store == nil and os.clock() < deadline do
		task.wait(0.1)
	end
	return Internal.store
end

-- Data sets this: profile save nudge for a loaded player (speeds up in-server mail delivery).
Internal.nudgeSave = nil :: ((userId: number) -> ())?

return Internal
