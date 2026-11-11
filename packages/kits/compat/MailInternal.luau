--!strict
--[[
	COMPAT (Phase 2 deletes it). Was packages/core/server/Data/Internal.luau; moved here in
	core-v1.3.0 step 4b-IIb so nothing needs ServerScriptService.CoreServer any more.
	Private bridge between the v1.2 Mail kit service and its store: the compat Bridge (wireMail)
	installs `store` / `nudgeSave` over framework Data messages; Mail installs `deliver`.
	NOT a public API.
]]

local Internal = {}

Internal.store = nil :: any -- ProfileStore (or its .Mock) once chosen by Data.start
Internal.isMock = false

-- Mail sets this. Mail calls processed() when the message is consumed: every handler succeeded,
-- or it was a duplicate (idempotency key already seen), malformed, or dead-lettered. Not calling
-- it leaves the message queued (ProfileStore re-delivers it next session).
Internal.deliver = nil :: ((player: Player, message: any, processed: () -> ()) -> ())?

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
