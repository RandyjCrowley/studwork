-- DataManager: loads and saves every player's data (coins, inventory, settings).
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local store = DataStoreService:GetDataStore("PlayerSave_v3")

local DEFAULT = {
	coins = 0,
	inventory = {},
	settings = { music = true, sfx = true },
	lastDaily = 0,
}

local sessions = {}
_G.PlayerData = sessions

local function copy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = if type(v) == "table" then copy(v) else v
	end
	return out
end

local function keyFor(player)
	return "Player_" .. player.UserId
end

local function makeLeaderstats(player, data)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = data.coins
	coins.Parent = stats
	stats.Parent = player
end

local function onJoin(player)
	local ok, saved = pcall(function()
		return store:GetAsync(keyFor(player))
	end)
	if not ok then
		player:Kick("Could not load your data, please rejoin")
		return
	end
	local data = copy(DEFAULT)
	if type(saved) == "table" then
		for k, v in pairs(saved) do
			data[k] = v
		end
	end
	sessions[player] = data
	makeLeaderstats(player, data)
end

local function save(player)
	local data = sessions[player]
	if not data then
		return
	end
	local ok, err = pcall(function()
		store:SetAsync(keyFor(player), data)
	end)
	if not ok then
		warn("save failed for", player.Name, err)
	end
end

function _G.AddCoins(player, amount)
	local data = sessions[player]
	if not data then
		return
	end
	data.coins += amount
	local stats = player:FindFirstChild("leaderstats")
	if stats then
		stats.Coins.Value = data.coins
	end
end

Players.PlayerAdded:Connect(onJoin)
Players.PlayerRemoving:Connect(function(player)
	save(player)
	sessions[player] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		save(player)
	end
end)

task.spawn(function()
	while true do
		task.wait(60)
		for _, player in ipairs(Players:GetPlayers()) do
			save(player)
		end
	end
end)
