--!strict
--[[
	The quests demo's server module (the game's implicit module, module-api.md §7 C4), through ctx
	only:
	  - builds the world (./World.luau, from Tuning.luau) at start where engine instances exist
	  - coin spots ("DemoCoin"): a touch grants Tuning.coinsPerTouch Coins and counts
	    Quests.progress(player, "coinTouched")
	  - DemoGuide: Quests.progress(player, "guideVisited") and Quests.grant(player, "guideGift")
	  - DemoBoard: Quests.progress(player, "boardVisited")
	  - DemoTower: Quests.progress(player, "towerVisited") and Goals.complete(player, "reachTower")
	  - after the goal chain: Goals.setNext -> "game.next.dailies", pointing at the board
	  - Studio-only console (StudWorkConsole; refused unless ctx.isStudio; the console is
	    server-only): questsdemo progress <key> <n> [userId], questsdemo finishchain [userId],
	    questsdemo event (starts demoEvent), questsdemo grant [userId]
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local Quests = require(Modules:WaitForChild("Quests"):WaitForChild("module"))
local Goals = require(Modules:WaitForChild("Goals"):WaitForChild("module"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local Tuning = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"):WaitForChild("Tuning"))
local World = require(script.World)

local EVENT_ID = "demoEvent"
local GIFT_QUEST = "guideGift"
local TOWER_GOAL = "reachTower"
local STUDIO_ONLY = "is Studio-only"

local QuestsDemo = {}

local ctx: any = nil
local players: { [any]: boolean } = {}

local function findPlayer(userId: any): any
	local id = tonumber(userId)
	for p in players do
		if id == nil or p.UserId == id then
			return p
		end
	end
	return nil
end

local function playerFromHit(hit: any): any
	local character = hit and hit:FindFirstAncestorOfClass("Model")
	return character and Players:GetPlayerFromCharacter(character)
end

-- Studio-only console commands: registered everywhere (so `help` lists them), refused unless Studio
local function registerConsole()
	ctx.console.register("progress", function(_caller: any, key: any, amount: any, userId: any): string
		if not ctx.isStudio then
			return `questsdemo progress {STUDIO_ONLY}`
		end
		if type(key) ~= "string" then
			return "usage: questsdemo progress <key> <n> [userId]"
		end
		local p = findPlayer(userId)
		if p == nil then
			return "no loaded player"
		end
		local moved = ctx.deps[Quests].progress(p, key, tonumber(amount) or 1)
		return `progress {key}: {if moved then "moved" else "nothing matched"}`
	end, "questsdemo progress <key> <n> [userId]: add to a quest counter (Studio)")

	ctx.console.register("finishchain", function(_caller: any, userId: any): string
		if not ctx.isStudio then
			return `questsdemo finishchain {STUDIO_ONLY}`
		end
		local p = findPlayer(userId)
		if p == nil then
			return "no loaded player"
		end
		local accepted = 0
		for _, goal in GameConfig.config.Goals.chain do
			if ctx.deps[Goals].complete(p, goal.id) then
				accepted += 1
			end
		end
		return `finishchain: {accepted} goal(s) accepted`
	end, "questsdemo finishchain [userId]: mark every goal done (Studio)")

	ctx.console.register("event", function(_caller: any): string
		if not ctx.isStudio then
			return `questsdemo event {STUDIO_ONLY}`
		end
		local started = ctx.events.trigger(EVENT_ID)
		return `{EVENT_ID}: {if started then "started" else "not started (unknown or already running)"}`
	end, "questsdemo event: start demoEvent now (Studio)")

	ctx.console.register("grant", function(_caller: any, userId: any): string
		if not ctx.isStudio then
			return `questsdemo grant {STUDIO_ONLY}`
		end
		local p = findPlayer(userId)
		if p == nil then
			return "no loaded player"
		end
		local ok, reason = ctx.deps[Quests].grant(p, GIFT_QUEST)
		return `{GIFT_QUEST}: {if ok then "granted" else tostring(reason)}`
	end, "questsdemo grant [userId]: hand out the guide's quest (Studio)")
end

local function connectWorld(folder: Instance)
	local quests = ctx.deps[Quests]
	local goals = ctx.deps[Goals]
	local economy = ctx.deps[Economy]
	local lastTouch: { [any]: { [any]: number } } = {}
	local function cooled(player: any, spot: any): boolean
		local now = os.clock()
		local byPlayer = lastTouch[player] or {}
		lastTouch[player] = byPlayer
		local last = byPlayer[spot]
		if last ~= nil and now - last < Tuning.touchCooldown then
			return false
		end
		byPlayer[spot] = now
		return true
	end
	local function onTouch(instance: Instance, fn: (player: any) -> ())
		if not instance:IsA("BasePart") then
			return
		end
		(instance :: BasePart).Touched:Connect(function(hit: BasePart)
			local player = playerFromHit(hit)
			if player ~= nil and players[player] and cooled(player, instance) then
				fn(player)
			end
		end)
	end
	for _, child in folder:GetChildren() do
		if string.sub(child.Name, 1, 8) == "DemoCoin" then
			onTouch(child, function(player: any)
				economy.grant(player, Tuning.coinsPerTouch, "demo:coin")
				quests.progress(player, "coinTouched")
				ctx.data.update(player, function(s: any)
					s.coinTouches = (s.coinTouches or 0) + 1
				end)
			end)
		end
	end
	local guide = folder:FindFirstChild("DemoGuide")
	if guide then
		onTouch(guide, function(player: any)
			quests.progress(player, "guideVisited")
			quests.grant(player, GIFT_QUEST)
		end)
	end
	local board = folder:FindFirstChild("DemoBoard")
	if board then
		onTouch(board, function(player: any)
			quests.progress(player, "boardVisited")
		end)
	end
	local tower = folder:FindFirstChild("DemoTower")
	if tower then
		onTouch(tower, function(player: any)
			quests.progress(player, "towerVisited")
			goals.complete(player, TOWER_GOAL)
		end)
	end
	ctx.lifecycle.onPlayerRemoving(function(player: any)
		lastTouch[player] = nil
	end)
end

function QuestsDemo.init(context: any)
	ctx = context
	registerConsole()
end

function QuestsDemo.start(_context: any)
	ctx.data.onLoaded(function(player: any)
		players[player] = true
	end)
	ctx.lifecycle.onPlayerRemoving(function(player: any)
		players[player] = nil
	end)

	-- after the first-session chain: point at the board for today's quests
	ctx.deps[Goals].setNext(function(_player: any): any
		return { text = "game.next.dailies", target = { tag = "DemoBoard" } }
	end)

	if World.canBuild() then
		connectWorld(World.build())
	else
		ctx.log.info("no engine instances here (a spec or the sim): the demo world isn't built")
	end
end

return QuestsDemo
