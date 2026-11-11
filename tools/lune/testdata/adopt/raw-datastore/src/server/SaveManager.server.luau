--# selene: allow(global_usage)
-- Old save code. A comment that mentions store:SetAsync(key) must not count.
local DSS = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local store = DSS:GetDataStore("PlayerData", "v1")

local function keyFor(player)
	return "Player_" .. player.UserId
end

Players.PlayerAdded:Connect(function(player)
	local key = "Player_" .. player.UserId
	local ok, data = pcall(function()
		return store:GetAsync(key)
	end)
	if ok then
		_G.Data[player] = data or { Coins = 0, Gems = 0, Pets = {} }
	end
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Parent = leaderstats
end)

Players.PlayerRemoving:Connect(function(player)
	store:SetAsync(`Player_{player.UserId}`, _G.Data[player])
end)

return keyFor
