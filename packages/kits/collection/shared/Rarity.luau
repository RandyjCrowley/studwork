--!strict
--[[
	Rarity module definition (kit: collection; module-api.md §2, §13, §14). Server part:
	../server/Rarity/init.luau (through ../server/ModuleServers.luau).

	config (config.Rarity)
	  tiers         "standard7" (default) | { { id, color?, glow?, glowStrength?, soundKey? } }
	                the ordered tier list (shared/Tiers.luau); item rarities are validated
	                against it at boot
	  rarityTables  { [tableId]: { entries, cost?, paid?, luckDisclosed?, luckMinTier?, pity?,
	                mutationChance? } } (the v1.2 keys); every table is a Compliance random source
	  mutations     { { id, name?, weight?, multiplier?, color?, [namespace]: {...} } } served by
	                Items.mutation / mutations
	data: section 'rarity' = { pity = { [tableId]: number } } (the v1.2 PlayerData field, unchanged;
	server-only). Version 1; migration 1 normalises a split v1.2 section, sanitize keeps only
	non-negative integer counters.
	theme: theme.rarity.tiers = the resolved config.Rarity.tiers (theme = function(config), Phase 2).
	optional: Inventory (rolls that grant), Economy (coin-priced RequestRoll of a free currency).
	client: the `roll` action (RequestRoll), served by ../shared/ModuleClients.luau.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Tiers = require(script.Parent.Tiers)
local Items = require(script.Parent.Items)
local Inventory = require(script.Parent.Inventory)
local Economy =
	require(ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Economy"):WaitForChild("Economy"))

local function migrate1(old: any): any
	local out = if type(old) == "table" then old else {}
	if type(out.pity) ~= "table" then
		out.pity = {}
	end
	return out
end

local function sanitize(section: any): any
	local clean = {}
	if type(section.pity) == "table" then
		for tableId, count in section.pity do
			if
				type(tableId) == "string"
				and type(count) == "number"
				and count == count
				and count >= 0
				and count < math.huge
				and count % 1 == 0
			then
				clean[tableId] = count
			end
		end
	end
	section.pity = clean
	return section
end

return StudWork.defineModule({
	name = "Rarity",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Rarity tiers, roll tables (pity, mutations, luck) through Compliance (collection kit)",
	dependsOn = { Items },
	optional = { Inventory, Economy },
	config = {
		schema = { tiers = "any", rarityTables = "table", mutations = "table" },
		defaults = { tiers = Tiers.DEFAULT_PRESET, rarityTables = {}, mutations = {} },
	},
	data = {
		key = "rarity",
		version = 1,
		default = { pity = {} },
		migrations = { [1] = migrate1 },
		sanitize = sanitize,
		replicate = false,
	},
	-- config-driven theme (framework Phase 2): the resolved config.Rarity.tiers, so a game with
	-- custom tiers lists them once, in config (an invalid list fails boot in the server part)
	theme = function(config: any): any
		local tiers = Tiers.resolve(if type(config) == "table" then config.tiers else nil)
		return { rarity = { tiers = tiers or Tiers.PRESETS.standard7 } }
	end,
	client = "Rarity",
})
