--!strict
--[[
	Sandbox demo hook for the Leaderboards module (docs/framework/kits/leaderboards.md): submit a score, show the top rows and the player's own rank.

	FOUNDATION STUB: required from server/init.luau, which calls `init(ctx)` and `start(ctx)`.
	Both do nothing yet; the Leaderboards builder (B4) owns this file and fills them in (check
	`ctx.isEnabled(<module ref>)` first: the sandbox may run without the module).
]]

local DemoLeaderboards = {}

function DemoLeaderboards.init(_ctx: any) end -- STUB (B4)

function DemoLeaderboards.start(_ctx: any) end -- STUB (B4)

return DemoLeaderboards
