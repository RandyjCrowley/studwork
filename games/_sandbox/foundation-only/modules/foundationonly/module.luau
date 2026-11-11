--!strict
--[[
	The foundation-only game's own module (module-api.md §7 C4): its save section is the gameId
	("foundationonly", the v1.2 game table). `optional = { Rebirth }` only so it can show the
	error a module that isn't enabled gives (Rebirth is not in GameConfig.modules).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Rebirth =
	require(ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Economy"):WaitForChild("Rebirth"))

return StudWork.defineModule({
	name = "FoundationOnly",
	version = "1.0.0",
	framework = "^1.3.0",
	description = "foundation-only test game: framework services only",
	optional = { Rebirth },
	data = { key = "foundationonly", version = 1, default = { joins = 0 }, replicate = { "joins" } },
	server = "FoundationOnly",
})
