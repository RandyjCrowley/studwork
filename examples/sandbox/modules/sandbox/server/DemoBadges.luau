--!strict
--[[
	Sandbox demo hook for the Badges module (docs/framework/kits/badges.md): award a manual badge and log BadgeAwarded.

	FOUNDATION STUB: required from server/init.luau, which calls `init(ctx)` and `start(ctx)`.
	Both do nothing yet; the Badges builder (B5) owns this file and fills them in (check
	`ctx.isEnabled(<module ref>)` first: the sandbox may run without the module).
]]

local DemoBadges = {}

function DemoBadges.init(_ctx: any) end -- STUB (B5)

function DemoBadges.start(_ctx: any) end -- STUB (B5)

return DemoBadges
