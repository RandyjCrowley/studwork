--!nocheck
-- (v1.6.0 dogfood) Sim players vs game code: typeof(simPlayer) is "Instance", so code that builds
-- leaderstats under the player (the playbook's step 8 recipe) must just work, unguarded; and
-- server:action calls a module action as a player, returning (ok, result | reason).
local F = require(script.Parent.Fixtures)

local function boot()
	local world = F.world()
	local server = F.server(world)
	return world, server
end

local function joinLoaded(world, server, userId)
	local p = server:join(userId)
	world:advanceUntil(function()
		return server:isLoaded(p)
	end, 30)
	return p
end

-- The playbook's leaderstats recipe (docs/agents/adopt-existing-game.md step 8), written exactly
-- as game code would be, with the server's own globals (Instance, typeof): no sim guard.
local function showCoins(G, player, coins)
	if G.typeof(player) ~= "Instance" then
		error("a sim player must look like an Instance")
	end
	local stats = player:FindFirstChild("leaderstats")
	if stats == nil then
		stats = G.Instance.new("Folder")
		stats.Name = "leaderstats"
		stats.Parent = player
	end
	local value = stats:FindFirstChild("Coins")
	if value == nil then
		value = G.Instance.new("IntValue")
		value.Name = "Coins"
		value.Parent = stats
	end
	value.Value = coins
end

describe("sim players support the leaderstats recipe", function()
	it(
		"Folder + IntValue parented to the player, found again by name, updated from CurrencyChanged",
		function()
			local world, server = boot()
			local p = joinLoaded(world, server, 1)
			local G = server.globals
			local Economy = server:use("Economy")
			Economy.signals.CurrencyChanged:Connect(function(player, currency, balance)
				if currency == "Coins" then
					showCoins(G, player, balance)
				end
			end)
			showCoins(G, p, Economy.balance(p))
			expect(p:FindFirstChild("leaderstats").Name).toBe("leaderstats")
			expect(p.leaderstats.Coins.Value).toBe(0)
			expect(Economy.grant(p, 42, "test")).toBe(true)
			world:advance(0.1)
			expect(p.leaderstats.Coins.Value).toBe(42)
			expect(#p:GetChildren()).toBe(1)
			expect(#p.leaderstats:GetChildren()).toBe(1) -- reused, not duplicated
			expect(p.leaderstats.Coins:IsA("IntValue")).toBe(true)
			expect(p.leaderstats.Coins:IsA("ValueBase")).toBe(true)
			expect(p.leaderstats.Coins:IsDescendantOf(p)).toBe(true)
			expect(#world:errors()).toBe(0)
		end
	)

	it("the value classes, Instance.new(class, parent), re-parenting, Destroy and Changed", function()
		local world, server = boot()
		local p = joinLoaded(world, server, 2)
		local I = server.globals.Instance
		local stats = I.new("Folder", p)
		stats.Name = "leaderstats"
		local n = I.new("NumberValue", stats)
		local s = I.new("StringValue", stats)
		local i = I.new("IntValue", stats)
		expect(n.Value).toBe(0)
		expect(s.Value).toBe("")
		i.Value = 2.6
		expect(i.Value).toBe(3) -- IntValue rounds like Roblox
		local seen = {}
		n.Changed:Connect(function(v)
			table.insert(seen, v)
		end)
		n.Value = 1.5
		world:advance(0.1)
		expect(seen).toEqual({ 1.5 })
		expect(p:FindFirstChild("NumberValue", true)).toBe(n)
		expect(stats:FindFirstChildOfClass("StringValue")).toBe(s)
		s.Parent = p
		expect(#stats:GetChildren()).toBe(2)
		expect(p:FindFirstChild("StringValue")).toBe(s)
		stats:Destroy()
		expect(p:FindFirstChild("leaderstats")).toBe(nil)
		expect(n.Parent).toBe(nil)
		expect(function()
			I.new("Part")
		end).toThrow("is not simulated")
	end)

	it("WaitForChild waits in a server thread (sim time) and honours its timeout", function()
		local world, server = boot()
		local p = joinLoaded(world, server, 3)
		local I = server.globals.Instance
		local found = server:spawn(function()
			return p:WaitForChild("leaderstats")
		end)
		local missing = server:spawn(function()
			return p:WaitForChild("nope", 2)
		end)
		world:advance(0.5)
		expect(found.done).toBe(false)
		local stats = I.new("Folder")
		stats.Name = "leaderstats"
		stats.Parent = p
		world:advance(0.5)
		expect(found.done).toBe(true)
		expect(found.result).toBe(stats)
		world:advance(2)
		expect(missing.done).toBe(true)
		expect(missing.result).toBe(nil)
		-- on the spec's own thread it never yields
		expect(p:WaitForChild("leaderstats")).toBe(stats)
		expect(p:WaitForChild("nope", 1)).toBe(nil)
	end)
end)

describe("server:action(player, module, action, ...) -> (ok, result | reason)", function()
	it("runs the action as the player (a yielding handler included) and returns (true, result)", function()
		local world, server = boot()
		local a = joinLoaded(world, server, 11)
		local b = joinLoaded(world, server, 12)
		world:setFriends(11, 12, true)
		local Inventory = server:use("Inventory")
		local item = Inventory.add(a, "rock", { source = "test" })
		local ok, result = server:action(a, "Inventory", "gift", 12, item.uid)
		expect(ok).toBe(true)
		expect(result).toBe(nil) -- the gift handler returns nothing
		world:advanceUntil(function()
			return #Inventory.list(b) == 1
		end, 30)
		expect(#Inventory.list(b)).toBe(1)
		expect(Inventory.get(a, item.uid)).toBe(nil)
	end)

	it("returns (false, reason) for a player who left, isn't loaded or is rate limited", function()
		local world, server = boot()
		local p = joinLoaded(world, server, 21)
		local ref = server:ref("Inventory")
		local results = {}
		for _ = 1, 5 do
			local ok, reason = server:action(p, ref, "gift", 22, "x")
			table.insert(results, if ok then "ok" else reason)
		end
		expect(results[1]).toBe("ok")
		expect(table.find(results, "rate_limited") ~= nil).toBe(true) -- gift: burst 3
		world.latency = 10 -- its save is still loading
		local unloaded = server:join(23)
		local ok2, reason2 = server:action(unloaded, "Inventory", "gift", 22, "x")
		expect(ok2).toBe(false)
		expect(reason2).toBe("not_loaded")
		server:leave(p)
		local ok3, reason3 = server:action(p, "Inventory", "gift", 22, "x")
		expect(ok3).toBe(false)
		expect(reason3).toBe("left")
	end)

	it("errors for an unknown action or a module that isn't enabled", function()
		local world, server = boot()
		local p = joinLoaded(world, server, 31)
		expect(function()
			server:action(p, "Inventory", "nope")
		end).toThrow("has no action 'nope'")
		expect(function()
			server:action(p, "Rarity", "roll", "Egg")
		end).toThrow("no module Rarity")
	end)
end)
