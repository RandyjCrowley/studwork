--!strict
--[[
	Sandbox demo hook for the Notifications module (docs/framework/kits/notifications.md): suggest the opt-in at a good moment and schedule an 'eggReady' notification.

	FOUNDATION STUB: required from server/init.luau, which calls `init(ctx)` and `start(ctx)`.
	Both do nothing yet; the Notifications builder (B6) owns this file and fills them in (check
	`ctx.isEnabled(<module ref>)` first: the sandbox may run without the module).
]]

local DemoNotifications = {}

function DemoNotifications.init(_ctx: any) end -- STUB (B6)

function DemoNotifications.start(_ctx: any) end -- STUB (B6)

return DemoNotifications
