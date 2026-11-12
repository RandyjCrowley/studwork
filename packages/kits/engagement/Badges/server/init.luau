--!strict
--[[
	Badges: the server part (docs/framework/kits/badges.md).

	FOUNDATION SKELETON: a valid, empty part. `api` records and sends nothing, so a game can list
	the module and boot. The badges and text builder (B5) implements the page: record then queue,
	the send thread within budget.perMinute, ownership checks at join, the triggers on the optional
	modules' signals, retries, console commands and the Awarded event.
]]

local Badges = {}

function Badges.init(_context: any) end -- STUB (B5)

function Badges.start(_context: any) end -- STUB (B5)

Badges.api = {
	-- STUB (B5)
	award = function(_player: any, _key: string): boolean
		return false
	end,
	has = function(_player: any, _key: string): boolean
		return false
	end,
}

Badges.txApi = {
	award = function(_tx: any, _key: string): boolean
		return false -- STUB (B5)
	end,
}

return Badges
