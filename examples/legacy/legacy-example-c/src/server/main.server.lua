-- main: everything about the player's stats. coins, xp, level, rebirths, inventory.
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local DataStore2 = require(ServerStorage.DataStore2)

DataStore2.Combine("DATA", "coins", "xp", "rebirths", "inventory", "boostUntil")

_G.Coins = {}
_G.Stores = {}

function _G.getLevel(xp)
	return math.floor(math.sqrt(xp / 50)) + 1
end

Players.PlayerAdded:Connect(function(plr)
	local coinsStore = DataStore2("coins", plr)
	local xpStore = DataStore2("xp", plr)
	local rebirthStore = DataStore2("rebirths", plr)
	_G.Stores[plr] = { coins = coinsStore, xp = xpStore, rebirths = rebirthStore, inventory = DataStore2("inventory", plr), boostUntil = DataStore2("boostUntil", plr) }

	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	local c = Instance.new("IntValue")
	c.Name = "Coins"
	c.Value = coinsStore:Get(0)
	c.Parent = ls
	local lvl = Instance.new("IntValue")
	lvl.Name = "Level"
	lvl.Value = _G.getLevel(xpStore:Get(0))
	lvl.Parent = ls
	local rb = Instance.new("IntValue")
	rb.Name = "Rebirths"
	rb.Value = rebirthStore:Get(0)
	rb.Parent = ls
	ls.Parent = plr

	_G.Coins[plr] = coinsStore:Get(0)
	coinsStore:OnUpdate(function(v)
		c.Value = v
		_G.Coins[plr] = v
	end)
	xpStore:OnUpdate(function(v)
		lvl.Value = _G.getLevel(v)
	end)
	rebirthStore:OnUpdate(function(v)
		rb.Value = v
	end)
end)

Players.PlayerRemoving:Connect(function(plr)
	_G.Stores[plr] = nil
end)

-- passive income: 1 coin a second per level, x(1 + rebirths), x2 while a boost is active
while true do
	task.wait(1)
	for _, plr in ipairs(Players:GetPlayers()) do
		local s = _G.Stores[plr]
		if s then
			local mult = 1 + s.rebirths:Get(0)
			if s.boostUntil:Get(0) > os.time() then
				mult *= 2
			end
			s.coins:Increment(_G.getLevel(s.xp:Get(0)) * mult, 0)
			s.xp:Increment(1, 0)
		end
	end
end
