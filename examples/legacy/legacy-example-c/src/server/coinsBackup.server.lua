-- coinsBackup: a second copy of everyone's coins, in case DataStore2 loses them (added after a
-- data scare). Restores the backup when it's higher than what DataStore2 loaded.
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local backup = DataStoreService:GetDataStore("CoinsBackup")

Players.PlayerAdded:Connect(function(plr)
	task.wait(3) -- let main load first
	local ok, saved = pcall(backup.GetAsync, backup, tostring(plr.UserId))
	if ok and type(saved) == "number" and _G.Stores[plr] and saved > _G.Stores[plr].coins:Get(0) then
		_G.Stores[plr].coins:Set(saved)
	end
end)

Players.PlayerRemoving:Connect(function(plr)
	local coins = _G.Coins[plr]
	if coins then
		pcall(backup.SetAsync, backup, tostring(plr.UserId), coins)
	end
	_G.Coins[plr] = nil
end)
