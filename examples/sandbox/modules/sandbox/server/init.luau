--!strict
--[[
	Sandbox server module (the game's implicit module, module-api.md §7 C4). What
	src/server/Main.server.luau did under v1.2, through ctx only:
	  - Collect: touching the block rolls the free "Block" table (Rarity), counts blockTouches in
	    the sandbox's own section, funnel FirstCollect; FirstUpgrade / FirstRebirth from signals
	  - Offline / Streak / Friends hooks (prints), live events CoinRain and SecretDrop
	  - Robux products EggRoll (paid roll of "Egg"; a restricted player gets a fixed crystal) and
	    CoinPack, the DoubleCoins pass, the "gift" mail kind
	  - Studio console (StudWorkConsole): `sandbox giftme [itemId]`, `sandbox fill`, `sandbox free`
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local Upgrades = require(Modules:WaitForChild("Upgrades"):WaitForChild("module"))
local Rebirth = require(Modules:WaitForChild("Rebirth"):WaitForChild("module"))
local Offline = require(Modules:WaitForChild("Offline"):WaitForChild("module"))
local Streak = require(Modules:WaitForChild("Streak"):WaitForChild("module"))
local Friends = require(Modules:WaitForChild("Friends"):WaitForChild("module"))
local Mail = require(Modules:WaitForChild("Mail"):WaitForChild("module"))
local Tuning = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"):WaitForChild("Tuning"))

local TOUCH_COOLDOWN = 1.5 -- seconds between block rewards per player (sandbox-only feel number)

local Sandbox = {}

local function firstPlayer(): Player?
	return Players:GetPlayers()[1]
end

function Sandbox.init(ctx: any)
	-- Robux products: receipt-safe, data-only handlers. Everything goes through `tx` inside the
	-- transaction that records the receipt; erroring (or tx.retryLater) grants nothing. An
	-- unknown policy is retried by Compliance itself.
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
	ctx.events.schedule("SecretDrop", nil, function(event: any)
		for _, player in Players:GetPlayers() do
			ctx.deps[Inventory].add(
				player,
				(event.data and event.data.itemId) or "void",
				{ source = "event" }
			)
		end
	end)

	-- Studio-only test hooks (StudWorkConsole:Invoke("sandbox", "giftme", itemId?) and friends)
	if ctx.isStudio then
		ctx.console.register("giftme", function(_player: any, itemId: string?): string
			local player = firstPlayer()
			if player == nil then
				return "no player"
			end
			local ok = ctx.deps[Mail].send(player.UserId, "gift", { itemId = itemId or "comet" })
			return "sent=" .. tostring(ok)
		end, "sandbox giftme [itemId]: mail yourself a gift (Studio)")
		ctx.console.register("fill", function(): string
			local player = firstPlayer()
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
		end, "sandbox fill: fill your inventory to the cap (Studio)")
		ctx.console.register("free", function(): string
			local player = firstPlayer()
			if player == nil then
				return "no player"
			end
			local inventory = ctx.deps[Inventory]
			local first = inventory.list(player)[1]
			if first then
				inventory.remove(player, first.uid, "test")
			end
			return `inventory {inventory.count(player)}/{inventory.cap(player)}`
		end, "sandbox free: remove one item (Studio)")
	end
end

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
			local def, info = ctx.deps[Rarity].roll("Block", player, nil, { grant = true, reason = "block" })
			if def and info.ok then
				ctx.data.update(player, function(s: any)
					s.blockTouches = (s.blockTouches or 0) + 1
				end)
				ctx.analytics.funnel(player, "FirstCollect")
			end
		end)
	else
		ctx.log.warn("no Workspace.SandboxWorld.CollectBlock (World.build() runs before StudWork.start)")
	end
	ctx.lifecycle.onPlayerRemoving(function(player: Player)
		lastTouch[player] = nil
	end)

	ctx.deps[Upgrades].signals.UpgradePurchased:Connect(function(player: Player)
		ctx.analytics.funnel(player, "FirstUpgrade")
	end)
	ctx.deps[Rebirth].signals.Rebirthed:Connect(function(player: Player)
		ctx.analytics.funnel(player, "FirstRebirth")
	end)

	-- Offline: the kit auto-pays (Offline config autoPay); the game just tells the player.
	ctx.deps[Offline].onReturn(function(player: Player, secondsAway: number)
		print(string.format("[sandbox] %s was away %ds", player.Name, secondsAway))
	end)
	ctx.deps[Streak].onDaily(function(player: Player, day: number)
		print(string.format("[sandbox] %s streak day %d", player.Name, day))
	end)
	ctx.deps[Friends].onCoPlay(function(player: Player, friends: { any }, kind: string)
		print(string.format("[sandbox] %s co-play (%s) with %d friend(s)", player.Name, kind, #friends))
	end)

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
end

return Sandbox
