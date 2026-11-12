--!strict
--[[
	Leaderboards: the server part (docs/framework/kits/leaderboards.md).

	FOUNDATION SKELETON: a valid, empty part. `api` answers with empty boards and refuses every
	submit, so a game can list the module and boot. The leaderboards builder (B4) implements the
	page: idempotent writes (`max(old, total)`, never increment), the shared top item with a reader
	lease, refresh paced by ctx.data.census(), shards, cutToTop, replication of boards and mine.
]]

local Leaderboards = {}

function Leaderboards.init(_context: any) end -- STUB (B4)

function Leaderboards.start(_context: any) end -- STUB (B4)

Leaderboards.api = {
	-- STUB (B4)
	submit = function(_player: any, _boardId: string, _value: number): boolean
		return false
	end,
	top = function(_boardId: string, _previous: boolean?): any
		return table.freeze({ rows = table.freeze({}), updatedAt = 0 })
	end,
	rank = function(_player: any, _boardId: string): (number?, number)
		return nil, 0
	end,
	refresh = function(_boardId: string): boolean
		return false
	end,
}

Leaderboards.txApi = {
	submit = function(_tx: any, _boardId: string, _value: number): boolean
		return false -- STUB (B4)
	end,
}

return Leaderboards
