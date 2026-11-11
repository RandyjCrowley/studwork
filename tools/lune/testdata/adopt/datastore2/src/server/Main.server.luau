local Players = game:GetService("Players")
local DataStore2 = require(script.Parent.DataStore2)

DataStore2.Combine("DATA", "coins", "inventory")

Players.PlayerAdded:Connect(function(player)
	local coinStore = DataStore2("coins", player)
	local inventoryStore = DataStore2("inventory", player)
	coinStore:Increment(5, 0)
	print(inventoryStore:Get({}))
end)
