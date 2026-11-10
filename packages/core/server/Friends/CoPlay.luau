--!strict
--[[
	Pure co-play helpers (no Roblox globals). Owned by agent E.

	kind(referredBy, friendIds, isPrivate):
	  "invite"  when the player joined through an invite/share link (GetJoinData().ReferredByPlayerId)
	            and the referrer is one of the friends currently in the server
	  "private" when the server is a private (VIP) server (game.PrivateServerOwnerId ~= 0)
	  "server"  otherwise (friends met in a public server)

	gained(prev, now): ids present in `now` but not in `prev` (sorted), so co-play hooks fire only
	when the friend set gains someone, not every check interval.

	pairKey(a, b): order-independent cache key for an IsFriendsWithAsync result.
]]

local CoPlay = {}

export type Kind = "server" | "invite" | "private"

function CoPlay.kind(referredBy: number?, friendIds: { number }, isPrivate: boolean): Kind
	if type(referredBy) == "number" and referredBy > 0 and table.find(friendIds, referredBy) ~= nil then
		return "invite"
	end
	if isPrivate then
		return "private"
	end
	return "server"
end

function CoPlay.gained(prev: { [number]: boolean }, now: { [number]: boolean }): { number }
	local out = {}
	for id in now do
		if not prev[id] then
			table.insert(out, id)
		end
	end
	table.sort(out)
	return out
end

function CoPlay.pairKey(a: number, b: number): string
	if a > b then
		a, b = b, a
	end
	return tostring(a) .. ":" .. tostring(b)
end

return CoPlay
