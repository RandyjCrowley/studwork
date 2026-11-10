--!strict
-- Weekly and scheduled live events (UTC). Triggerable from the admin command / console too.
local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Events: Types.EventsConfig = {
	CoinRain = {
		schedule = { weekday = 7, hourUtc = 18, minuteUtc = 0 }, -- Saturday 18:00 UTC
		durationSec = 300,
		data = { multiplier = 2 },
	},
	SecretDrop = {
		durationSec = 60,
		data = { itemId = "void" },
	},
}

return Events
