--!strict
-- This experience's gamepass and developer product ids. 0 = not created on Roblox yet.
local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Products: Types.ProductsConfig = {
	passes = {
		DoubleCoins = 0,
	},
	devProducts = {
		EggRoll = 0, -- paid random roll of rarity table "Egg"
		CoinPack = 0,
	},
}

return Products
