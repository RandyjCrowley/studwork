--!strict
--[[
	Pure odds replication planning for Core.Rarity (zero requires).

	Scheme: every client gets the SHARED map (luck-free details, luck = 1) through
	ctx.setReplicatedAll("odds", shared). A player gets a per-player override
	(ctx.setReplicated(player, "odds", merged)) only while their luck differs from 1 on at least
	one luckDisclosed table in the shared map; the override is the shared map with those tables
	replaced by the player's luck-adjusted details. When that is no longer true the override is
	cleared with nil (Snapshot.build then falls back to the shared value).

	playerOdds(shared, luckFor, detailFor) -> merged map, or nil when no override is needed.
		luckFor(tableId) -> the player's effective luck for that table
		detailFor(tableId) -> the player's luck-adjusted OddsDetail (Rarity.getOddsDetail(id, player))
]]

local OddsSync = {}

function OddsSync.playerOdds(
	shared: { [string]: any },
	luckFor: (tableId: string) -> number,
	detailFor: (tableId: string) -> any
): { [string]: any }?
	local merged: { [string]: any }? = nil
	for tableId, detail in shared do
		if type(detail) == "table" and detail.luckDisclosed == true and luckFor(tableId) ~= 1 then
			local own = detailFor(tableId)
			if own ~= nil then
				local out: { [string]: any } = merged or table.clone(shared)
				out[tableId] = own
				merged = out
			end
		end
	end
	return merged
end

return OddsSync
