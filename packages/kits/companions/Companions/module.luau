--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Items = require(Modules:WaitForChild("Items"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module"))
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local Rebirth = require(Modules:WaitForChild("Rebirth"):WaitForChild("module"))
local Plot = require(Modules:WaitForChild("Plot"):WaitForChild("module"))
local Types = require(script.Parent.shared.Types)
local Config = require(script.Parent.shared.Config)
local Save = require(script.Parent.shared.Save)
export type API = {
	equip: (Player, string) -> (boolean, string?),
	unequip: (Player, string) -> (boolean, string?),
	equipBest: (Player) -> (boolean, string?),
	equipped: (Player) -> { Types.PublicCopy },
	bonus: (Player) -> number,
	refresh: (Player) -> (boolean, string?),
	registerLook: (string, Types.Look) -> Types.Connection,
	applyLook: (Instance, any, string?) -> (),
	signals: { EquippedChanged: any },
}
export type ClientAPI = {
	setLowDetail: (boolean) -> (),
	lowDetail: () -> boolean,
	debugStats: () -> Types.DebugStats,
	registerLook: (string, Types.Look) -> Types.Connection,
	applyLook: (Instance, any, string?) -> (),
	open: () -> (),
	read: any,
}
export type Extensions = {
	canEquipWith: (string, (Player, any) -> boolean) -> Types.Connection,
	scoreWith: (string, (Player, any, any) -> number) -> Types.Connection,
}
return StudWork.defineModule({
	name = "Companions",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Equipped collectible companions",
	dependsOn = { Items, Inventory },
	optional = { Rarity, Economy, Rebirth, Plot },
	config = { schema = Config.schema, defaults = Config.defaults },
	itemFields = { item = Config.itemSchema },
	data = {
		key = "companions",
		version = 1,
		default = { equipped = {}, manual = false },
		migrations = { [1] = Save.migrate1 },
		sanitize = Save.sanitize,
		replicate = { "equipped", "manual" },
	},
	strings = {
		["Companions.title"] = "Companions",
		["Companions.open"] = "Companions",
		["Companions.equip"] = "Equip",
		["Companions.unequip"] = "Unequip",
		["Companions.equipBest"] = "Equip best",
		["Companions.count"] = "{equipped}/{slots} equipped · {owned} owned",
		["Companions.empty"] = "No companions yet",
		["Companions.disabled"] = "Companions are disabled",
		["Companions.previous"] = "Previous",
		["Companions.next"] = "Next",
		["Companions.page"] = "Page {page}/{pages}",
	},
	client = "Companions",
})
