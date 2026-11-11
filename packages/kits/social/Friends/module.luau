--!strict
--[[
	Friends module definition (kit: social). v1.3.0: a real module; the server part
	is ../server/Friends. No save data.

	config (GameConfig.config.Friends.friends)
	  checkIntervalSec   number    seconds between friend re-checks (default 30, floor 5)
	  coPlayMultiplier   number?   income multiplier while a friend is in the server (needs the
	                               optional Economy module)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))

return StudWork.defineModule({
	name = "Friends",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Detects friends in the same server: CoPlay signal + co-play multiplier (social kit)",
	optional = { Economy },
	config = {
		schema = {
			friends = {
				checkIntervalSec = "number(0..)",
				coPlayMultiplier = "number?",
			},
		},
		defaults = { friends = { checkIntervalSec = 30 } },
	},
})
