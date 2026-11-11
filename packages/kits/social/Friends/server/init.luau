--!strict
--[[
	Friends: the social kit's server module (core-v1.3.0 module API). README.md has the details.

	Detects Roblox friends playing in the same server:
	  - when a player's data loads (for them and for everyone already here) and every
	    config.friends.checkIntervalSec for everyone loaded (the framework's shared ticker).
	  - player:IsFriendsWithAsync results are cached per pair (pcall; failures are retried on the
	    next check, not cached), deduped in flight (PairDedupe, L4).
	  - co-play kind (CoPlay.kind): "invite" when GetJoinData().ReferredByPlayerId is a friend in
	    the server, "private" in a private (VIP) server, else "server".
	  - api.signals.CoPlay(player, friends, kind) fires (and onCoPlay handlers run) only when the
	    friend set GAINS someone.
	  - config.friends.coPlayMultiplier (optional) is applied through the OPTIONAL Economy
	    dependency (ctx.deps[Economy].addMultiplier(player, "coplay", mult)) while >= 1 friend is
	    present, removed with removeMultiplier when the last friend leaves.

	api: onCoPlay(handler) -> Connection, friendsInServer(player) -> { Player }, signals.CoPlay.
	Console (Studio): `friends coplay <server|invite|private> [userId]`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CoPlay = require(script.CoPlay)
local PairDedupe = require(script.PairDedupe)
local SignalTable = require(script.SignalTable)
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))

local MULTIPLIER_ID = "coplay"
local MIN_INTERVAL = 5 -- seconds; floor for a misconfigured checkIntervalSec
local FALLBACK_INTERVAL = 30

local Friends = {}

local ctx: any = nil
local signals = SignalTable.new()
local pairs_ = PairDedupe.new(function(thread: thread, ok: boolean, value: boolean?)
	task.spawn(thread, ok, value)
end, function(key: string): boolean
	-- cache only while both players are still here (key = "lowId:highId")
	local a, b = string.match(key, "^(%d+):(%d+)$")
	return a ~= nil
		and Players:GetPlayerByUserId(tonumber(a) :: number) ~= nil
		and Players:GetPlayerByUserId(tonumber(b) :: number) ~= nil
end)
local friendSets: { [Player]: { [number]: boolean } } = {}
local referredBy: { [Player]: number } = {}
local boosted: { [Player]: boolean } = {}
local busy: { [Player]: boolean } = {}

local function isPrivateServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId ~= 0
end

local function friendsConfig(): any
	local cfg = ctx.config.friends
	return if type(cfg) == "table" then cfg else {}
end

local function coPlayMultiplier(): number?
	local mult = friendsConfig().coPlayMultiplier
	if type(mult) == "number" and mult == mult and mult > 0 and mult ~= math.huge then
		return mult
	end
	return nil
end

local function checkInterval(): number
	local sec = friendsConfig().checkIntervalSec
	if type(sec) ~= "number" or sec ~= sec then
		return FALLBACK_INTERVAL
	end
	return math.max(sec, MIN_INTERVAL)
end

local function playersFrom(set: { [number]: boolean }): { Player }
	local list = {}
	for userId in set do
		local p = Players:GetPlayerByUserId(userId)
		if p then
			table.insert(list, p)
		end
	end
	table.sort(list, function(a, b)
		return a.UserId < b.UserId
	end)
	return list
end

local function applyMultiplier(player: Player)
	if not ctx.isEnabled(Economy) then
		return -- optional integration
	end
	local set = friendSets[player]
	local hasFriend = set ~= nil and next(set) ~= nil
	local mult = coPlayMultiplier()
	local economy = ctx.deps[Economy]
	if hasFriend and mult and not boosted[player] then
		boosted[player] = true
		local ok, err = pcall(economy.addMultiplier, player, MULTIPLIER_ID, mult)
		if not ok then
			ctx.log.warn("addMultiplier failed: " .. tostring(err))
		end
	elseif not hasFriend and boosted[player] then
		boosted[player] = nil
		local ok, err = pcall(economy.removeMultiplier, player, MULTIPLIER_ID)
		if not ok then
			ctx.log.warn("removeMultiplier failed: " .. tostring(err))
		end
	end
end

local function fireCoPlay(player: Player, friends: { Player }, kind: string)
	signals.CoPlay:Fire(player, friends, kind)
	local text = if #friends == 1
		then `Playing with {friends[1].DisplayName}!`
		else `Playing with {#friends} friends!`
	pcall(ctx.net.feedback, player, "toast", text)
	pcall(ctx.analytics.custom, player, "CoPlay_" .. kind, #friends)
end

local function areFriends(a: Player, b: Player): boolean?
	local ok, result = pairs_:get(CoPlay.pairKey(a.UserId, b.UserId), function(): boolean
		return a:IsFriendsWithAsync(b.UserId)
	end)
	if not ok then
		return nil -- unknown; retry next check
	end
	return result == true
end

local function recompute(player: Player)
	if busy[player] or player.Parent ~= Players then
		return
	end
	busy[player] = true
	local prev = friendSets[player] or {}
	local now: { [number]: boolean } = {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local friends = areFriends(player, other)
			if friends == nil then
				friends = prev[other.UserId] == true -- keep the last known state on API failure
			end
			if friends and other.Parent == Players then
				now[other.UserId] = true
			end
		end
	end
	busy[player] = nil
	if player.Parent ~= Players then
		return
	end
	friendSets[player] = now
	applyMultiplier(player)
	local gained = CoPlay.gained(prev, now)
	if #gained > 0 then
		local ids = {}
		for id in now do
			table.insert(ids, id)
		end
		fireCoPlay(player, playersFrom(now), CoPlay.kind(referredBy[player], ids, isPrivateServer()))
	end
end

local function readJoinData(player: Player)
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	-- ReferredByPlayerId is documented on Player:GetJoinData but missing from luau-lsp's defs
	local referrer = if ok and type(joinData) == "table" then (joinData :: any).ReferredByPlayerId else nil
	if type(referrer) == "number" then
		referredBy[player] = referrer
	end
end

local function onRemoving(leaver: Player)
	friendSets[leaver] = nil
	referredBy[leaver] = nil
	boosted[leaver] = nil
	busy[leaver] = nil
	pairs_:forgetUser(leaver.UserId)
	for player, set in friendSets do
		if set[leaver.UserId] then
			set[leaver.UserId] = nil
			applyMultiplier(player)
		end
	end
end

function Friends.init(context: any)
	ctx = context
	signals.CoPlay = ctx.signals.new("CoPlay")
	ctx.console.register("coplay", function(_player: any, ...: any): string
		if not ctx.isStudio then
			return "friends coplay is Studio-only"
		end
		local args = { ... }
		local kind = args[1]
		if kind ~= "server" and kind ~= "invite" and kind ~= "private" then
			return "usage: friends coplay <server|invite|private> [userId]"
		end
		local last = tonumber(args[#args])
		local player = (last and Players:GetPlayerByUserId(last)) or Players:GetPlayers()[1]
		if player == nil then
			return "no player in server"
		end
		local mock = {}
		for _, other in Players:GetPlayers() do
			if other ~= player then
				table.insert(mock, other)
			end
		end
		if #mock == 0 then
			mock = { player }
		end
		fireCoPlay(player, mock, kind)
		return `fired co-play ({kind}) for {player.Name} with {#mock} mock friend(s)`
	end, "friends coplay <server|invite|private> [userId]: fire the co-play hook with mock friends (Studio)")
end

function Friends.start(_context: any)
	Players.PlayerAdded:Connect(readJoinData)
	for _, p in Players:GetPlayers() do
		readJoinData(p)
	end
	ctx.lifecycle.onPlayerRemoving(onRemoving)
	ctx.lifecycle.onPlayerLoaded(function(player: Player)
		task.spawn(recompute, player)
		for _, other in Players:GetPlayers() do
			if other ~= player and friendSets[other] ~= nil then
				task.spawn(recompute, other)
			end
		end
	end)
	ctx.lifecycle.onTick(checkInterval(), function()
		for _, player in Players:GetPlayers() do
			if ctx.data.isLoaded(player) then
				task.spawn(recompute, player)
			end
		end
	end)
end

Friends.api = {
	friendsInServer = function(player: Player): { Player }
		local set = friendSets[player]
		return if set then playersFrom(set) else {}
	end,
	onCoPlay = function(handler: (player: Player, friends: { Player }, kind: string) -> ()): any
		return signals.CoPlay:Connect(handler)
	end,
	signals = signals,
}

return Friends
