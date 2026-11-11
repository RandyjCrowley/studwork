local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local store = DataStoreService:GetDataStore("PlayerData", "v1")

Players.PlayerAdded:Connect(function(player)
	local data = store:GetAsync("Player_" .. player.UserId) or {}
	data.LastLobbyVisit = os.time()
	store:SetAsync("Player_" .. player.UserId, data)
end)
