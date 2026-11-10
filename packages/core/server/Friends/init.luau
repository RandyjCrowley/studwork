--!strict
--[[
	Core.Friends. OWNED BY AGENT E (core/e-meta). Public API: Types.FriendsAPI.

	Detects Roblox friends playing in the same server:
	  - when a player's data loads (for them and for everyone already here) and every
	    balance.friends.checkIntervalSec for everyone loaded.
	  - player:IsFriendsWithAsync results are cached per pair (pcall; failures are retried on the
	    next check, not cached). Cache entries are dropped when either player leaves.
	  - co-play kind (CoPlay.kind): "invite" when GetJoinData().ReferredByPlayerId is a friend in
	    the server, "private" in a private (VIP) server (game.PrivateServerId ~= "" and
	    game.PrivateServerOwnerId ~= 0; reserved servers count as "server"), else "server".
	  - CoPlay signal + onCoPlay handlers fire with the full current friend list only when the
	    friend set GAINS someone (never on every interval).
	  - balance.friends.coPlayMultiplier (optional) is applied with
	    Economy.addMultiplier(player, "coplay", mult) while >= 1 friend is present and removed
	    with Economy.removeMultiplier when the last friend leaves.

	friendsInServer(player) returns the last detected friend list (no yielding).
	Studio console: `coplay <server|invite|private> [userId]` fires the hook for the first player
	with a mock friend list (the other players, or the player itself when solo).
]]

local Players = game:GetService("Players")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local HandlerList =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("HandlerList"))
local CoPlay = require(script.CoPlay)

local MULTIPLIER_ID = "coplay"
local MIN_INTERVAL = 5 -- seconds; floor for a misconfigured checkIntervalSec
local FALLBACK_INTERVAL = 30 -- seconds; only used when checkIntervalSec is missing/invalid

local Friends = {}

local ctx: any = nil
local handlers = HandlerList.new()
local pairCache: { [string]: boolean } = {}
local friendSets: { [Player]: { [number]: boolean } } = {}
local referredBy: { [Player]: number } = {}
local boosted: { [Player]: boolean } = {}
local busy: { [Player]: boolean } = {}

local function isPrivateServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId ~= 0
end

local function coPlayMultiplier(): number?
	local cfg = ctx.config.balance.friends
	local mult = cfg and cfg.coPlayMultiplier
	if type(mult) == "number" and mult == mult and mult > 0 and mult ~= math.huge then
		return mult
	end
	return nil
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
	local set = friendSets[player]
	local hasFriend = set ~= nil and next(set) ~= nil
	local mult = coPlayMultiplier()
	if hasFriend and mult and not boosted[player] then
		boosted[player] = true
		pcall(ctx.services.Economy.addMultiplier, player, MULTIPLIER_ID, mult)
	elseif not hasFriend and boosted[player] then
		boosted[player] = nil
		pcall(ctx.services.Economy.removeMultiplier, player, MULTIPLIER_ID)
	end
end

local function fireCoPlay(player: Player, friends: { Player }, kind: Types.CoPlayKind)
	ctx.signals.CoPlay:Fire(player, friends, kind)
	handlers:fire(player, friends, kind)
	local text = if #friends == 1
		then `Playing with {friends[1].DisplayName}!`
		else `Playing with {#friends} friends!`
	pcall(ctx.net.feedback, player, "toast", text)
	pcall(ctx.services.Analytics.custom, player, "CoPlay_" .. kind, #friends)
end

local function areFriends(a: Player, b: Player): boolean?
	local key = CoPlay.pairKey(a.UserId, b.UserId)
	local cached = pairCache[key]
	if cached ~= nil then
		return cached
	end
	local ok, result = pcall(function()
		return a:IsFriendsWithAsync(b.UserId)
	end)
	if not ok then
		return nil -- unknown; retry next check
	end
	if a.Parent == Players and b.Parent == Players then
		pairCache[key] = result == true
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
	local prefix, suffix = tostring(leaver.UserId) .. ":", ":" .. tostring(leaver.UserId)
	for key in pairCache do
		if string.sub(key, 1, #prefix) == prefix or string.sub(key, -#suffix) == suffix then
			pairCache[key] = nil
		end
	end
	for player, set in friendSets do
		if set[leaver.UserId] then
			set[leaver.UserId] = nil
			applyMultiplier(player)
		end
	end
end

local function checkInterval(): number
	local cfg = ctx.config.balance.friends
	local sec = cfg and cfg.checkIntervalSec
	if type(sec) ~= "number" or sec ~= sec then
		return FALLBACK_INTERVAL -- ConfigValidate should already have rejected this config
	end
	return math.max(sec, MIN_INTERVAL)
end

function Friends.init(context: any)
	ctx = context
end

function Friends.start()
	Players.PlayerAdded:Connect(readJoinData)
	for _, p in Players:GetPlayers() do
		readJoinData(p)
	end
	Players.PlayerRemoving:Connect(onRemoving)

	ctx.services.Data.onLoaded(function(player: Player)
		task.spawn(recompute, player)
		for _, other in Players:GetPlayers() do
			if other ~= player and friendSets[other] ~= nil then
				task.spawn(recompute, other)
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(checkInterval())
			for _, player in Players:GetPlayers() do
				if ctx.services.Data.isLoaded(player) then
					task.spawn(recompute, player)
				end
			end
		end
	end)

	ctx.console.register(
		"coplay",
		"coplay <server|invite|private> [userId]: fire the co-play hook with mock friends (Studio)",
		function(...: any)
			if not ctx.isStudio then
				return "coplay is Studio-only"
			end
			local args = { ... }
			local kind = args[1]
			if kind ~= "server" and kind ~= "invite" and kind ~= "private" then
				return "usage: coplay <server|invite|private> [userId]"
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
			fireCoPlay(player, mock, kind :: Types.CoPlayKind)
			return `fired co-play ({kind}) for {player.Name} with {#mock} mock friend(s)`
		end
	)
end

function Friends.friendsInServer(player: Player): { Player }
	local set = friendSets[player]
	return if set then playersFrom(set) else {}
end

function Friends.onCoPlay(
	handler: (player: Player, friends: { Player }, kind: Types.CoPlayKind) -> ()
): Types.Connection
	return handlers:add(handler)
end

return Friends
