--!strict
--[[
	Core.Data. OWNED BY AGENT A (core/a-data). Public API: Types.DataAPI.

	PHASE 0 STUB: in-memory only. Data survives leave -> rejoin within the same server (kept in a
	per-UserId table) but not server restarts. Agent A replaces this with ProfileStore: session
	locking, versioned migrations, BindToClose flush, Studio mock store, Mail via MessageAsync.

	Contract details other services rely on (keep them when replacing the stub):
	- DataLoaded fires after defaults/migrations, with stats.sessions already incremented
	  (sessions == 1 means first join ever).
	- lastSeen is the PREVIOUS session's leave time while DataLoaded handlers run (Offline reads
	  it); Data sets lastSeen = now on leave and periodically.
	- DataChanged(player) is deferred and coalesced: at most once per player per frame.
	- update() returns false (and does not run fn) when the player's data is not loaded.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local Schema = require(script.Schema)

type PlayerData = Types.PlayerData

local Data = {}

local ctx: any = nil
local loaded: { [Player]: PlayerData } = {}
local memory: { [number]: PlayerData } = {} -- stub persistence across rejoin (same server)
local dirty: { [Player]: boolean } = {}
local loadedHandlers: { (Player, PlayerData) -> () } = {}

local function markDirty(player: Player)
	dirty[player] = true
end

local function onPlayerAdded(player: Player)
	local now = os.time()
	local data = memory[player.UserId]
	if data == nil then
		data = Schema.default(ctx.config, now)
	end
	local d = data :: PlayerData
	d.stats.sessions = (d.stats.sessions or 0) + 1
	if d.game[ctx.config.gameId] == nil then
		d.game[ctx.config.gameId] = if ctx.config.data then table.clone(ctx.config.data.defaults) else {}
	end
	loaded[player] = d
	ctx.signals.DataLoaded:Fire(player, d)
	for _, handler in loadedHandlers do
		task.spawn(handler, player, d)
	end
	markDirty(player)
end

local function onPlayerRemoving(player: Player)
	local data = loaded[player]
	if data then
		data.lastSeen = os.time()
		memory[player.UserId] = data
	end
	loaded[player] = nil
	dirty[player] = nil
end

function Data.init(context: any)
	ctx = context
end

function Data.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	RunService.Heartbeat:Connect(function()
		if next(dirty) == nil then
			return
		end
		local batch = dirty
		dirty = {}
		for player in batch do
			if loaded[player] then
				ctx.signals.DataChanged:Fire(player)
			end
		end
	end)
end

function Data.get(player: Player): PlayerData?
	return loaded[player]
end

function Data.update(player: Player, fn: (data: PlayerData) -> ()): boolean
	local data = loaded[player]
	if data == nil then
		return false
	end
	fn(data)
	markDirty(player)
	return true
end

function Data.onLoaded(handler: (player: Player, data: PlayerData) -> ()): Types.Connection
	table.insert(loadedHandlers, handler)
	for player, data in loaded do
		task.spawn(handler, player, data)
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
	return loaded[player] ~= nil
end

function Data.getGame(player: Player): { [string]: any }?
	local data = loaded[player]
	return if data then data.game[ctx.config.gameId] else nil
end

function Data.saveAsync(player: Player): boolean
	return loaded[player] ~= nil -- stub: in-memory, nothing to commit
end

function Data.updateGame(player: Player, fn: (gameData: { [string]: any }) -> ()): boolean
	return Data.update(player, function(data)
		fn(data.game[ctx.config.gameId])
	end)
end

return Data
