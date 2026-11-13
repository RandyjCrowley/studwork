--!nocheck
-- Real module parts and ProfileStore sessions share one simulated cloud across servers.
local F = require("packages/framework/test/sim/Fixtures.luau")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage.Framework)

local function code(id, extra)
	local definition = { id = id, code = string.upper(id), rewards = { { kind = "currency", amount = 10 } } }
	for key, value in extra or {} do
		definition[key] = value
	end
	return definition
end
local function worldWith(definitions, extra)
	local world = F.world({
		config = {
			modules = { "Economy", "Codes", "Settings" },
			items = {},
			config = {
				Codes = {
					definitions = definitions or { code("welcome") },
					rate = { rate = 100, burst = 100 },
					sharedOpsPerMinute = 1000,
				},
			},
		},
	})
	for key, value in extra or {} do
		world.config.config.Codes[key] = value
	end
	return world
end
local function join(world, server, id)
	local player = server:join(id)
	assert(
		world:advanceUntil(function()
			return server:isLoaded(player)
		end, 60, 0.1),
		"player loaded"
	)
	world:advance(0.1)
	return player
end
local function finish(world, handle, seconds)
	assert(
		world:advanceUntil(function()
			return handle.done
		end, seconds or 60, 0.1),
		"operation finished"
	)
	assert(handle.error == nil, tostring(handle.error))
	return handle.result
end
local function redeem(world, server, player, text)
	return finish(world, server:spawn(server:use("Codes").redeem, player, text))
end
local function ledger(world, id)
	return world:peek("StudWorkShared_sim", "Codes/cap/" .. id)
end
local function occupied(record)
	local count = record.used
	for _ in record.reserved do
		count += 1
	end
	return count
end
local function coins(server, player)
	return server:use("Economy").balance(player)
end

describe("player modules across real simulated servers", function()
	it("double submits and a second-server rejoin grant once", function()
		local world = worldWith({ code("welcome", { maxUses = 10 }) })
		local a, b = F.server(world), F.server(world)
		local p = join(world, a, 1001)
		world.latency = 0.1
		local first = a:spawn(a:use("Codes").redeem, p, "  welcome  ")
		local second = a:spawn(a:use("Codes").redeem, p, "WELCOME")
		expect(finish(world, first)).toBe("ok")
		expect(finish(world, second)).toBe("try_later")
		expect(coins(a, p)).toBe(10)
		a:leave(p)
		world:advance(10)
		local rejoined = join(world, b, 1001)
		expect(redeem(world, b, rejoined, "WELCOME")).toBe("already_used")
		expect(coins(b, rejoined)).toBe(10)
		expect(ledger(world, "welcome").used).toBe(1)
		expect(F.writerViolations(world, 1001)).toEqual({})
		expect(world:errors()).toEqual({})
	end)
	it("three servers concurrently grant exactly ten capped uses", function()
		local world = worldWith({ code("limited", { maxUses = 10 }) })
		local servers = { F.server(world), F.server(world), F.server(world) }
		local players = {}
		for id = 1, 18 do
			local server = servers[(id - 1) % 3 + 1]
			table.insert(players, { server = server, player = join(world, server, 2000 + id) })
		end
		world.latency = 0.05
		local handles = {}
		for _, entry in players do
			table.insert(
				handles,
				entry.server:spawn(entry.server:use("Codes").redeem, entry.player, "LIMITED")
			)
		end
		local granted, refused = 0, 0
		for _, handle in handles do
			local result = finish(world, handle)
			if result == "ok" then
				granted += 1
			else
				expect(result).toBe("limit_reached")
				refused += 1
			end
		end
		expect(granted).toBe(10)
		expect(refused).toBe(8)
		local total = 0
		for _, entry in players do
			total += coins(entry.server, entry.player)
		end
		expect(total).toBe(100)
		local record = ledger(world, "limited")
		expect(record.used).toBe(10)
		expect(occupied(record)).toBe(10)
		for _, write in world.log do
			if write.store == "StudWorkShared_sim" and write.key == "Codes/cap/limited" then
				expect(occupied(write.after) <= write.after.limit).toBe(true)
			end
		end
		expect(world:errors()).toEqual({})
	end)
	it("an uncertain profile save keeps its slot and recovers without a second grant", function()
		local world = worldWith({ code("limited", { maxUses = 1 }) })
		local a, b = F.server(world), F.server(world)
		local p, other = join(world, a, 3001), join(world, b, 3002)
		world:failFor(40, function(_, store, key)
			return store == F.STORE and key == F.key(3001)
		end)
		local pending = a:spawn(a:use("Codes").redeem, p, "LIMITED")
		expect(finish(world, pending, 35)).toBe("try_later")
		expect(coins(a, p)).toBe(10)
		expect(occupied(ledger(world, "limited"))).toBe(1)
		expect(redeem(world, b, other, "LIMITED")).toBe("limit_reached")
		world:advance(15)
		expect(redeem(world, a, p, "LIMITED")).toBe("already_used")
		expect(coins(a, p)).toBe(10)
		expect(ledger(world, "limited").used).toBe(1)
		expect(next(a:section(p, "codes").pending)).toBe(nil)
		expect(F.writerViolations(world, 3001)).toEqual({})
		expect(world:errors()).toEqual({})
	end)
	it("failed reward transactions release their reservation without partial rewards", function()
		local world = worldWith({
			code("broken", {
				maxUses = 1,
				rewards = {
					{ kind = "currency", amount = 10 },
					{ kind = "item", itemId = "missing" },
				},
			}),
		})
		local a, b = F.server(world), F.server(world)
		local p, q = join(world, a, 4001), join(world, b, 4002)
		expect(redeem(world, a, p, "BROKEN")).toBe("try_later")
		expect(coins(a, p)).toBe(0)
		expect(occupied(ledger(world, "broken"))).toBe(0)
		expect(redeem(world, b, q, "BROKEN")).toBe("try_later")
		expect(coins(b, q)).toBe(0)
		expect(occupied(ledger(world, "broken"))).toBe(0)
	end)
	it("limits brute force and rejects test-only definitions in live", function()
		local world = worldWith(
			{ code("preview", { testOnly = true }) },
			{ failureLimit = 3, failureWindowSeconds = 60, lockoutSeconds = 10 }
		)
		local server = F.server(world)
		local p = join(world, server, 5001)
		expect(server.runtime.env.name()).toBe("live")
		expect(redeem(world, server, p, "PREVIEW")).toBe("invalid")
		expect(redeem(world, server, p, "wrong")).toBe("invalid")
		expect(redeem(world, server, p, "wrong")).toBe("invalid")
		expect(redeem(world, server, p, "wrong")).toBe("try_later")
		world:advance(11)
		expect(redeem(world, server, p, "wrong")).toBe("invalid")
		expect(coins(server, p)).toBe(0)
		expect(world:errors()).toEqual({})
	end)
	it("adds and disables live codes through the fake configuration snapshot", function()
		local world = worldWith(
			{},
			{ live = { enabled = true, key = "player_codes", refreshSeconds = 5, maxEntries = 32 } }
		)
		local config = StudWork.test.fakes.configService({
			values = { player_codes = { definitions = { code("live") }, disabled = {} } },
		})
		local server = F.server(world, { services = { ConfigService = config } })
		local p = join(world, server, 6001)
		expect(redeem(world, server, p, "LIVE")).toBe("ok")
		config.set("player_codes", { definitions = { code("live"), code("next") }, disabled = { "live" } })
		config.publish()
		world:advance(6)
		local q = join(world, server, 6002)
		expect(redeem(world, server, q, "LIVE")).toBe("invalid")
		expect(redeem(world, server, q, "NEXT")).toBe("ok")
		expect(coins(server, q)).toBe(10)
		expect(world:errors()).toEqual({})
	end)
	it("refuses out-of-range preferences and replicates values only to their owner", function()
		local world = worldWith()
		local acknowledgements, parts = {}, {}
		local server = F.server(world, {
			serverParts = parts,
			beforeStart = function(current)
				local part = current.require("packages/kits/player/Settings/server/init.luau").new()
				part.net = {
					Set = { On = function() end },
					Ack = {
						Fire = function(owner, ...)
							table.insert(acknowledgements, { owner = owner.UserId, values = table.pack(...) })
						end,
					},
				}
				parts.Settings = part
			end,
		})
		local a, b = join(world, server, 7001), join(world, server, 7002)
		local ran, accepted = server:action(a, "Settings", "set", "musicVolume", "slider", false, 2, "", 1)
		expect(ran).toBe(true)
		expect(accepted).toBe(false)
		expect(server:use("Settings").get(a, "musicVolume")).toBe(1)
		ran, accepted = server:action(a, "Settings", "set", "musicVolume", "slider", false, 0.35, "", 2)
		expect(ran).toBe(true)
		expect(accepted).toBe(true)
		expect(#acknowledgements).toBe(2)
		for _, ack in acknowledgements do
			expect(ack.owner).toBe(7001)
		end
		expect(acknowledgements[1].values[7]).toBe(false)
		expect(acknowledgements[2].values[7]).toBe(true)
		server:remote("StateInit", a)
		server:remote("StateInit", b)
		world:advance(3)
		expect(server.synced[a].modules.Settings.extra.values.musicVolume).toBe(0.35)
		expect(server.synced[b].modules.Settings.extra.values.musicVolume).toBe(1)
		expect(server.synced[b].modules.Settings.data).toBe(nil)
		expect(world:errors()).toEqual({})
	end)
	it("drops removed setting IDs from an old save on a second server", function()
		local world = worldWith()
		local a, b = F.server(world), F.server(world)
		local p = join(world, a, 8001)
		a:update(p, function(data)
			data.settings.values.removed = true
			data.settings.values.musicVolume = 8
		end)
		finish(world, a:spawn(a.save, a, p))
		a:leave(p)
		world:advance(10)
		local rejoined = join(world, b, 8001)
		expect(b:section(rejoined, "settings").values.removed).toBe(nil)
		expect(b:use("Settings").get(rejoined, "musicVolume")).toBe(1)
		expect(world:errors()).toEqual({})
	end)
	it("refuses a different cap policy from another deployment", function()
		local world = worldWith({ code("limited", { maxUses = 2 }) })
		local other = table.clone(world.config)
		other.config = table.clone(world.config.config)
		other.config.Codes = table.clone(world.config.config.Codes)
		other.config.Codes.definitions = { code("limited", { maxUses = 3 }) }
		local a, b = F.server(world), F.server(world, { config = other })
		local p, q = join(world, a, 9001), join(world, b, 9002)
		expect(redeem(world, a, p, "LIMITED")).toBe("ok")
		expect(redeem(world, b, q, "LIMITED")).toBe("try_later")
		expect(coins(b, q)).toBe(0)
		expect(ledger(world, "limited").limit).toBe(2)
		expect(occupied(ledger(world, "limited"))).toBe(1)
		expect(world:errors()).toEqual({})
	end)
	it("recovers a saved pending receipt after its catalog entry disappears", function()
		local world = worldWith({ code("limited", { maxUses = 1 }) })
		local a = F.server(world)
		local p = join(world, a, 9101)
		local injected = false
		local disconnect = world:watchWrites(function(write)
			local stored = if write.storeName == F.STORE then world:peek(write.storeName, write.key) else nil
			local data = stored and stored.Data
			if
				not injected
				and write.storeName == F.STORE
				and data
				and data.codes
				and data.codes.pending.limited
			then
				injected = true
				world:failFor(20, function(_, store)
					return store == "StudWorkShared_sim"
				end)
			end
		end)
		expect(redeem(world, a, p, "LIMITED")).toBe("try_later")
		disconnect()
		expect(injected).toBe(true)
		expect(coins(a, p)).toBe(10)
		expect(a:section(p, "codes").pending.limited ~= nil).toBe(true)
		a:leave(p)
		world:advance(25)
		local removed = table.clone(world.config)
		removed.config = table.clone(world.config.config)
		removed.config.Codes = table.clone(world.config.config.Codes)
		removed.config.Codes.definitions = {}
		local b = F.server(world, { config = removed })
		local rejoined = join(world, b, 9101)
		assert(world:advanceUntil(function()
			return next(b:section(rejoined, "codes").pending) == nil
		end, 60, 0.1))
		expect(coins(b, rejoined)).toBe(10)
		expect(ledger(world, "limited").used).toBe(1)
		expect(redeem(world, b, rejoined, "LIMITED")).toBe("invalid")
		expect(coins(b, rejoined)).toBe(10)
		expect(F.writerViolations(world, 9101)).toEqual({})
		expect(world:errors()).toEqual({})
	end)
end)
