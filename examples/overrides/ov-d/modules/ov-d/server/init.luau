--!strict
--[[
	The game's server module (the game's implicit module, module-api.md §7 C4). What
	src/server/Main.server.luau did under v1.2, through ctx only (tools/new-game keeps the lines
	of the modules you chose):
	  - Collect: touching the block rolls the free "Block" table (Rarity), counts blockTouches in
	    the game's own section, funnel FirstCollect
	  - live events CoinRain (Economy) and SecretDrop (Inventory)
	  - Robux product EggRoll (paid roll of "Egg"; a restricted player gets a fixed crystal)
	  - Studio console (StudWorkConsole): `giftme [itemId]` (Mail), `fill`, `free` (Inventory)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))

local TOUCH_COOLDOWN = 1.5 -- seconds between block rewards per player (sandbox-only feel number)

local Sandbox = {}

local function firstPlayer(): Player?
	return Players:GetPlayers()[1]
end

function Sandbox.init(ctx: any)
	-- Robux products: receipt-safe, data-only handlers. Everything goes through `tx` inside the
	-- transaction that records the receipt; erroring (or tx.retryLater) grants nothing. An
	-- unknown policy is retried by Compliance itself (M4).
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
			local collected = true
			local def, info = ctx.deps[Rarity].roll("Block", player, nil, { grant = true, reason = "block" })
			collected = def ~= nil and info.ok
			if collected then
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
end

return Sandbox
