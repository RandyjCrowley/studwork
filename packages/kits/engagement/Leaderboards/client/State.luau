--!strict
--[[
	Leaderboards client state readers (pure). Read this module's per-module client slice of the
	replicated state (module-api.md §10: state.modules.Leaderboards.extra):

	  State.ids(state) -> { string }             board ids, sorted
	  State.entry(state, boardId) -> Entry?      { period, periodId?, endsAt?, title, rows, updatedAt, previous? }
	  State.rows(state, boardId) -> { Row }      the rows ({} for an unknown board or unloaded state)
	  State.mine(state, boardId) -> { value, rank? }?   the local player's own value and rank
	  State.all(state) -> { { id, entry, mine? } }      every board, in id order, with the player's own line

	`title` is a string key (resolve it with UI.text). Nothing here can write: the server owns every value.
]]

local State = {}

export type Row = { rank: number, userId: number, name: string, value: number }
export type Entry = {
	period: string,
	periodId: string?,
	endsAt: number?,
	title: string,
	rows: { Row },
	updatedAt: number,
	previous: { periodId: string, rows: { Row } }?,
}
export type Mine = { value: number, rank: number? }

local NAME = "Leaderboards"

local function extra(state: any): any
	if type(state) ~= "table" or type(state.modules) ~= "table" then
		return nil
	end
	local slice = state.modules[NAME]
	return if type(slice) == "table" then slice.extra else nil
end

local function boards(state: any): { [string]: Entry }
	local e = extra(state)
	local b = if type(e) == "table" then e.boards else nil
	return if type(b) == "table" then b else {}
end

function State.ids(state: any): { string }
	local out = {}
	for id in boards(state) do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

function State.entry(state: any, boardId: string): Entry?
	local entry = boards(state)[boardId]
	return if type(entry) == "table" then entry else nil
end

function State.rows(state: any, boardId: string): { Row }
	local entry = State.entry(state, boardId)
	return if entry ~= nil and type(entry.rows) == "table" then entry.rows else {}
end

function State.mine(state: any, boardId: string): Mine?
	local e = extra(state)
	local mine = if type(e) == "table" and type(e.mine) == "table" then e.mine[boardId] else nil
	return if type(mine) == "table" and type(mine.value) == "number" then mine else nil
end

function State.all(state: any): { { id: string, entry: Entry, mine: Mine? } }
	local out = {}
	for _, id in State.ids(state) do
		table.insert(
			out,
			{ id = id, entry = (State.entry(state, id) :: any) :: Entry, mine = State.mine(state, id) }
		)
	end
	return out
end

return State
