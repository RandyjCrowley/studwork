--!strict
--[[
	The game's server module (the game's implicit module, module-api.md §7 C4). What
	src/server/Main.server.luau did under v1.2, through ctx only (tools/new-game keeps the lines
	of the modules you chose):
	  - Collect: touching the block rolls the free "Block" table (Rarity), counts blockTouches in -- @if Rarity
	    the game's own section, funnel FirstCollect -- @if Rarity
	  - each collect feeds the Quests counter "collected" (Balance.luau's collect quests) -- @if Quests
	  - funnel steps FirstUpgrade / FirstRebirth from the kit signals -- @if Upgrades|Rebirth
	  - Offline / Streak / Friends hooks (prints) -- @if Offline|Streak|Friends
	  - live events CoinRain (Economy) and SecretDrop (Inventory) -- @if Economy|Inventory
	  - Robux product EggRoll (paid roll of "Egg"; a restricted player gets a fixed crystal) -- @if Rarity,Inventory
	  - Robux product CoinPack and the DoubleCoins pass -- @if Economy
	  - the "gift" mail kind -- @if Mail
	  - Studio console (StudWorkConsole): `giftme [itemId] [userId]` (Mail), `fill [userId]`, `free [userId]` (Inventory) -- @if Inventory|Mail
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module")) -- @if Rarity
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module")) -- @if Inventory
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module")) -- @if Economy
local Upgrades = require(Modules:WaitForChild("Upgrades"):WaitForChild("module")) -- @if Upgrades
local Rebirth = require(Modules:WaitForChild("Rebirth"):WaitForChild("module")) -- @if Rebirth
local Offline = require(Modules:WaitForChild("Offline"):WaitForChild("module")) -- @if Offline
local Streak = require(Modules:WaitForChild("Streak"):WaitForChild("module")) -- @if Streak
local Friends = require(Modules:WaitForChild("Friends"):WaitForChild("module")) -- @if Friends
local Mail = require(Modules:WaitForChild("Mail"):WaitForChild("module")) -- @if Mail
local Quests = require(Modules:WaitForChild("Quests"):WaitForChild("module")) -- @if Quests
local Tuning = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"):WaitForChild("Tuning")) -- @if Economy

local TOUCH_COOLDOWN = 1.5 -- seconds between block rewards per player (a feel number for this game only)

local Sandbox = {}

-- @if Inventory|Mail
-- The player a console command acts on. A handler's `player` is nil from the Studio command bar
-- and from h:console, so a command takes the target's userId as its last argument; without one it
-- acts on the first player in the server.
local function targetPlayer(userId: string?): Player?
	local id = tonumber(userId)
	if id ~= nil then
		return Players:GetPlayerByUserId(id)
	end
	return Players:GetPlayers()[1]
end
-- @end

-- @if Inventory|Economy|Mail
function Sandbox.init(ctx: any)
	-- Robux products: receipt-safe, data-only handlers. Everything goes through `tx` inside the
	-- transaction that records the receipt; erroring (or tx.retryLater) grants nothing. An
	-- unknown policy is retried by Compliance itself.
	-- @if Rarity,Inventory
	ctx.shop.onProduct("EggRoll", function(tx: any)
		local def, info = tx.use(Rarity).roll("Egg")
		if info.reason == "restricted" then
			-- The client never prompts restricted players, but if a purchase still arrives they
			-- must not pay for nothing: grant a fixed, non-random item instead of a roll.
			assert(tx.use(Inventory).addItem("crystal"), "inventory full")
			return
		end
		assert(def and info.ok, info.reason or "roll failed") -- e.g. inventory full: retried later
	end)
	-- @end
	-- @if Economy
	ctx.shop.onProduct("CoinPack", function(tx: any)
		assert(tx.use(Economy).grant(Tuning.coinPackCoins), "grant failed")
	end)
	ctx.shop.onPassOwned("DoubleCoins", function(player: Player)
		ctx.deps[Economy].addMultiplier(player, "pass:DoubleCoins", Tuning.doubleCoinsMultiplier)
	end)

	-- Live events
	ctx.events.schedule("CoinRain", nil, function(event: any)
		local mult = (event.data and event.data.multiplier) or 2
		for _, player in Players:GetPlayers() do
			ctx.deps[Economy].addMultiplier(player, "event:CoinRain", mult, event.endsAt)
		end
	end)
	-- @end
	-- @if Inventory
	ctx.events.schedule("SecretDrop", nil, function(event: any)
		for _, player in Players:GetPlayers() do
			ctx.deps[Inventory].add(
				player,
				(event.data and event.data.itemId) or "void",
				{ source = "event" }
			)
		end
	end)
	-- @end

	-- @if Inventory|Mail
	-- Studio-only test hooks. A command is typed with this module's lower-case name in front
	-- (StudWorkConsole:Invoke("sandbox", "giftme", itemId?) and friends; Invoke("help") lists them all).
	-- A handler's first parameter is the calling player, which is nil from the command bar and
	-- h:console: target a user with a userId argument (targetPlayer). Name it _player (selene).
	if ctx.isStudio then
		-- @if Mail
		ctx.console.register("giftme", function(_player: any, itemId: string?, userId: string?): string
			local player = targetPlayer(userId)
			if player == nil then
				return "no player"
			end
			local ok = ctx.deps[Mail].send(player.UserId, "gift", { itemId = itemId or "comet" })
			return "sent=" .. tostring(ok)
		end, "sandbox giftme [itemId] [userId]: mail a player a gift (Studio)")
		-- @end
		-- @if Inventory
		ctx.console.register("fill", function(_player: any, userId: string?): string
			local player = targetPlayer(userId)
			if player == nil then
				return "no player"
			end
			local inventory = ctx.deps[Inventory]
			while inventory.count(player) < inventory.cap(player) do
				if inventory.add(player, "pebble", { source = "test" }) == nil then
					break
				end
			end
			return `inventory {inventory.count(player)}/{inventory.cap(player)}`
		end, "sandbox fill [userId]: fill a player's inventory to the cap (Studio)")
		ctx.console.register("free", function(_player: any, userId: string?): string
			local player = targetPlayer(userId)
			if player == nil then
				return "no player"
			end
			local inventory = ctx.deps[Inventory]
			local first = inventory.list(player)[1]
			if first then
				inventory.remove(player, first.uid, "test")
			end
			return `inventory {inventory.count(player)}/{inventory.cap(player)}`
		end, "sandbox free [userId]: remove one of a player's items (Studio)")
		-- @end
	end
	-- @end
end
-- @end

function Sandbox.start(ctx: any)
	-- Collect: touching the block rolls the free "Block" table.
	local lastTouch: { [Player]: number } = {}
	local world = Workspace:FindFirstChild("SandboxWorld")
	local block = world and world:FindFirstChild("CollectBlock")
	if block and block:IsA("BasePart") then
		block.Touched:Connect(function(hit: BasePart)
			local character = hit:FindFirstAncestorOfClass("Model")
			local player = character and Players:GetPlayerFromCharacter(character)
			if player == nil then
				return
			end
			local now = os.clock()
			local last = lastTouch[player]
			if last and now - last < TOUCH_COOLDOWN then
				return
			end
			lastTouch[player] = now
			local collected = true
			-- @if Rarity,Inventory
			local def, info = ctx.deps[Rarity].roll("Block", player, nil, { grant = true, reason = "block" })
			collected = def ~= nil and info.ok
			-- @end
			if collected then
				ctx.data.update(player, function(s: any)
					s.blockTouches = (s.blockTouches or 0) + 1
				end)
				ctx.analytics.funnel(player, "FirstCollect")
				-- @if Quests
				if ctx.isEnabled(Quests) then -- Quests is optional: the game may drop it
					ctx.deps[Quests].progress(player, "collected", 1)
				end
				-- @end
			end
		end)
	else
		ctx.log.warn("no Workspace.SandboxWorld.CollectBlock (World.build() runs before StudWork.start)")
	end
	ctx.lifecycle.onPlayerRemoving(function(player: Player)
		lastTouch[player] = nil
	end)

	-- @if Upgrades
	ctx.deps[Upgrades].signals.UpgradePurchased:Connect(function(player: Player)
		ctx.analytics.funnel(player, "FirstUpgrade")
	end)
	-- @end
	-- @if Rebirth
	ctx.deps[Rebirth].signals.Rebirthed:Connect(function(player: Player)
		ctx.analytics.funnel(player, "FirstRebirth")
	end)
	-- @end

	-- @if Offline
	-- Offline: the kit auto-pays (Offline config autoPay); the game just tells the player.
	ctx.deps[Offline].onReturn(function(player: Player, secondsAway: number)
		print(string.format("[sandbox] %s was away %ds", player.Name, secondsAway))
	end)
	-- @end
	-- @if Streak
	ctx.deps[Streak].onDaily(function(player: Player, day: number)
		print(string.format("[sandbox] %s streak day %d", player.Name, day))
	end)
	-- @end
	-- @if Friends
	ctx.deps[Friends].onCoPlay(function(player: Player, friends: { any }, kind: string)
		print(string.format("[sandbox] %s co-play (%s) with %d friend(s)", player.Name, kind, #friends))
	end)
	-- @end

	-- @if Mail,Inventory
	-- Mail: a game gift kind. Idempotent by message id; a full inventory returns false, so the
	-- gift waits in the player's mailbox (HUD badge) until they claim it with room to spare.
	ctx.deps[Mail].onReceive("gift", function(player: Player, payload: any, info: any): boolean
		if type(payload.itemId) ~= "string" then
			error("gift without itemId")
		end
		local inventory = ctx.deps[Inventory]
		if inventory.count(player) >= inventory.cap(player) then
			return false
		end
		local key = "gift:" .. info.id
		for _, item in inventory.list(player) do
			if item.meta and item.meta.mail == key then
				return true -- already granted by an earlier run of this message
			end
		end
		local meta: { [string]: string | number | boolean } = { mail = key }
		return inventory.add(player, payload.itemId, { source = "gift", meta = meta }) ~= nil
	end)
	-- @end
end

return Sandbox
