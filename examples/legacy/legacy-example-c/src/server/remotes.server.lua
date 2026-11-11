-- remotes: rebirth, boosts, and the xp orbs (created here).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Events = ReplicatedStorage:WaitForChild("Events")

local REBIRTH_COST = 10000
local BOOST_COST = 500
local BOOST_SECONDS = 600

local giveXp = Instance.new("RemoteEvent")
giveXp.Name = "GiveXP"
giveXp.Parent = Events

giveXp.OnServerEvent:Connect(function(plr, amount)
	local s = _G.Stores[plr]
	if s then
		s.xp:Increment(amount, 0)
	end
end)

Events.Rebirth.OnServerEvent:Connect(function(plr)
	local s = _G.Stores[plr]
	if not s or s.coins:Get(0) < REBIRTH_COST * (1 + s.rebirths:Get(0)) then
		return
	end
	s.coins:Set(0)
	s.xp:Set(0)
	s.rebirths:Increment(1, 0)
end)

Events.BuyBoost.OnServerInvoke = function(plr)
	local s = _G.Stores[plr]
	if not s or s.coins:Get(0) < BOOST_COST then
		return false
	end
	s.coins:Increment(-BOOST_COST, 0)
	s.boostUntil:Set(math.max(s.boostUntil:Get(0), os.time()) + BOOST_SECONDS)
	local inv = s.inventory:Get({})
	inv.boostsBought = (inv.boostsBought or 0) + 1
	s.inventory:Set(inv)
	return true
end
