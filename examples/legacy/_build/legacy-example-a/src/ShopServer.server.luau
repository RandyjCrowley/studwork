-- ShopServer: buying items with coins, the daily reward, settings, and the shop list.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ShopItems = require(ReplicatedStorage:WaitForChild("ShopItems"))

local DAILY_REWARD = 100
local DAILY_SECONDS = 24 * 60 * 60

Remotes.BuyItem.OnServerEvent:Connect(function(player, itemId)
	local data = _G.PlayerData[player]
	local item = ShopItems[itemId]
	if not data or not item then
		return
	end
	if table.find(data.inventory, itemId) then
		return
	end
	if data.coins < item.price then
		return
	end
	_G.AddCoins(player, -item.price)
	table.insert(data.inventory, itemId)
end)

Remotes.ClaimDaily.OnServerEvent:Connect(function(player)
	local data = _G.PlayerData[player]
	if not data then
		return
	end
	if os.time() - data.lastDaily < DAILY_SECONDS then
		return
	end
	data.lastDaily = os.time()
	_G.AddCoins(player, DAILY_REWARD)
end)

Remotes.ToggleMusic.OnServerEvent:Connect(function(player, on)
	local data = _G.PlayerData[player]
	if data and type(on) == "boolean" then
		data.settings.music = on
	end
end)

Remotes.GetShop.OnServerInvoke = function(player)
	local data = _G.PlayerData[player]
	return ShopItems, data and data.inventory or {}
end
