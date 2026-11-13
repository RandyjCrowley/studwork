--!nocheck
--[[
	Movement's CastCache (review M3): one RaycastParams per option set, and a character exclude list kept current
	from PlayerAdded / PlayerRemoving / CharacterAdded / CharacterRemoving. Pure module, fakes for every engine piece.
]]
local CastCache = require("packages/kits/carry/Movement/shared/CastCache.luau")

local EXCLUDE = { name = "Exclude" }

-- a fake engine: players with a Character field, signals that count live connections, params that count filter writes
local function engine(initial)
	local e = { players = {}, constructed = 0, getPlayersCalls = 0, filterWrites = 0, params = {} }
	local signals = {}
	local function signal(name)
		signals[name] = signals[name] or { handlers = {}, connected = 0 }
		return signals[name]
	end
	local function connect(sig, fn)
		sig.handlers[fn] = true
		sig.connected += 1
		return function()
			if sig.handlers[fn] then
				sig.handlers[fn] = nil
				sig.connected -= 1
			end
		end
	end
	local function fire(sig, ...)
		for fn in table.clone(sig.handlers) do
			fn(...)
		end
	end
	function e.connections()
		local n = 0
		for _, sig in signals do
			n += sig.connected
		end
		return n
	end
	function e.addPlayer(name, character)
		local player = { Name = name, Character = character }
		table.insert(e.players, player)
		fire(signal("playerAdded"), player)
		return player
	end
	function e.removePlayer(player, skipCharacterEvent)
		-- the engine fires CharacterRemoving for the character before the player leaves
		if player.Character ~= nil and not skipCharacterEvent then
			e.setCharacter(player, nil)
		end
		fire(signal("playerRemoving"), player)
		table.remove(e.players, table.find(e.players, player))
	end
	-- spawn / respawn / a game setting player.Character itself: the engine fires Removing for the old one, Added for the new
	function e.setCharacter(player, character)
		local old = player.Character
		if old ~= nil then
			fire(signal("charRemoving:" .. player.Name), old)
		end
		player.Character = character
		if character ~= nil then
			fire(signal("charAdded:" .. player.Name), character)
		end
	end
	for _, p in initial or {} do
		table.insert(e.players, { Name = p[1], Character = p[2] })
	end

	e.source = {
		newParams = function()
			e.constructed += 1
			local backing = { FilterDescendantsInstances = {} } -- the engine's default
			local params = setmetatable({}, {
				__index = backing,
				__newindex = function(_, k, v)
					if k == "FilterDescendantsInstances" then
						e.filterWrites += 1
						-- the engine returns a copy: later mutation of the assigned table must not show
						v = table.clone(v)
					end
					backing[k] = v
				end,
			})
			table.insert(e.params, params)
			return params
		end,
		excludeFilter = function()
			return EXCLUDE
		end,
		getPlayers = function()
			e.getPlayersCalls += 1
			return table.clone(e.players)
		end,
		playerAdded = function(fn)
			return connect(signal("playerAdded"), fn)
		end,
		playerRemoving = function(fn)
			return connect(signal("playerRemoving"), fn)
		end,
		characterAdded = function(player, fn)
			return connect(signal("charAdded:" .. player.Name), fn)
		end,
		characterRemoving = function(player, fn)
			return connect(signal("charRemoving:" .. player.Name), fn)
		end,
	}
	return e
end

local function has(list, x)
	return table.find(list, x) ~= nil
end

local OPTS = { ignoreCharacters = true, respectCanCollide = true, collisionGroup = "Walkers" }

describe("CastCache: one params per option set", function()
	it("N casts with the same options construct params once and read the players once", function()
		local e = engine({ { "a", { "charA" } }, { "b", { "charB" } } })
		local cache = CastCache.new(e.source)
		local first = cache.params(OPTS)
		for _ = 1, 500 do
			expect(cache.params(OPTS)).toBe(first)
		end
		expect(e.constructed).toBe(1)
		expect(e.getPlayersCalls).toBe(1)
		expect(e.filterWrites).toBe(1)
		expect(first.FilterType).toBe(EXCLUDE)
		expect(first.RespectCanCollide).toBe(true)
		expect(first.CollisionGroup).toBe("Walkers")
		expect(#first.FilterDescendantsInstances).toBe(2)
	end)

	it("a different collisionGroup, respectCanCollide or ignoreCharacters gets distinct params", function()
		local e = engine({ { "a", { "charA" } } })
		local cache = CastCache.new(e.source)
		local base = cache.params(OPTS)
		local other =
			cache.params({ ignoreCharacters = true, respectCanCollide = true, collisionGroup = "Other" })
		local noRespect = cache.params({ ignoreCharacters = true, collisionGroup = "Walkers" })
		local noIgnore = cache.params({ respectCanCollide = true, collisionGroup = "Walkers" })
		local noGroup = cache.params({ ignoreCharacters = true, respectCanCollide = true })
		local all = { base, other, noRespect, noIgnore, noGroup }
		for i = 1, #all do
			for j = i + 1, #all do
				expect(all[i] ~= all[j]).toBe(true)
			end
		end
		expect(e.constructed).toBe(5)
		expect(other.CollisionGroup).toBe("Other")
		expect(noRespect.RespectCanCollide).toBe(nil)
		expect(noGroup.CollisionGroup).toBe(nil)
		expect(#noIgnore.FilterDescendantsInstances).toBe(0)
		expect(#noGroup.FilterDescendantsInstances).toBe(1)
		-- and each is itself cached
		expect(cache.params(OPTS)).toBe(base)
		expect(cache.params({ ignoreCharacters = true, respectCanCollide = true, collisionGroup = "Other" })).toBe(
			other
		)
		expect(e.constructed).toBe(5)
	end)

	it("a call that doesn't ignore characters never connects to anything", function()
		local e = engine({ { "a", { "charA" } } })
		local cache = CastCache.new(e.source)
		cache.params({ respectCanCollide = true })
		expect(e.connections()).toBe(0)
		expect(e.getPlayersCalls).toBe(0)
	end)

	it("a non-empty exclude gets its own params every time, with the characters appended", function()
		local e = engine({ { "a", { "charA" } } })
		local cache = CastCache.new(e.source)
		local wall = { "wall" }
		local one = cache.params({ exclude = { wall }, ignoreCharacters = true })
		local two = cache.params({ exclude = { wall }, ignoreCharacters = true })
		expect(one ~= two).toBe(true)
		expect(has(one.FilterDescendantsInstances, wall)).toBe(true)
		expect(#one.FilterDescendantsInstances).toBe(2)
		-- an empty exclude is the cached path
		expect(cache.params({ exclude = {}, ignoreCharacters = true })).toBe(
			cache.params({ ignoreCharacters = true })
		)
	end)
end)

describe("CastCache: the character exclude list follows the four events", function()
	it("a respawned player's NEW character is excluded from the first cast after CharacterAdded", function()
		local e = engine({})
		local cache = CastCache.new(e.source)
		local p = e.addPlayer("a", nil)
		local params = cache.params(OPTS)
		expect(#params.FilterDescendantsInstances).toBe(0)
		e.setCharacter(p, { "first" })
		local first = p.Character
		expect(has(cache.params(OPTS).FilterDescendantsInstances, first)).toBe(true)
		e.setCharacter(p, { "second" }) -- respawn
		local list = cache.params(OPTS).FilterDescendantsInstances
		expect(has(list, p.Character)).toBe(true)
		expect(has(list, first)).toBe(false)
		expect(#list).toBe(1)
		expect(cache.params(OPTS)).toBe(params) -- the same params object, filter reassigned
	end)

	it("a removed character leaves the list at CharacterRemoving", function()
		local e = engine({})
		local cache = CastCache.new(e.source)
		local p = e.addPlayer("a", { "body" })
		local body = p.Character
		expect(has(cache.params(OPTS).FilterDescendantsInstances, body)).toBe(true)
		e.setCharacter(p, nil)
		expect(#cache.params(OPTS).FilterDescendantsInstances).toBe(0)
	end)

	it("a player who leaves isn't in the list and their connections are dropped (no leak)", function()
		local e = engine({ { "a", { "charA" } } })
		local cache = CastCache.new(e.source)
		local b = e.addPlayer("b", { "charB" })
		cache.params(OPTS)
		local connected = e.connections()
		expect(connected > 2).toBe(true)
		local charB = b.Character
		e.removePlayer(b)
		local list = cache.params(OPTS).FilterDescendantsInstances
		expect(#list).toBe(1)
		expect(has(list, charB)).toBe(false)
		expect(e.connections()).toBe(connected - 2) -- b's CharacterAdded and CharacterRemoving
		-- many join/leave cycles don't grow the connections
		for i = 1, 20 do
			e.removePlayer(e.addPlayer("t" .. i, { "c" .. i }))
		end
		cache.params(OPTS)
		expect(e.connections()).toBe(connected - 2)
		expect(#cache.params(OPTS).FilterDescendantsInstances).toBe(1)
	end)

	it("a player who leaves with no CharacterRemoving seen still drops out of the list", function()
		local e = engine({})
		local cache = CastCache.new(e.source)
		local p = e.addPlayer("a", { "body" })
		expect(#cache.params(OPTS).FilterDescendantsInstances).toBe(1)
		e.removePlayer(p, true)
		expect(#cache.params(OPTS).FilterDescendantsInstances).toBe(0)
	end)

	it(
		"a player who joins already holding a character, and one who spawns later, are both excluded",
		function()
			local e = engine({})
			local cache = CastCache.new(e.source)
			cache.params(OPTS)
			local early = e.addPlayer("early", { "body" })
			local late = e.addPlayer("late", nil)
			expect(#cache.params(OPTS).FilterDescendantsInstances).toBe(1)
			e.setCharacter(late, { "lateBody" })
			local list = cache.params(OPTS).FilterDescendantsInstances
			expect(#list).toBe(2)
			expect(has(list, early.Character)).toBe(true)
			expect(has(list, late.Character)).toBe(true)
		end
	)

	it("a game that sets player.Character itself (replacing a live one) swaps old for new", function()
		local e = engine({})
		local cache = CastCache.new(e.source)
		local p = e.addPlayer("a", { "rig" })
		local rig = p.Character
		cache.params(OPTS)
		e.setCharacter(p, { "custom" })
		local list = cache.params(OPTS).FilterDescendantsInstances
		expect(#list).toBe(1)
		expect(list[1]).toBe(p.Character)
		expect(has(list, rig)).toBe(false)
	end)

	it("the list is rebuilt, and the filter reassigned, only after a change", function()
		local e = engine({ { "a", { "charA" } } })
		local cache = CastCache.new(e.source)
		cache.params(OPTS)
		cache.params({ ignoreCharacters = true }) -- a second option set
		local writes = e.filterWrites
		local v = cache.version()
		for _ = 1, 200 do
			cache.params(OPTS)
			cache.params({ ignoreCharacters = true })
		end
		expect(e.filterWrites).toBe(writes)
		expect(cache.version()).toBe(v)
		expect(e.getPlayersCalls).toBe(1)
		-- a player with no character yet changes nothing
		local p = e.addPlayer("b", nil)
		cache.params(OPTS)
		expect(e.filterWrites).toBe(writes)
		-- a spawn changes the list: each cached params is reassigned once, lazily
		e.setCharacter(p, { "bodyB" })
		cache.params(OPTS)
		cache.params(OPTS)
		expect(e.filterWrites).toBe(writes + 1)
		cache.params({ ignoreCharacters = true })
		expect(e.filterWrites).toBe(writes + 2)
		expect(e.getPlayersCalls).toBe(1)
	end)

	it("stop() disconnects everything", function()
		local e = engine({ { "a", { "charA" } } })
		local cache = CastCache.new(e.source)
		cache.params(OPTS)
		expect(e.connections() > 0).toBe(true)
		cache.stop()
		expect(e.connections()).toBe(0)
	end)
end)
