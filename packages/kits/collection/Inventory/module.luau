--!strict
--[[
	Inventory module definition (kit: collection; module-api.md §2, §6, §8). Server part:
	./server/init.luau (ServerScriptService.Modules.Inventory).

	config (config.Inventory)
	  inventory     { cap = number }   base capacity (default 50); modules add to it through
	                                   extensions.capBonus (Upgrades' "inventoryCap" effect)
	  starterItems  { itemId }         granted on a player's first session (default none)
	data: section 'inventory' = { inventory = { [uid]: ItemInstance } } (the v1.2 PlayerData field,
	unchanged: FrameworkSection.V12_MAP splits a v1.2 save into exactly this shape). Version 1;
	migration 1 normalises a split v1.2 section, sanitize drops malformed instances.
	optional: Mail (the "core_gift" mail kind and the crash-safe gift outbox).
	client: the `gift` action (own net.blink event Gift), served by ./client/init.luau.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Items = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Items"):WaitForChild("module"))
local Mail = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Mail"):WaitForChild("module"))

local function isTable(v: any): boolean
	return type(v) == "table"
end

-- v1.2 save shape -> version 1 (same shape; makes sure the map exists).
local function migrate1(old: any): any
	local out = if isTable(old) then old else {}
	if not isTable(out.inventory) then
		out.inventory = {}
	end
	return out
end

-- Once after migrations on load: keep only well-formed instances (uid key = instance.uid). An
-- itemId no longer in GameConfig.items is KEPT (removing an item from config never deletes
-- saves); Inventory.get still returns it.
local function sanitize(section: any): any
	if not isTable(section.inventory) then
		section.inventory = {}
		return section
	end
	local clean = {}
	for uid, instance in section.inventory do
		if
			type(uid) == "string"
			and uid ~= ""
			and isTable(instance)
			and type(instance.itemId) == "string"
			and instance.itemId ~= ""
		then
			instance.uid = uid
			if type(instance.acquiredAt) ~= "number" then
				instance.acquiredAt = 0
			end
			if instance.mutation ~= nil and type(instance.mutation) ~= "string" then
				instance.mutation = nil
			end
			if instance.source ~= nil and type(instance.source) ~= "string" then
				instance.source = nil
			end
			if instance.meta ~= nil and not isTable(instance.meta) then
				instance.meta = nil
			end
			clean[uid] = instance
		end
	end
	section.inventory = clean
	return section
end

return StudWork.defineModule({
	name = "Inventory",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Per-player item instances: cap, transfer, gifts (collection kit)",
	dependsOn = { Items },
	optional = { Mail },
	config = {
		schema = { inventory = "table", starterItems = "{string}" },
		defaults = { inventory = { cap = 50 }, starterItems = {} },
	},
	data = {
		key = "inventory",
		version = 1,
		default = { inventory = {} },
		migrations = { [1] = migrate1 },
		sanitize = sanitize,
		replicate = { "inventory" },
	},
	client = "Inventory",
})
