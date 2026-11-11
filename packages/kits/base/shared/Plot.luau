--!strict
--[[
	Plot module definition (kit: base). core-v1.3.0 Phase 1: a real module; the server part is
	../server/Plot (README.md there). Save section "plot" = { displayed = { [slotId]: uid } },
	unchanged from v1.2 (FrameworkSection.V12_MAP), replicated to the owning client.

	config (GameConfig.config.Plot)
	  plot.slotCount               integer?   keep the first N slots of each plot (natural order)
	  plot.autoDisplay             boolean?   new items go to the first compatible free slot
	  plot.keepDisplayedOnRebirth  boolean?   keep owned items on display through a rebirth
	                                          (default false; replaces v1.2 balance.rebirth
	                                          .keepDisplayed, which Plot can't read any more)
	  assetsFolderName             string     ReplicatedStorage folder with item models
	                                          (default "GameAssets")
	  plotTag                      string     CollectionService tag that marks a plot Model
	                                          (default "CorePlot")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Kits = ReplicatedStorage:WaitForChild("Kits")
local Inventory = require(Kits:WaitForChild("Collection"):WaitForChild("Inventory"))
local Items = require(Kits:WaitForChild("Collection"):WaitForChild("Items"))
local Rarity = require(Kits:WaitForChild("Collection"):WaitForChild("Rarity"))
local Rebirth = require(Kits:WaitForChild("Economy"):WaitForChild("Rebirth"))

return StudWork.defineModule({
	name = "Plot",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Assigns plots, shows displayed items on them (base kit)",
	dependsOn = { Inventory },
	optional = { Items, Rarity, Rebirth },
	config = {
		schema = {
			plot = {
				slotCount = "integer(1..)?",
				autoDisplay = "boolean?",
				keepDisplayedOnRebirth = "boolean?",
			},
			assetsFolderName = "string",
			plotTag = "string",
		},
		defaults = {
			plot = {},
			assetsFolderName = "GameAssets",
			plotTag = "CorePlot",
		},
	},
	data = { key = "plot", version = 1, default = { displayed = {} }, replicate = { "displayed" } },
	client = "Plot",
})
