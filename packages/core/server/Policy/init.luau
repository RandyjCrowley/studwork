--!strict
--[[
	Core.Policy. OWNED BY AGENT C (core/c-items). Public API: Types.PolicyAPI.

	PHASE 0 STUB: one PolicyService lookup per player, restricted = true until known or on
	failure (fail closed). Agent C adds retries, Studio override for testing restricted players,
	and replication of the flag (ctx.setReplicated(player, "paidRandomRestricted", value)).
]]

local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")

local Policy = {}

local ctx: any = nil
local restricted: { [Player]: boolean } = {}

local function lookup(player: Player)
	local ok, info = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	local value = true
	if ok and type(info) == "table" then
		value = info.ArePaidRandomItemsRestricted == true
	end
	if player.Parent == Players then
		restricted[player] = value
		ctx.setReplicated(player, "paidRandomRestricted", value)
	end
end

function Policy.init(context: any)
	ctx = context
end

function Policy.start()
	Players.PlayerAdded:Connect(function(player)
		lookup(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		restricted[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(lookup, player)
	end
end

function Policy.paidRandomRestricted(player: Player): boolean
	local value = restricted[player]
	if value == nil then
		return true
	end
	return value
end

return Policy
