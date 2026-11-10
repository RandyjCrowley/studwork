--!strict
--[[
	Core.Policy. OWNED BY AGENT C (core/c-items). Public API: Types.PolicyAPI.

	paidRandomRestricted(player) -> PolicyService ArePaidRandomItemsRestricted for the player.
	FAIL CLOSED: true until the lookup succeeds, and true if every attempt fails.
	Lookup: PolicyService:GetPolicyInfoForPlayerAsync, up to MAX_ATTEMPTS tries with exponential
	backoff (BASE_DELAY_SEC * 2^(attempt-1), capped at MAX_DELAY_SEC); stops if the player leaves.
	Replicates with ctx.setReplicated(player, "paidRandomRestricted", v) (true first, then the
	known value). Studio only: console `restrict <true|false|clear> [userId]` overrides the value.
	State is cleared on PlayerRemoving.
]]

local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")

local Policy = {}

local MAX_ATTEMPTS = 4
local BASE_DELAY_SEC = 1
local MAX_DELAY_SEC = 8

local ctx: any = nil
local restricted: { [Player]: boolean } = {}
local overrides: { [Player]: boolean } = {}

local function effective(player: Player): boolean
	local o = overrides[player]
	if o ~= nil then
		return o
	end
	local value = restricted[player]
	if value == nil then
		return true
	end
	return value
end

local function publish(player: Player)
	if player.Parent == Players then
		ctx.setReplicated(player, "paidRandomRestricted", effective(player))
	end
end

local function lookup(player: Player)
	publish(player) -- fail closed while unknown
	for attempt = 1, MAX_ATTEMPTS do
		if player.Parent ~= Players then
			return
		end
		local ok, info = pcall(function()
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end)
		if ok and type(info) == "table" and type(info.ArePaidRandomItemsRestricted) == "boolean" then
			if player.Parent == Players then
				restricted[player] = info.ArePaidRandomItemsRestricted
				publish(player)
			end
			return
		end
		if attempt < MAX_ATTEMPTS then
			task.wait(math.min(BASE_DELAY_SEC * 2 ^ (attempt - 1), MAX_DELAY_SEC))
		else
			warn(
				"[Core.Policy] lookup failed for "
					.. player.Name
					.. "; staying restricted: "
					.. tostring(info)
			)
		end
	end
end

local function targetPlayer(userId: any): Player?
	local id = tonumber(userId)
	if id then
		return Players:GetPlayerByUserId(id)
	end
	return Players:GetPlayers()[1]
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
		overrides[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(lookup, player)
	end

	if ctx.isStudio then
		ctx.console.register(
			"restrict",
			"restrict <true|false|clear> [userId]: override the paid-random policy (Studio)",
			function(value: any, userId: any): string?
				local player = targetPlayer(userId)
				if player == nil then
					return "no player"
				end
				if value == "true" or value == true then
					overrides[player] = true
				elseif value == "false" or value == false then
					overrides[player] = false
				elseif value == "clear" then
					overrides[player] = nil
				else
					return "usage: restrict <true|false|clear> [userId]"
				end
				publish(player)
				return player.Name .. " paidRandomRestricted = " .. tostring(effective(player))
			end
		)
	end
end

function Policy.paidRandomRestricted(player: Player): boolean
	return effective(player)
end

return Policy
