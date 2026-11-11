--!nocheck
--[[
	v1.6.0 legacy import (adopting.md §3) in the multi-server sim: the REAL framework Data + Store
	(ProfileStore 1.0.3) on the World's mock DataStore, with the legacy reader reading the World's
	stores read-only (sim.server(world, { legacy = "world" })) or a StudWork.test.legacyStore.

	  - an "old server" writes the old save through the World; a StudWork server imports it once
	  - two servers: only the server that still holds the StudWork session imports (a session
	    taken during the reads discards everything: lost_session, nothing written)
	  - the old store is only read: no write to it ever comes from a StudWork server
]]

local F = require(script.Parent.Fixtures)
local Legacy = require("packages/framework/server/Legacy.luau")

local KICK_LEGACY =
	"We couldn't bring over your save from the previous version yet. Nothing was lost. Please rejoin in a minute."

local function importPart(counter, source)
	return {
		init = function(ctx)
			ctx.data.importLegacy({
				id = "v1-save",
				version = 1,
				source = source or { kind = "datastore", name = "OldData", key = "Player_{userId}" },
				import = function(tx, old)
					counter.n += 1
					ctx.section(tx).coins = old.coins
				end,
			})
		end,
	}
end

local function joinLoaded(world, s, userId: number, within: number?)
	local p = s:join(userId)
	assert(
		world:advanceUntil(function()
			return s:isLoaded(p)
		end, within or 30, 0.25),
		"loaded"
	)
	return p
end

local function writesTo(world, storeName: string): number
	local n = 0
	for _, w in world.log do
		if w.store == storeName then
			n += 1
		end
	end
	return n
end

describe("legacy import (multi-server sim)", function()
	it("reads the World's old store read-only and imports once; the marker is saved with the data", function()
		local world = F.world()
		world:seed("OldData", "Player_91", { coins = 40 }) -- an old server's save
		world:advance(Legacy.QUIET_SECONDS + 5)
		local counter = { n = 0 }
		local a = F.server(world, { legacy = "world", serverParts = { SimGame = importPart(counter) } })
		local p = joinLoaded(world, a, 91)
		expect(counter.n).toBe(1)
		expect(a:section(p, F.GAME_ID).coins).toBe(40)
		a:leave(p)
		world:advance(10)
		local saved = F.saved(world, 91)
		expect(saved[F.GAME_ID].coins).toBe(40)
		expect(saved._framework.imports["v1-save"].found).toBe(true)
		expect(saved._framework.schemaVersion).toBe(2)
		-- rejoin on another server: nothing imported again
		local b = F.server(world, { legacy = "world", serverParts = { SimGame = importPart(counter) } })
		local q = joinLoaded(world, b, 91)
		expect(counter.n).toBe(1)
		expect(b:section(q, F.GAME_ID).coins).toBe(40)
		expect(writesTo(world, "OldData")).toBe(0)
	end)

	it("DataStore2 ordered backups through the World's OrderedDataStore", function()
		local world = F.world()
		world:setOrdered("coins/92", "1", 1)
		world:setOrdered("coins/92", "2", 2)
		world:seed("coins/92", "1", 5)
		world:seed("coins/92", "2", 25)
		world:advance(Legacy.QUIET_SECONDS + 5)
		local counter = { n = 0 }
		local part = {}
		part.init = function(ctx)
			ctx.data.importLegacy({
				id = "ds2",
				version = 1,
				source = { kind = "datastore2", name = "coins" },
				import = function(tx, old)
					counter.n += 1
					ctx.section(tx).coins = old
				end,
			})
		end
		local a = F.server(world, { legacy = "world", serverParts = { SimGame = part } })
		local p = joinLoaded(world, a, 92)
		expect(a:section(p, F.GAME_ID).coins).toBe(25)
	end)

	it("a busy old save (an old server's final write) kicks; a later join imports", function()
		local world = F.world()
		world:seed("OldData", "Player_93", { coins = 7 }) -- just written
		local counter = { n = 0 }
		local a = F.server(world, { legacy = "world", serverParts = { SimGame = importPart(counter) } })
		local p = a:join(93)
		world:advance(20)
		expect(a:isLoaded(p)).toBe(false)
		local kicked = false
		for _, k in a.kicks do
			if k.userId == 93 and k.message == KICK_LEGACY then
				kicked = true
			end
		end
		expect(kicked).toBe(true)
		-- nothing written for them: ProfileStore's fresh profile ends with its empty Data untouched
		local saved = F.saved(world, 93)
		expect(saved == nil or next(saved) == nil).toBe(true)
		a:leave(p)
		world:advance(Legacy.QUIET_SECONDS)
		local q = joinLoaded(world, a, 93)
		expect(a:section(q, F.GAME_ID).coins).toBe(7)
		expect(counter.n).toBe(1)
	end)

	it("two servers: the session taken during the reads -> lost_session; only the holder imports", function()
		local world = F.world()
		local legacy = Legacy.memory()
		legacy.set("OldData", "Player_94", { coins = 40 }, 0)
		local slow = true
		-- server A's reads take a minute (DataStore throttling); B's are instant
		local slowStore = setmetatable({
			get = function(...)
				if slow then
					slow = false
					world.scheduler:wait(60)
				end
				return legacy.get(...)
			end,
		}, { __index = legacy })
		local counterA, counterB = { n = 0 }, { n = 0 }
		local a = F.server(world, { legacy = slowStore, serverParts = { SimGame = importPart(counterA) } })
		local b = F.server(world, { legacy = legacy, serverParts = { SimGame = importPart(counterB) } })
		local pa = a:join(94)
		world:advance(5) -- A holds the StudWork session and is reading the old store
		expect(F.lockHolder(world, 94)).toBe(a.jobId)
		local pb = joinLoaded(world, b, 94, 120) -- B takes the session over
		world:advance(70)
		expect(a:isLoaded(pa)).toBe(false)
		expect(counterA.n).toBe(0) -- A never ran the import
		expect(counterB.n).toBe(1)
		expect(b:section(pb, F.GAME_ID).coins).toBe(40)
		local calls = {}
		for _, c in a.calls do
			if c.service == "Analytics" and c.fn == "custom" and c.args[2] == "LegacyImportFailed" then
				table.insert(calls, c.args[4].reason)
			end
		end
		expect(calls).toEqual({ "lost_session" })
		b:leave(pb)
		world:advance(10)
		expect(F.saved(world, 94)[F.GAME_ID].coins).toBe(40)
	end)
end)
