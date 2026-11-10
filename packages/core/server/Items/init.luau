--!strict
--[[
	Core.Items. OWNED BY AGENT C (core/c-items). Public API: Types.ItemsAPI.

	PHASE 0 STUB: plain registry (Core.start registers GameConfig.items). Agent C adds full
	validation (unique ids, rarity tiers, numeric ranges) with tests.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Items = {}

local ctx: any = nil
local byId: { [string]: Types.ItemDef } = {}
local ordered: { Types.ItemDef } = {}
local mutationMult: { [string]: number } = {}

function Items.init(context: any)
	ctx = context
	for _, m in ctx.config.balance.mutations or {} do
		mutationMult[m.id] = m.multiplier
	end
	Items.register(ctx.config.items)
end

function Items.start() end

function Items.register(defs: { Types.ItemDef })
	for _, def in defs do
		assert(byId[def.id] == nil, "[Core.Items] duplicate item id " .. def.id)
		byId[def.id] = table.freeze(table.clone(def))
		table.insert(ordered, byId[def.id])
	end
end

function Items.get(id: string): Types.ItemDef?
	return byId[id]
end

function Items.all(): { Types.ItemDef }
	return table.clone(ordered)
end

function Items.byTag(tag: string): { Types.ItemDef }
	local list = {}
	for _, def in ordered do
		if def.tags and table.find(def.tags, tag) then
			table.insert(list, def)
		end
	end
	return list
end

function Items.incomeOf(instance: Types.ItemInstance): number
	local def = byId[instance.itemId]
	if def == nil then
		return 0
	end
	local mult = if instance.mutation then (mutationMult[instance.mutation] or 1) else 1
	return def.incomePerSec * mult
end

return Items
