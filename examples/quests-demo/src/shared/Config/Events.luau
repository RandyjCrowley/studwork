--!strict
-- Live events (UTC). demoEvent has no schedule: it starts only by hand (`questsdemo event`, or
-- `events event demoEvent`), for 600 s, and the event quest "eventCoins" is active while it runs.
local Events = {
	demoEvent = {
		durationSec = 600,
	},
}

return Events
