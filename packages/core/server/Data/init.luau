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
	  fn runs against a copy-on-read working proxy (Transaction.luau): it commits only when fn
	  returns without error; an error discards every write and is re-raised with a traceback; a
	  yield discards and errors; a same-player update inside a running one errors ("nested
	  Data.update"). Only touched sections change identity. Data.get inside fn returns the
	  COMMITTED data (not fn's uncommitted writes).
	- sectionVersion(player, section) (ctx-only) moves only for sections a committed update
	  changed, plus Data's own writes (lastSeen on save, the stats save stamp, purchases pruning,
	  console reset/lastseen).
	- Load failures: store not chosen within STORE_WAIT_TIMEOUT -> kick (load failed). A failed
	  migration / unreadable save -> DataLoadFailed analytics + kick with Load.KICK_MIGRATION_FAILED;
	  profile.Data is never replaced, so the closing EndSession save writes back what was loaded.
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
local Load = require(script.Load)
local Transaction = require(script.Transaction)
local Sanitize = require(script.Sanitize)
local Schema = require(script.Schema)

type PlayerData = Types.PlayerData

-- Engineering constants.
local SAVE_TIMEOUT = 30 -- seconds saveAsync waits for the DataStore write
local STORE_STATE_TIMEOUT = 15 -- seconds to wait for ProfileStore's Studio API-access probe
local STORE_WAIT_TIMEOUT = 30 -- seconds loadPlayer waits for chooseStore before kicking (L1)
local KICK_LOAD_FAILED = Load.KICK_LOAD_FAILED
local KICK_SESSION_ENDED = "Your save data was opened in another server. Please rejoin."

-- Reserved key in PlayerData.stats used by saveAsync to recognise its own commit.
local SAVE_SEQ_KEY = "_saveSeq"

type Entry = {
	profile: any,
	data: PlayerData,
	saveStarted: number, -- OnSave count (diagnostics)
	saveSeq: number, -- last sequence stamped into data.stats[SAVE_SEQ_KEY] by saveAsync
	committedSeq: number, -- highest sequence seen in a SUCCESSFUL save (OnAfterSave payload)
	ended: boolean,
	lastSeenOverride: number?, -- Studio `lastseen` console: written instead of os.time()
	tx: Transaction.State, -- running flag (nested detection) + per-section versions
}

local Data = {}

local ctx: any = nil
local ProfileStore: any = nil
local store: any = nil
local entries: { [Player]: Entry } = {}
local dirty: { [Player]: boolean } = {}
local loadedHandlers: { (Player, PlayerData) -> () } = {}
local storeReady = false
local storeFailed = false

local function markDirty(player: Player)
	dirty[player] = true
end

local function profileKey(userId: number): string
	return "Player_" .. tostring(userId)
end

local function chooseStoreUnsafe()
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

-- L1: a failure here must not leave loadPlayer waiting forever.
local function chooseStore()
	local ok, err = pcall(chooseStoreUnsafe :: any)
	if not ok then
		storeFailed = true
		warn(`[Core.Data] could not select a ProfileStore: {err}`)
	end
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
		Transaction.bump(entry.tx, "lastSeen")
	end
	if Sanitize.prunePurchases(entry.data.purchases, Schema.PURCHASES_CAP) > 0 then
		Transaction.bump(entry.tx, "purchases")
	end
end

local function loadPlayer(player: Player)
	local ready = Load.awaitStore(
		function()
			return storeReady
		end,
		function()
			return storeFailed
		end,
		os.clock,
		function()
			task.wait(0.1)
		end,
		STORE_WAIT_TIMEOUT
	)
	if player.Parent ~= Players then
		return
	end
	if not ready then
		warn(`[Core.Data] no ProfileStore for {player.UserId} (failed or timed out); kicking`)
		player:Kick(KICK_LOAD_FAILED)
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
	local decision = Load.decide(profile.Data, function(raw)
		return Schema.prepare(raw, ctx.config, now)
	end)
	if decision.action == "kick" then
		-- Never write over data we can't understand: profile.Data is untouched (Load.decide never
		-- replaces it), so the closing EndSession save writes back exactly what was loaded; only
		-- the session lock changes. No OnSave hook is connected yet, so lastSeen isn't stamped.
		warn(`[Core.Data] refusing to load {userId} ({decision.status}): {decision.reason}`)
		if decision.analytics then
			task.spawn(function()
				pcall(function()
					ctx.services.Analytics.custom(player, "DataLoadFailed", 1)
				end)
			end)
		end
		profile:EndSession()
		player:Kick(decision.message)
		return
	end
	local data = decision.data :: { [string]: any }
	local dropWarning = Load.dropWarning(userId, decision.report)
	if dropWarning then
		warn(dropWarning)
	end
	profile.Data = data
	profile:AddUserId(userId)
	local playerData = data :: PlayerData
	playerData.stats.sessions = (playerData.stats.sessions or 0) + 1

	-- Start the save sequence from the stored value so saves of older data never look newer.
	local storedSeq = playerData.stats[SAVE_SEQ_KEY]
	local loadedSeq = if type(storedSeq) == "number" and storedSeq == storedSeq then storedSeq else 0
	local entry: Entry = {
		profile = profile,
		data = playerData,
		saveStarted = 0,
		saveSeq = loadedSeq,
		committedSeq = loadedSeq,
		ended = false,
		tx = Transaction.newState(),
	}
	entries[player] = entry

	profile.OnSave:Connect(function()
		onSave(entry)
	end)
	-- OnSave fires for every attempt but OnAfterSave only for successful writes, so attempts and
	-- successes can't be counted against each other. Instead saveAsync stamps a sequence number
	-- into the data and waits until a successful save's payload contains it (or a later one).
	profile.OnAfterSave:Connect(function(lastSaved: any)
		local stats = type(lastSaved) == "table" and lastSaved.stats
		local seq = type(stats) == "table" and stats[SAVE_SEQ_KEY]
		if type(seq) == "number" and seq > entry.committedSeq then
			entry.committedSeq = seq
		end
	end)
	-- OnSessionEnd fires for every ending save (leave, shutdown, session stolen). Only a stolen
	-- session ("External") deserves the "opened in another server" kick.
	local lastSaveReason: string? = nil
	profile.OnLastSave:Connect(function(reason: string)
		lastSaveReason = reason
	end)
	profile.OnSessionEnd:Connect(function()
		entry.ended = true
		if entries[player] == entry then
			entries[player] = nil
			dirty[player] = nil
		end
		if player.Parent == Players and lastSaveReason == "External" then
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
		-- Mail owns the decision: it calls processed() once every handler succeeded (maybe later,
		-- after retries) or the message was dead-lettered / was a duplicate / was malformed.
		deliver(player, message, processed)
	end)
end

local function onPlayerRemoving(player: Player)
	local entry = entries[player]
	entries[player] = nil
	dirty[player] = nil
	if entry and not entry.ended then
		entry.data.lastSeen = entry.lastSeenOverride or os.time()
		Transaction.bump(entry.tx, "lastSeen")
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
				local fresh: { [string]: any } = Schema.default(ctx.config, os.time()) :: any
				fresh.stats.sessions = 1
				-- keep the root identity (profile.Data points at it): replace its contents
				local root = entry.data :: any
				for key in table.clone(root) do
					root[key] = nil
				end
				for key, value in fresh do
					root[key] = value
				end
				Transaction.bumpAll(entry.tx, root)
				fireLoaded(player, entry.data) -- "re-read everything"
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
			Transaction.bump(entry.tx, "lastSeen")
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
	local changed = Transaction.run(entry.tx, entry.data :: any, fn :: any)
	if #changed > 0 then
		markDirty(player)
	end
	return true
end

-- ctx-only (Context.DataInternal). Globally increasing per-section version (0 = never changed
-- this session); moves only when a committed update or Data itself changed that section.
function Data.sectionVersion(player: Player, section: string): number
	local entry = entries[player]
	return if entry then Transaction.version(entry.tx, section) else 0
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
	-- Stamp a sequence number into the data; any successful save whose payload carries this
	-- number (or a later one) contains every write made before this call. A failed save never
	-- blocks later calls: the next successful save (ours or an autosave) carries the stamp.
	entry.saveSeq = math.max(entry.saveSeq, entry.committedSeq) + 1
	local target = entry.saveSeq
	entry.data.stats[SAVE_SEQ_KEY] = target
	Transaction.bump(entry.tx, "stats")
	entry.profile:Save()
	local deadline = os.clock() + SAVE_TIMEOUT
	while entry.committedSeq < target do
		if entry.ended or os.clock() > deadline then
			return entry.committedSeq >= target
		end
		task.wait()
	end
	return true
end

return Data
