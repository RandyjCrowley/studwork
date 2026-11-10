--!strict
--[[
	Core.Data. OWNED BY AGENT A (core/a-data). Public API: Types.DataAPI.
	ProfileStore 1.0.3 backed player data. See README.md in this folder.

	Contract details other services rely on:
	- DataLoaded / onLoaded fire after migrations, reconcile and sanitize, with stats.sessions
	  already incremented (sessions == 1 means first join ever).
	- lastSeen is the PREVIOUS session's last save/leave time while DataLoaded handlers run
	  (Offline reads it; on a first join lastSeen == firstJoin == now). Data writes
	  lastSeen = os.time() right before EVERY ProfileStore save (autosave, saveAsync, leave,
	  BindToClose) via profile.OnSave.
	- DataChanged(player) is deferred and coalesced: at most once per player per frame.
	- update() returns false (and does not run fn) when the player's data is not loaded.
	  fn must not yield: it runs in a coroutine and Data raises an error if it yields.
	- saveAsync(player) yields until the current data is committed (true) or the save failed /
	  timed out / the player is not loaded (false).

	Store: ProfileStore.New("PlayerData_" .. gameId) live ("PlayerData_<gameId>_Studio" in Studio
	with API access), key "Player_" .. userId, profile:AddUserId(userId) for GDPR erasure.
	Studio without DataStore access -> store.Mock (warned once; nothing persists across runs).
	Data saved by NEWER code (schemaVersion or game _version above ours) is never modified: the
	session is ended without any write by us and the player is kicked with a rejoin message.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local Internal = require(script.Internal)
local Sanitize = require(script.Sanitize)
local Schema = require(script.Schema)

type PlayerData = Types.PlayerData

-- Engineering constants.
local SAVE_TIMEOUT = 30 -- seconds saveAsync waits for the DataStore write
local STORE_STATE_TIMEOUT = 15 -- seconds to wait for ProfileStore's Studio API-access probe
local KICK_LOAD_FAILED = "Your save data could not be loaded. Please rejoin in a moment."
local KICK_SESSION_ENDED = "Your save data was opened in another server. Please rejoin."
local KICK_NEWER_DATA =
	"This server is running an older version of the game. Please rejoin to get the latest."

type Entry = {
	profile: any,
	data: PlayerData,
	saveStarted: number, -- OnSave count
	saveDone: number, -- OnAfterSave count
	ended: boolean,
	lastSeenOverride: number?, -- Studio `lastseen` console: written instead of os.time()
}

local Data = {}

local ctx: any = nil
local ProfileStore: any = nil
local store: any = nil
local entries: { [Player]: Entry } = {}
local dirty: { [Player]: boolean } = {}
local loadedHandlers: { (Player, PlayerData) -> () } = {}
local storeReady = false

local function markDirty(player: Player)
	dirty[player] = true
end

local function profileKey(userId: number): string
	return "Player_" .. tostring(userId)
end

local function chooseStore()
	ProfileStore = require(ServerStorage:WaitForChild("ServerPackages"):WaitForChild("ProfileStore")) :: any
	local gameId: string = ctx.config.gameId
	local name = "PlayerData_" .. gameId
	if ctx.isStudio then
		name ..= "_Studio"
		local deadline = os.clock() + STORE_STATE_TIMEOUT
		while ProfileStore.DataStoreState == "NotReady" and os.clock() < deadline do
			task.wait(0.1)
		end
	end
	local base = ProfileStore.New(name, {})
	if ctx.isStudio and ProfileStore.DataStoreState ~= "Access" then
		warn(
			`[Core.Data] DataStore API unavailable in Studio ({ProfileStore.DataStoreState}); using ProfileStore.Mock - data will not persist.`
		)
		store = base.Mock
		Internal.isMock = true
	else
		store = base
	end
	Internal.store = store
	storeReady = true
end

local function fireLoaded(player: Player, data: PlayerData)
	ctx.signals.DataLoaded:Fire(player, data)
	for _, handler in table.clone(loadedHandlers) do
		task.spawn(handler, player, data)
	end
	markDirty(player)
end

local function onSave(entry: Entry)
	-- Fires synchronously right before every ProfileStore write (autosave, Save, EndSession,
	-- BindToClose shutdown save), so lastSeen and the purchases cap are always in the commit.
	entry.saveStarted += 1
	if not entry.ended then
		entry.data.lastSeen = entry.lastSeenOverride or os.time()
	end
	Sanitize.prunePurchases(entry.data.purchases, Schema.PURCHASES_CAP)
end

local function loadPlayer(player: Player)
	while not storeReady do
		task.wait()
	end
	if player.Parent ~= Players then
		return
	end
	local userId = player.UserId
	local ok, profile = pcall(function()
		return store:StartSessionAsync(profileKey(userId), {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})
	end)
	if not ok then
		warn(`[Core.Data] StartSessionAsync errored for {userId}: {profile}`)
		profile = nil
	end
	if profile == nil then
		if player.Parent == Players then
			player:Kick(KICK_LOAD_FAILED)
		end
		return
	end
	if player.Parent ~= Players then
		profile:EndSession() -- left while loading
		return
	end

	local now = os.time()
	local data, status, message = Schema.prepare(profile.Data, ctx.config, now)
	if status == "newer" or status == "error" then
		-- Never write over data we can't understand: profile.Data is untouched, so the final
		-- EndSession save writes back exactly what was loaded (only the session lock changes).
		warn(`[Core.Data] refusing to load {userId} ({status}): {message}`)
		profile:EndSession()
		player:Kick(if status == "newer" then KICK_NEWER_DATA else KICK_LOAD_FAILED)
		return
	end
	profile.Data = data
	profile:AddUserId(userId)
	local playerData = data :: PlayerData
	playerData.stats.sessions = (playerData.stats.sessions or 0) + 1

	local entry: Entry =
		{ profile = profile, data = playerData, saveStarted = 0, saveDone = 0, ended = false }
	entries[player] = entry

	profile.OnSave:Connect(function()
		onSave(entry)
	end)
	profile.OnAfterSave:Connect(function()
		entry.saveDone += 1
	end)
	profile.OnSessionEnd:Connect(function()
		entry.ended = true
		if entries[player] == entry then
			entries[player] = nil
			dirty[player] = nil
		end
		if player.Parent == Players then
			player:Kick(KICK_SESSION_ENDED)
		end
	end)

	fireLoaded(player, playerData)

	-- Queued + future Mail messages. ProfileStore re-delivers unprocessed messages next session.
	profile:MessageHandler(function(message: any, processed: () -> ())
		local deliver = Internal.deliver
		if entries[player] ~= entry or deliver == nil then
			return
		end
		if deliver(player, message) then
			processed()
		end
	end)
end

local function onPlayerRemoving(player: Player)
	local entry = entries[player]
	entries[player] = nil
	dirty[player] = nil
	if entry and not entry.ended then
		entry.data.lastSeen = entry.lastSeenOverride or os.time()
		entry.profile:EndSession() -- OnSave writes lastSeen again right before the final save
	end
end

local function firstPlayer(userIdArg: any): Player?
	local userId = tonumber(userIdArg)
	if userId then
		return Players:GetPlayerByUserId(userId)
	end
	return Players:GetPlayers()[1]
end

local function registerConsole()
	if not ctx.isStudio or ctx.console == nil then
		return
	end
	ctx.console.register(
		"data",
		"data <dump|reset> [userId]: print or wipe a player's data",
		function(sub, userId)
			local player = firstPlayer(userId)
			local entry = if player then entries[player] else nil
			if player == nil or entry == nil then
				return "no loaded player"
			end
			if sub == "dump" then
				return HttpService:JSONEncode(entry.data)
			elseif sub == "reset" then
				local fresh = Schema.default(ctx.config, os.time())
				fresh.stats.sessions = 1
				entry.profile.Data = fresh
				entry.data = fresh
				fireLoaded(player, fresh) -- "re-read everything"
				return `reset data of {player.Name}`
			end
			return "usage: data <dump|reset> [userId]"
		end
	)
	ctx.console.register(
		"lastseen",
		"lastseen <secondsAgo> [userId]: set lastSeen back",
		function(ago, userId)
			local seconds = tonumber(ago)
			local player = firstPlayer(userId)
			if seconds == nil or seconds ~= seconds then
				return "usage: lastseen <secondsAgo> [userId]"
			end
			if player == nil or entries[player] == nil then
				return "no loaded player"
			end
			local entry = entries[player] :: Entry
			entry.lastSeenOverride = os.time() - seconds
			entry.data.lastSeen = os.time() - seconds
			markDirty(player)
			return `lastSeen of {player.Name} = now - {seconds}s (kept through saves; rejoin to trigger Offline)`
		end
	)
end

function Data.init(context: any)
	ctx = context
end

function Data.start()
	Internal.nudgeSave = function(userId: number)
		local player = Players:GetPlayerByUserId(userId)
		local entry = if player then entries[player] else nil
		if entry and not entry.ended and entry.profile:IsActive() then
			entry.profile:Save()
		end
	end
	task.spawn(chooseStore)
	Players.PlayerAdded:Connect(loadPlayer)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end
	-- ProfileStore's own BindToClose ends every active session (OnSave -> lastSeen) and waits
	-- for the writes. This one only stamps lastSeen early in case a game handler inspects it.
	game:BindToClose(function()
		local now = os.time()
		for _, entry in entries do
			if not entry.ended then
				entry.data.lastSeen = entry.lastSeenOverride or now
			end
		end
	end)
	RunService.Heartbeat:Connect(function()
		if next(dirty) == nil then
			return
		end
		local batch = dirty
		dirty = {}
		for player in batch do
			if entries[player] then
				ctx.signals.DataChanged:Fire(player)
			end
		end
	end)
	registerConsole()
end

function Data.get(player: Player): PlayerData?
	local entry = entries[player]
	return if entry then entry.data else nil
end

function Data.update(player: Player, fn: (data: PlayerData) -> ()): boolean
	local entry = entries[player]
	if entry == nil or entry.ended then
		return false
	end
	local co = coroutine.create(fn)
	local ok, err = coroutine.resume(co, entry.data)
	markDirty(player)
	if not ok then
		error(err, 2)
	end
	if coroutine.status(co) ~= "dead" then
		coroutine.close(co)
		error("Data.update: fn must not yield", 2)
	end
	return true
end

function Data.onLoaded(handler: (player: Player, data: PlayerData) -> ()): Types.Connection
	table.insert(loadedHandlers, handler)
	for player, entry in entries do
		task.spawn(handler, player, entry.data)
	end
	local connection = { Connected = true }
	function connection.Disconnect(self: any)
		self.Connected = false
		local index = table.find(loadedHandlers, handler)
		if index then
			table.remove(loadedHandlers, index)
		end
	end
	return (connection :: any) :: Types.Connection
end

function Data.isLoaded(player: Player): boolean
	local entry = entries[player]
	return entry ~= nil and not entry.ended
end

function Data.getGame(player: Player): { [string]: any }?
	local entry = entries[player]
	return if entry then entry.data.game[ctx.config.gameId] else nil
end

function Data.updateGame(player: Player, fn: (gameData: { [string]: any }) -> ()): boolean
	return Data.update(player, function(data)
		fn(data.game[ctx.config.gameId])
	end)
end

function Data.saveAsync(player: Player): boolean
	local entry = entries[player]
	if entry == nil or entry.ended or not entry.profile:IsActive() then
		return false
	end
	local before = entry.saveStarted
	entry.profile:Save() -- spawns the save; OnSave fires synchronously inside
	if entry.saveStarted == before then
		return false
	end
	-- Saves on one key complete in order, so our write is committed once saveDone reaches the
	-- OnSave count of our call. A failed write is retried by ProfileStore's next save; we give up
	-- after SAVE_TIMEOUT and report false.
	local target = entry.saveStarted
	local deadline = os.clock() + SAVE_TIMEOUT
	while entry.saveDone < target do
		if entry.ended or os.clock() > deadline then
			return entry.saveDone >= target
		end
		task.wait()
	end
	return true
end

return Data
