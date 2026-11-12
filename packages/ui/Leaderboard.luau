--!strict
--[[
	UI.Leaderboard (docs/framework/kits/leaderboards.md, "Client part and UI"): a ranked list.

	props: { title: string, rows: { { rank, userId, name, value } }, selfUserId: number?,
	         selfValue: number?, selfRank: number?, format: "number" | "time"?, emptyText: string? }

	Theme tokens only (rows from colors.surface / surfaceAlt, the player's own row colors.leaderboardSelf,
	which is in the base theme so this works without the module that feeds it); names are rendered with
	AutoLocalize = false; every label goes through UI.text.

	STUB (foundation): the export and its props exist and the component renders nothing. The
	leaderboards builder (B4) implements it.
]]

export type Row = { rank: number, userId: number, name: string, value: number }
export type Props = {
	title: string,
	rows: { Row },
	selfUserId: number?,
	selfValue: number?,
	selfRank: number?,
	format: ("number" | "time")?,
	emptyText: string?,
}

local function Leaderboard(_props: Props): any
	return nil -- STUB (B4)
end

return Leaderboard
