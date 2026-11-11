-- Sessions: the loaded profiles, shared by the server scripts.
local Sessions = {}
Sessions.profiles = {}

function Sessions.addCoins(player, amount)
	local profile = Sessions.profiles[player]
	if not profile then
		return
	end
	profile.Data.coins += amount
	local stats = player:FindFirstChild("leaderstats")
	if stats then
		stats.Coins.Value = profile.Data.coins
	end
end

return Sessions
