-- Pets: hatch an egg for gems, equip up to 3 pets; equipped pets earn coins every second.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Sessions = require(script.Parent.Sessions)
local Passes = require(script.Parent.Passes)
local Config = require(ReplicatedStorage.Shared.Pets)

local rng = Random.new()

local function pick()
	local total = 0
	for _, w in pairs(Config.egg.weights) do
		total += w
	end
	local roll = rng:NextNumber() * total
	for id, w in pairs(Config.egg.weights) do
		roll -= w
		if roll <= 0 then
			return id
		end
	end
	return "puppy"
end

ReplicatedStorage.Remotes.Hatch.OnServerEvent:Connect(function(player)
	local profile = Sessions.profiles[player]
	if not profile then
		return
	end
	local data = profile.Data
	local cap = if Passes.owns(player, "ExtraSlots") then Config.maxPetsWithPass else Config.maxPets
	if #data.pets >= cap or data.gems < Config.egg.gemCost then
		return
	end
	data.gems -= Config.egg.gemCost
	table.insert(data.pets, { id = pick(), uid = HttpService:GenerateGUID(false) })
	data.stats.hatched += 1
	Sessions.pushState(player)
end)

ReplicatedStorage.Remotes.Equip.OnServerEvent:Connect(function(player, uid, on)
	local profile = Sessions.profiles[player]
	if not profile or type(uid) ~= "string" then
		return
	end
	local data = profile.Data
	local index = table.find(data.equipped, uid)
	if on and not index and #data.equipped < Config.maxEquipped then
		for _, pet in ipairs(data.pets) do
			if pet.uid == uid then
				table.insert(data.equipped, uid)
				break
			end
		end
	elseif not on and index then
		table.remove(data.equipped, index)
	end
	Sessions.pushState(player)
end)

-- coins from equipped pets
task.spawn(function()
	while true do
		task.wait(1)
		for _, player in ipairs(Players:GetPlayers()) do
			local profile = Sessions.profiles[player]
			if profile then
				local perSecond = 0
				for _, uid in ipairs(profile.Data.equipped) do
					for _, pet in ipairs(profile.Data.pets) do
						if pet.uid == uid then
							perSecond += Config.pets[pet.id].coinsPerSecond
						end
					end
				end
				if perSecond > 0 then
					Sessions.addCoins(player, perSecond * (if Passes.owns(player, "VIP") then 2 else 1))
				end
			end
		end
	end
end)
