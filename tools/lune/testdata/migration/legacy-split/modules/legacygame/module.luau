--!strict
-- The example game's own module: its save section is the gameId; it imports the old save.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local KitDefs = ReplicatedStorage:WaitForChild("Modules")

return StudWork.defineModule({
	name = "LegacyGame",
	version = "1.0.0",
	framework = "^1.3.0",
	dependsOn = {
		require(KitDefs:WaitForChild("Inventory"):WaitForChild("module")),
		require(KitDefs:WaitForChild("Economy"):WaitForChild("module")),
	},
	data = { key = "legacy-split", version = 1, default = { rebirths = 0 } },
	server = "LegacyGame",
})
