--!strict
--[[
	Core.Rarity. OWNED BY AGENT C (core/c-items). Public API: Types.RarityAPI.

	PHASE 0 STUB: plain weighted roll; luck multiplies weights of tiers >= luckMinTier; no pity,
	no mutations. Agent C implements pity, mutations, odds with luck, paid-roll policy blocking
	(the stub already refuses paid rolls for restricted players), RequestRoll handling with cost.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RarityTiers = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("RarityTiers"))
local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))

local Rarity = {}

local ctx: any = nil
local rng = Random.new()

local function weightsFor(tableId: string, luck: number?): ({ { itemId: string, weight: number } }?, number)
	local t = ctx.config.balance.rarityTables[tableId]
	if t == nil then
		return nil, 0
	end
	local minTier = t.luckMinTier or "Rare"
	local l = if type(luck) == "number" and luck == luck and luck > 0 then math.min(luck, 1000) else 1
	local list = {}
	local total = 0
	for _, entry in t.entries do
		local def = ctx.services.Items.get(entry.itemId)
		local w = entry.weight
		if def and RarityTiers.atLeast(def.rarity, minTier) then
			w *= l
		end
		total += w
		table.insert(list, { itemId = entry.itemId, weight = w })
	end
	return list, total
end

function Rarity.init(context: any)
	ctx = context
end

function Rarity.start()
	ctx.net.handle("RequestRoll", function(player: Player, tableId: string)
		local t = ctx.config.balance.rarityTables[tableId]
		if t == nil or t.cost == nil or t.paid then
			return
		end
		if not ctx.services.Economy.spend(player, t.cost.amount, "roll:" .. tableId, t.cost.currency) then
			return
		end
		Rarity.roll(tableId, player, nil, { grant = true, reason = "roll" })
	end)
end

function Rarity.roll(
	tableId: string,
	player: Player,
	luck: number?,
	opts: Types.RollOptions?
): (Types.ItemDef?, Types.RollInfo)
	local o: Types.RollOptions = opts or {}
	if o.paid and ctx.services.Policy.paidRandomRestricted(player) then
		return nil, { ok = false, reason = "restricted", pity = false }
	end
	local list, total = weightsFor(tableId, luck)
	if list == nil or total <= 0 then
		return nil, { ok = false, reason = "unknown_table", pity = false }
	end
	local pick = rng:NextNumber() * total
	local chosen = list[#list].itemId
	for _, entry in list do
		pick -= entry.weight
		if pick <= 0 then
			chosen = entry.itemId
			break
		end
	end
	local def = ctx.services.Items.get(chosen)
	local info: Types.RollInfo = { ok = true, pity = false }
	if o.grant and def then
		local instance = ctx.services.Inventory.add(player, chosen, { source = o.reason or "roll" })
		if instance == nil then
			return def, { ok = false, reason = "inventory_full", pity = false }
		end
		info.instance = instance
	end
	return def, info
end

function Rarity.getOdds(tableId: string, luck: number?): { [string]: number }
	local list, total = weightsFor(tableId, luck)
	local odds = {}
	if list == nil or total <= 0 then
		return odds
	end
	for _, entry in list do
		odds[entry.itemId] = (odds[entry.itemId] or 0) + entry.weight / total
	end
	return odds
end

function Rarity.tiers(): { Types.RarityTierDef }
	return RarityTiers.all()
end

return Rarity
