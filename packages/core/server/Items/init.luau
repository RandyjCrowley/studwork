--!strict
--[[
	Core.Items. OWNED BY AGENT C (core/c-items). Public API: Types.ItemsAPI.

	Registry of ItemDefs. init() registers GameConfig.items; games may call register(defs) later
	(e.g. generated items). Every batch is validated by ItemValidate and committed all-or-nothing;
	an invalid def or a duplicate id raises "[Core.Items] ..." and registers nothing.

	get(id) / all() (registration order) / byTag(tag) (indexed; returns a fresh array) /
	incomeOf(instance) = def.incomePerSec * mutation multiplier (balance.mutations; unknown
	mutation -> multiplier 1, unknown item -> 0). Registered defs are frozen copies.
]]

local Core = game:GetService("ReplicatedStorage"):WaitForChild("Core")
local Types = require(Core:WaitForChild("Types"))
local Validate = require(Core:WaitForChild("Validate"))
local ItemValidate = require(script.ItemValidate)

local Items = {}

local ctx: any = nil
local byId: { [string]: Types.ItemDef } = {}
local ordered: { Types.ItemDef } = {}
local tagIndex: { [string]: { Types.ItemDef } } = {}
local mutationMult: { [string]: number } = {}

local function freezeDef(def: Types.ItemDef): Types.ItemDef
	local copy = table.clone(def)
	if def.tags then
		copy.tags = table.freeze(table.clone(def.tags))
	end
	return table.freeze(copy)
end

function Items.init(context: any)
	ctx = context
	for _, m in ctx.config.balance.mutations or {} do
		if type(m) == "table" and type(m.id) == "string" then
			mutationMult[m.id] = if Validate.isNonNegativeNumber(m.multiplier) then m.multiplier else 1
		end
	end
	Items.register(ctx.config.items)
end

function Items.start() end

function Items.register(defs: { Types.ItemDef })
	local ok, err = ItemValidate.validateBatch(defs, function(id: string): boolean
		return byId[id] ~= nil
	end)
	if not ok then
		error("[Core.Items] " .. tostring(err), 2)
	end
	for _, def in defs do
		local frozen = freezeDef(def)
		byId[frozen.id] = frozen
		table.insert(ordered, frozen)
		local seen: { [string]: boolean } = {}
		for _, tag in (frozen.tags or {}) :: { string } do
			if not seen[tag] then
				seen[tag] = true
				local list = tagIndex[tag]
				if list == nil then
					list = {}
					tagIndex[tag] = list
				end
				table.insert(list, frozen)
			end
		end
	end
end

function Items.get(id: string): Types.ItemDef?
	if type(id) ~= "string" then
		return nil
	end
	return byId[id]
end

function Items.all(): { Types.ItemDef }
	return table.clone(ordered)
end

function Items.byTag(tag: string): { Types.ItemDef }
	local list = if type(tag) == "string" then tagIndex[tag] else nil
	return if list then table.clone(list) else {}
end

function Items.incomeOf(instance: Types.ItemInstance): number
	if type(instance) ~= "table" then
		return 0
	end
	local def = byId[instance.itemId]
	if def == nil then
		return 0
	end
	local mult = if instance.mutation then (mutationMult[instance.mutation] or 1) else 1
	return def.incomePerSec * mult
end

return Items
