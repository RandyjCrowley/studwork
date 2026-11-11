--!strict
--[[
	Upgrades module definition (kit: economy). core-v1.3.0 Phase 1: a real StudWork module; the
	server part is ../server/Upgrades.

	config (config.Upgrades): upgrades = { [upgradeId]: { baseCost, costGrowth, currency?
	(default Economy's primary), maxLevel, effect = "incomeMultiplier" | "inventoryCap" | "custom",
	perLevel, resetsOnRebirth? (default true) } }                                default {}
	data: section `upgrades` = { upgrades = { [upgradeId]: level } }.
	client: the `upgrade` action (RequestUpgrade), served by ./ModuleClients.luau.
	optional: Rebirth (levels reset on rebirth through Rebirth.extensions.resetStep), Inventory
	("inventoryCap" upgrades add to Inventory.cap through Inventory.extensions.capBonus).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy = require(script.Parent.Economy)
local Rebirth = require(script.Parent.Rebirth)
local Inventory =
	require(ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Collection"):WaitForChild("Inventory"))

return StudWork.defineModule({
	name = "Upgrades",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Levelled upgrades bought with currency (economy kit)",
	dependsOn = { Economy },
	optional = { Rebirth, Inventory },
	config = {
		schema = {
			upgrades = {
				type = "{[string]: table}",
				description = "upgradeId -> { baseCost, costGrowth, currency?, maxLevel, effect, perLevel, resetsOnRebirth? }",
			},
		},
		defaults = { upgrades = {} },
	},
	data = { key = "upgrades", version = 1, default = { upgrades = {} }, replicate = { "upgrades" } },
	client = "Upgrades",
})
