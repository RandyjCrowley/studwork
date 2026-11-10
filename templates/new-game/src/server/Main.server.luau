--!strict
--[[
	Sandbox server: the minimal "touch a block -> get an item -> it earns" game.
	Exercises core: Rarity, Inventory (+auto display on Plot), Economy, Upgrades, Rebirth,
	Offline, Streak, Friends, Events, Shop, Policy, Data (per-game table), Analytics.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = require(ReplicatedStorage:WaitForChild("Core"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local World = require(script.Parent.World)

local TOUCH_COOLDOWN = 1.5 -- seconds between block rewards per player (sandbox-only feel number)

local block = World.build()

Core.start(Config)

-- Collect: touching the block rolls the free "Block" table.
local lastTouch: { [Player]: number } = {}
block.Touched:Connect(function(hit)
	local character = hit:FindFirstAncestorOfClass("Model")
	local player = character and Players:GetPlayerFromCharacter(character)
	if player == nil then
		return
	end
	local now = os.clock()
	if lastTouch[player] and now - lastTouch[player] < TOUCH_COOLDOWN then
		return
	end
	lastTouch[player] = now
	local def, info = Core.Rarity.roll("Block", player, nil, { grant = true, reason = "block" })
	if def and info.ok then
		Core.Data.updateGame(player, function(g)
			g.blockTouches = (g.blockTouches or 0) + 1
		end)
		Core.Analytics.funnel(player, "FirstCollect")
	end
end)
Players.PlayerRemoving:Connect(function(player)
	lastTouch[player] = nil
end)

Core.Signals.UpgradePurchased:Connect(function(player)
	Core.Analytics.funnel(player, "FirstUpgrade")
end)
Core.Signals.Rebirthed:Connect(function(player)
	Core.Analytics.funnel(player, "FirstRebirth")
end)

-- Offline: core auto-pays (balance.offline.autoPay); the game just tells the player.
Core.Offline.onReturn(function(player, secondsAway)
	print(string.format("[sandbox] %s was away %ds", player.Name, secondsAway))
end)

Core.Streak.onDaily(function(player, day)
	print(string.format("[sandbox] %s streak day %d", player.Name, day))
end)

Core.Friends.onCoPlay(function(player, friends, kind)
	print(string.format("[sandbox] %s co-play (%s) with %d friend(s)", player.Name, kind, #friends))
end)

-- Live events
Core.Events.schedule("CoinRain", nil, function(ctx)
	local mult = (ctx.data and ctx.data.multiplier) or 2
	for _, player in Players:GetPlayers() do
		Core.Economy.addMultiplier(player, "event:CoinRain", mult, ctx.endsAt)
	end
end)
Core.Events.schedule("SecretDrop", nil, function(ctx)
	for _, player in Players:GetPlayers() do
		Core.Inventory.add(player, (ctx.data and ctx.data.itemId) or "void", { source = "event" })
	end
end)

-- Robux roll (paid random item). Shop records the receipt; Rarity refuses restricted players.
Core.Shop.onProduct("EggRoll", function(player, _receipt)
	if not Core.Policy.isKnown(player) then
		return false -- policy lookup still running (e.g. a receipt replayed on join): retry later
	end
	if Core.Policy.paidRandomRestricted(player) then
		-- The client never prompts restricted players, but if a purchase still arrives (policy
		-- changed, prompt from elsewhere) they must not pay for nothing: grant a fixed,
		-- non-random item instead of a roll.
		return Core.Inventory.add(player, "crystal", { source = "egg_fallback" }) ~= nil
	end
	local def, info = Core.Rarity.roll("Egg", player, nil, { paid = true, grant = true, reason = "egg" })
	return def ~= nil and info.ok
end)
Core.Shop.onProduct("CoinPack", function(player, _receipt)
	return Core.Economy.grant(player, 1000, "coinpack")
end)
Core.Shop.onPassOwned("DoubleCoins", function(player)
	Core.Economy.addMultiplier(player, "pass:DoubleCoins", 2)
end)
