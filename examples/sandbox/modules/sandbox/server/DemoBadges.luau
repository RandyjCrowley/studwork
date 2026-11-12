--!strict
--[[
	Sandbox demo hook for the Badges module (docs/framework/kits/badges.md). Required from
	server/init.luau, which calls `init(ctx)` and `start(ctx)`; does nothing when the game leaves
	Badges out of GameConfig.modules.
	  - the first item a player collects awards the manual badge `firstCollect` (config.Badges in
	    src/shared/Config/Balance.luau; its id is the placeholder 0, so it is recorded, never sent)
	  - BadgeAwarded is logged (it fires only once Roblox confirmed a badge)
	  - Studio console: `sandbox badge [key] [userId]` awards a badge by hand
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Badges = require(Modules:WaitForChild("Badges"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))

local FIRST_COLLECT = "firstCollect"

local DemoBadges = {}

local function award(ctx: any, player: any, key: string): string
	local ok, result = pcall(ctx.deps[Badges].award, player, key)
	if not ok then
		return `no badge '{key}' in config.Badges.badges`
	end
	return if result then `recorded {key}` else `{key} was already recorded`
end

function DemoBadges.init(ctx: any)
	if not ctx.isEnabled(Badges) or not ctx.isStudio then
		return
	end
	ctx.console.register("badge", function(_player: any, key: string?, userId: string?): string
		local id = tonumber(userId)
		local target = nil
		for _, p in game:GetService("Players"):GetPlayers() do
			if id == nil or p.UserId == id then
				target = p
				break
			end
		end
		if target == nil then
			return "no player"
		end
		return award(ctx, target, key or FIRST_COLLECT)
	end, "sandbox badge [key] [userId]: award a badge by hand (Studio)")
end

function DemoBadges.start(ctx: any)
	if not ctx.isEnabled(Badges) then
		return
	end
	local badges = ctx.deps[Badges]
	badges.signals.BadgeAwarded:Connect(function(player: any, key: string, badgeId: number)
		ctx.log.info(`badge {key} ({badgeId}) confirmed for user {player.UserId}`)
	end)
	if ctx.isEnabled(Inventory) then
		ctx.deps[Inventory].signals.ItemAdded:Connect(function(player: any)
			if not pcall(badges.has, player, FIRST_COLLECT) then
				return -- the game's config has no firstCollect badge
			end
			if not badges.has(player, FIRST_COLLECT) then
				award(ctx, player, FIRST_COLLECT)
			end
		end)
	end
end

return DemoBadges
