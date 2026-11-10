--!strict
--[[
	Core.Friends. OWNED BY AGENT E (core/e-meta). Public API: Types.FriendsAPI.

	PHASE 0 STUB: on join, checks IsFriendsWith against everyone in the server and fires
	onCoPlay(player, friends, "server") when any are found. Agent E: periodic re-check,
	invite joins (GetJoinData / launch data from an invite), private servers (PrivateServerId),
	the co-play multiplier, a Studio mock friend for solo testing, caching (IsFriendsWith yields).
]]

local Players = game:GetService("Players")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local HandlerList =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("HandlerList"))

local Friends = {}

local ctx: any = nil
local handlers = HandlerList.new()

function Friends.init(context: any)
	ctx = context
end

function Friends.friendsInServer(player: Player): { Player }
	local list = {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local ok, isFriend = pcall(function()
				return player:IsFriendsWithAsync(other.UserId)
			end)
			if ok and isFriend then
				table.insert(list, other)
			end
		end
	end
	return list
end

function Friends.start()
	ctx.services.Data.onLoaded(function(player: Player)
		local friends = Friends.friendsInServer(player)
		if #friends > 0 then
			ctx.signals.CoPlay:Fire(player, friends, "server")
			handlers:fire(player, friends, "server")
		end
	end)
end

function Friends.onCoPlay(
	handler: (player: Player, friends: { Player }, kind: Types.CoPlayKind) -> ()
): Types.Connection
	return handlers:add(handler)
end

return Friends
