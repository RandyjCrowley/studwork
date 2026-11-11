--!strict
--[[
	The game's server module (the game's implicit module, module-api.md §7 C4). What
	src/server/Main.server.luau did under v1.2, through ctx only (tools/new-game keeps the lines
	of the modules you chose):
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local TOUCH_COOLDOWN = 1.5 -- seconds between block rewards per player (sandbox-only feel number)

local Sandbox = {}

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
