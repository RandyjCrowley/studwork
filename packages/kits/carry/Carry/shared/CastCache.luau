--!strict
--[[
	CastCache: one RaycastParams per option set, and a character exclude list kept current from events.

	World.luau used to build a new RaycastParams and loop Players:GetPlayers() on every Raycast/Blockcast (about
	300 casts a second at 50 players). The engine pieces come in through `source`, so the Lune specs run this with
	fakes:

	  CastCache.new({
	    newParams = () -> params,                      -- RaycastParams.new
	    excludeFilter = () -> Enum.RaycastFilterType.Exclude,
	    getPlayers = () -> { player },                 -- Players:GetPlayers (once, to seed)
	    playerAdded = (fn(player)) -> disconnect,
	    playerRemoving = (fn(player)) -> disconnect,
	    characterAdded = (player, fn(character)) -> disconnect,
	    characterRemoving = (player, fn(character)) -> disconnect,
	  })
	  cache.params(opts) -> params                      -- opts: respectCanCollide, collisionGroup, ignoreCharacters, exclude

	Nothing is connected until the first params() call that asks for ignoreCharacters (lazy, like the live adapter's
	services); it then seeds from the current players and follows the four events. A change to the character list
	bumps `version`; a cached params whose version is stale gets FilterDescendantsInstances REASSIGNED (the property
	returns a copy, so mutating a table you assigned does nothing).

	What the list relies on: CharacterAdded OVERWRITES the player's entry (a respawn, LoadCharacter, or a script
	assigning a new model to player.Character), and CharacterRemoving (for the character it names) and
	PlayerRemoving clear it. Known small windows, accepted (worst case: a cast hits a body it should skip, or skips
	a body that is no longer a character):
	  - `player.Character = nil` is not documented to fire CharacterRemoving: a body kept in the world after that
	    (a ragdoll or corpse system) stays excluded until the player's next CharacterAdded or PlayerRemoving;
	  - with deferred signals (Workspace.SignalBehavior = Deferred, the default) player.Character can already be
	    the new model up to about one frame before CharacterAdded runs here, so another player's cast can hit the
	    new body in that frame.

	Cached entries are keyed on respectCanCollide, collisionGroup and ignoreCharacters. A call with a non-empty
	`exclude` gets its own uncached params (nothing in the kit passes one; the list would have to be part of the key).
]]

export type Source = {
	newParams: () -> any,
	excludeFilter: () -> any, -- Enum.RaycastFilterType.Exclude, fetched on the first cast (never at live())
	getPlayers: () -> { any },
	playerAdded: (fn: (player: any) -> ()) -> () -> (),
	playerRemoving: (fn: (player: any) -> ()) -> () -> (),
	characterAdded: (player: any, fn: (character: any) -> ()) -> () -> (),
	characterRemoving: (player: any, fn: (character: any) -> ()) -> () -> (),
}
export type Opts = {
	exclude: { any }?,
	collisionGroup: string?,
	ignoreCharacters: boolean?,
	respectCanCollide: boolean?,
}
export type Cache = {
	params: (opts: Opts) -> any,
	version: () -> number,
	stop: () -> (),
}

-- a safety bound: collisionGroup is in the key, and it is a per-character fact
local MAX_ENTRIES = 64

local CastCache = {}

function CastCache.new(source: Source): Cache
	local entries: { [string]: { params: any, version: number } } = {}
	local entryCount = 0
	local chars: { [any]: any } = {} -- player -> current character
	local connections: { [any]: { () -> () } } = {} -- player -> disconnects
	local globalDisconnects: { () -> () } = {}
	local version = 0
	local list: { any } = {}
	local listVersion = 0
	local connected = false

	local function setChar(player: any, character: any?)
		if chars[player] ~= character then
			chars[player] = character
			version += 1
		end
	end

	local function watch(player: any)
		if connections[player] ~= nil then
			return
		end
		local mine: { () -> () } = {}
		connections[player] = mine
		table.insert(
			mine,
			source.characterAdded(player, function(character: any)
				setChar(player, character)
			end)
		)
		table.insert(
			mine,
			source.characterRemoving(player, function(character: any)
				if chars[player] == character then
					setChar(player, nil)
				end
			end)
		)
	end

	local function unwatch(player: any)
		local mine = connections[player]
		if mine ~= nil then
			connections[player] = nil
			for _, disconnect in mine do
				disconnect()
			end
		end
		setChar(player, nil)
	end

	local function connect()
		connected = true
		table.insert(
			globalDisconnects,
			source.playerAdded(function(player: any)
				watch(player)
				setChar(player, (player :: any).Character)
			end)
		)
		table.insert(globalDisconnects, source.playerRemoving(unwatch))
		for _, player in source.getPlayers() do
			watch(player)
			setChar(player, (player :: any).Character)
		end
	end

	-- the exclude list for the current version, rebuilt only after a change
	local function characters(): { any }
		if listVersion ~= version then
			list = {}
			for _, character in chars do
				table.insert(list, character)
			end
			listVersion = version
		end
		return list
	end

	local function build(opts: Opts): any
		local params = source.newParams()
		params.FilterType = source.excludeFilter()
		if opts.respectCanCollide then
			params.RespectCanCollide = true
		end
		if opts.collisionGroup ~= nil then
			params.CollisionGroup = opts.collisionGroup
		end
		return params
	end

	local function params(opts: Opts): any
		local ignore = opts.ignoreCharacters == true
		if ignore and not connected then
			connect()
		end

		local extra = opts.exclude
		if extra ~= nil and #extra > 0 then
			local filter: { any } = table.clone(extra)
			if ignore then
				for _, character in characters() do
					table.insert(filter, character)
				end
			end
			local fresh = build(opts)
			fresh.FilterDescendantsInstances = filter
			return fresh
		end

		local group = opts.collisionGroup
		local key = (if opts.respectCanCollide then "1" else "0")
			.. (if ignore then "1" else "0")
			.. (if group ~= nil then "g" .. #group .. ":" .. group else "-")
		local entry = entries[key]
		if entry == nil then
			if entryCount >= MAX_ENTRIES then
				entries, entryCount = {}, 0
			end
			entry = { params = build(opts), version = -1 } -- an empty filter until the first reassignment
			entries[key] = entry
			entryCount += 1
		end
		if ignore and entry.version ~= version then
			entry.params.FilterDescendantsInstances = characters() -- reassigned: the engine copies it
			entry.version = version
		end
		return entry.params
	end

	local function stop()
		for _, disconnect in globalDisconnects do
			disconnect()
		end
		for _, mine in connections do
			for _, disconnect in mine do
				disconnect()
			end
		end
		table.clear(globalDisconnects)
		table.clear(connections)
		table.clear(chars)
		table.clear(entries)
		entryCount = 0
		connected = false
		version += 1
	end

	return {
		params = params,
		version = function()
			return version
		end,
		stop = stop,
	}
end

return CastCache
