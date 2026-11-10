--!strict
--[[
	Server -> local player state replication. OWNED BY AGENT G (core/g-client).

	Contract (kept from Phase 0): set(player, key, value) / setAll(key, value) for non-PlayerData
	keys of Types.ReplicatedState; a StateInit request sends a full snapshot; payloads go through
	the Blink StateSync event; one player's data is never sent to another player.

	How it works (charm-sync 0.4.1, see README.md):
	  * One Charm atom per player holding a ReplicatedState-shaped table, synced by
	    CharmSync.server under the key tostring(player.UserId). Each player is subscribed ONLY to
	    their own key, so charm-sync never builds a payload for them containing another player.
	  * DataChanged / DataLoaded / set / setAll mark the player dirty; once per Heartbeat dirty
	    players get a new Snapshot.build whose data comes from a per-player SectionCache (M2):
	    only sections whose ctx.services.Data.sectionVersion moved are deep-copied again, the
	    rest reuse last time's copy by reference, so charm-sync's diff skips them (old == new).
	    Server-only sections (purchases, pity, funnel, mail) are never replicated. Then
	    CharmSync.server.flush() diffs last-synced vs new and sends
	    { type = "patch", data = { [key] = diff } } (removed values = None).
	  * set/setAll table values are sanitised (Snapshot.copy) once when set, not every rebuild.
	  * StateInit (client ready) (re)subscribes the player -> the next flush sends
	    { type = "init", data = { [key] = fullState } }. Sending StateInit again re-hydrates.
	  * PlayerRemoving unsubscribes and drops the atom + per-player keys.
	  * CharmSync.config.interval is set to -1: we flush manually right after rebuilding so a
	    change goes out the same frame (charm-sync's config table is global to the place).
	Payload on the wire: { SyncPayload } (array of { type: "init"|"patch", data: {[string]: any} }).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Charm = require(Packages:WaitForChild("Charm")) :: any
local CharmSync = require(Packages:WaitForChild("CharmSync")) :: any

local Snapshot = require(script.Snapshot)
local SectionCache = require(script.SectionCache)

local Replication = {}

type PlayerEntry = {
	atom: any,
	cache: SectionCache.SectionCache,
	extra: { [string]: any },
	subscribed: boolean,
}

local ctx: any = nil
local entries: { [Player]: PlayerEntry } = {}
local shared: { [string]: any } = {}
local dirty: { [Player]: boolean } = {}
local needsFlush = false
local started = false

local function keyOf(player: Player): string
	return tostring(player.UserId)
end

local function getData(player: Player): any
	local services = ctx and ctx.services
	if services and services.Data and services.Data.get then
		return services.Data.get(player)
	end
	return nil
end

-- Fallback when Data has no sectionVersion: a fresh number every call = always re-copy (correct).
local fallbackVersion = 0

local function buildFor(player: Player, entry: PlayerEntry): { [string]: any }
	local data = getData(player)
	local dataApi = ctx and ctx.services and ctx.services.Data
	local versionOf = if dataApi and dataApi.sectionVersion
		then function(section: string): number
			return dataApi.sectionVersion(player, section)
		end
		else function(_section: string): number
			fallbackVersion += 1
			return fallbackVersion
		end
	local dataCopy = entry.cache:build(data, versionOf)
	return Snapshot.build(data, entry.extra, shared, { dataCopy = dataCopy, sanitized = true })
end

local function entryFor(player: Player): PlayerEntry?
	local entry = entries[player]
	if entry == nil then
		if player.Parent ~= Players then
			return nil
		end
		local newEntry: PlayerEntry =
			{ atom = nil, cache = SectionCache.new(), extra = {}, subscribed = false }
		newEntry.atom = Charm.atom(buildFor(player, newEntry))
		entries[player] = newEntry
		entry = newEntry
	end
	return entry
end

local function markDirty(player: Player)
	if typeof(player) == "Instance" and player.Parent == Players then
		dirty[player] = true
	end
end

local function rebuild(player: Player)
	local entry = entryFor(player)
	if entry then
		-- always a new top-level table (charm-sync compares by reference); unchanged sections
		-- inside it keep their previous references (SectionCache)
		entry.atom(buildFor(player, entry))
		needsFlush = true
	end
end

local function subscribe(player: Player)
	local entry = entryFor(player)
	if entry == nil then
		return
	end
	local key = keyOf(player)
	if entry.subscribed then
		-- forget this key for this client so the next flush sends a full "init" again
		CharmSync.server.removeSignalsFromClient(player, key)
	end
	rebuild(player)
	CharmSync.server.addSignalsToClient(player, { [key] = entry.atom })
	entry.subscribed = true
	dirty[player] = nil
	needsFlush = true
end

local function cleanup(player: Player)
	local entry = entries[player]
	if entry and entry.subscribed then
		CharmSync.server.removeClient(player)
	end
	entries[player] = nil
	dirty[player] = nil
end

function Replication.init(context: any)
	ctx = context
end

function Replication.set(player: Player, key: string, value: any)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if not Snapshot.EXTRA_KEYS[key] then
		warn(`[Replication] set: unknown key {key}`)
		return
	end
	local entry = entryFor(player)
	if entry == nil then
		return
	end
	-- tables are compared by content later (diff); always mark them dirty
	if entry.extra[key] ~= value or type(value) == "table" then
		entry.extra[key] = if type(value) == "table" then Snapshot.copy(value) else value
		markDirty(player)
	end
end

function Replication.setAll(key: string, value: any)
	if not Snapshot.EXTRA_KEYS[key] then
		warn(`[Replication] setAll: unknown key {key}`)
		return
	end
	shared[key] = if type(value) == "table" then Snapshot.copy(value) else value
	for _, player in Players:GetPlayers() do
		markDirty(player)
	end
end

-- Debug helper: the snapshot currently held for a player (nil if none). Read-only.
function Replication.peek(player: Player): any
	local entry = entries[player]
	return if entry then entry.atom() else nil
end

local function step()
	if next(dirty) ~= nil then
		local batch = dirty
		dirty = {}
		Charm.batch(function()
			for player in batch do
				if player.Parent == Players then
					rebuild(player)
				end
			end
		end)
	end
	if needsFlush then
		needsFlush = false
		CharmSync.server.flush()
	end
end

function Replication.start()
	if started then
		return
	end
	started = true

	CharmSync.config.interval = -1 -- manual flush in step()
	CharmSync.server.connect(function(player: Player, payloads: any)
		-- charm-sync only builds payloads for keys this player subscribed to (their own)
		if player.Parent == Players and entries[player] ~= nil then
			ctx.net.events.StateSync.Fire(player, payloads)
		end
	end)

	ctx.signals.DataChanged:Connect(markDirty)
	if ctx.signals.DataLoaded then
		ctx.signals.DataLoaded:Connect(function(player: Player)
			markDirty(player)
		end)
	end
	ctx.net.handle("StateInit", function(player: Player)
		subscribe(player)
	end)
	Players.PlayerRemoving:Connect(cleanup)
	RunService.Heartbeat:Connect(step)
end

return Replication
