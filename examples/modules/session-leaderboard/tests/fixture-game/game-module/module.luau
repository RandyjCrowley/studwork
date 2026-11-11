--!strict
-- The fixture game's own module (module-api.md §7 C4): no code, just its save section.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

return StudWork.defineModule({
	name = "LeaderboardFixture",
	version = "1.0.0",
	framework = "^1.3.0",
	data = { key = "leaderboard-fixture", version = 1, default = {} },
})
