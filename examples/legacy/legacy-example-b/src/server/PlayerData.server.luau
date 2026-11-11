-- PlayerData: ProfileService profiles (coins, gems, pets, stats), shared with the other scripts
-- through the PlayerData BindableFunction-free module table in ServerStorage.
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileService = require(ServerStorage.Lib.ProfileService)
local Sessions = require(script.Parent.Sessions)

local TEMPLATE = {
	coins = 0,
	gems = 0,
	pets = {}, -- list of { id = "fox", uid = "..." }
	equipped = {}, -- list of uids
	stats = { hatched = 0, collected = 0 },
	Purchases = {}, -- [purchaseId] = true (granted developer products)
}

local store = ProfileService.GetProfileStore("PlayerData", TEMPLATE)

local function pushState(player)
	local profile = Sessions.profiles[player]
	if profile then
		ReplicatedStorage.Remotes.StateChanged:FireClient(player, profile.Data)
	end
end
Sessions.pushState = pushState

Players.PlayerAdded:Connect(function(player)
	local profile = store:LoadProfileAsync("Player_" .. player.UserId)
	if profile == nil then
		player:Kick("Your data is in use on another server, try again soon")
		return
	end
	profile:AddUserId(player.UserId)
	profile:Reconcile()
	profile:ListenToRelease(function()
		Sessions.profiles[player] = nil
		player:Kick("Your data was loaded on another server")
	end)
	if not player:IsDescendantOf(Players) then
		profile:Release()
		return
	end
	Sessions.profiles[player] = profile
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = profile.Data.coins
	coins.Parent = stats
	stats.Parent = player
	pushState(player)
end)

Players.PlayerRemoving:Connect(function(player)
	local profile = Sessions.profiles[player]
	if profile then
		profile:Release()
	end
end)
