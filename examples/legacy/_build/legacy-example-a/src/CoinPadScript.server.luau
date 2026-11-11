-- CoinPad: stand on the pad to collect coins (once every 2 seconds per player).
local Players = game:GetService("Players")
local pad = script.Parent
local last = {}

pad.Touched:Connect(function(hit)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	if not player then
		return
	end
	if last[player] and os.clock() - last[player] < 2 then
		return
	end
	last[player] = os.clock()
	_G.AddCoins(player, 5)
end)
