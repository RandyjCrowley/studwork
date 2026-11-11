--!strict
--[[
	Items server part (collection kit; module-api.md §12). Items.new() -> a fresh part per runtime
	(ModuleServers.loadServer calls it), so two servers in one process never share state.

	api (frozen; ctx.deps[Items] / StudWork.use(Items))
	  get(id) -> ItemDef?            frozen def from GameConfig.items, namespaced fields included
	  all() -> { ItemDef }           GameConfig.items order (a fresh array of the frozen defs)
	  byTag(tag) -> { ItemDef }      indexed; a fresh array
	  mutation(id) -> MutationDef?   frozen; config.Rarity.mutations entry, namespaced fields
	                                 included (economy.incomeMultiplier; see mutationDef)
	  mutations() -> { MutationDef } config order
	  register(...)                  errors: items exist only through GameConfig.items (§12)
	extensions
	  mutations(list)                Rarity (same kit) hands over config.Rarity.mutations in its
	                                 init; once per runtime. Kit-internal plumbing.
	Removed (core-v1.3.0 Breaking): incomeOf (income is Economy's: item.economy.incomePerSec x
	mutation.economy.incomeMultiplier), register, onRegistered.
	Boot checks (beyond the framework's base-field schema): ItemValidate per def (id/name length,
	tags shape); rarity strings are checked by Rarity against the active tier list.
]]

local ItemValidate = require(script.ItemValidate)
local Util = require(script.Parent.Util)

local NO_LATE_ITEMS_ERROR =
	"items must be declared in GameConfig.items; registering items after start is not supported in core-v1.3.0"

local Items = {}

-- A MutationDef: the config entry, frozen. v1.2 configs carry `multiplier`; until Economy
-- declares its own mutation field the def also gets economy.incomeMultiplier = multiplier when it
-- has no `economy` table (PHASE1-CONTRACT bridged semantics, kept by the real module).
local function mutationDef(m: any): any
	local out = table.clone(m)
	if type(out.economy) ~= "table" and type(out.multiplier) == "number" then
		out.economy = { incomeMultiplier = out.multiplier }
	end
	return Util.frozenCopy(out)
end

function Items.new(): any
	local ctx: any = nil
	local ordered: { any } = {}
	local byId: { [string]: any } = {}
	local tagIndex: { [string]: { any } } = {}
	local mutationList: { any } = {}
	local mutationById: { [string]: any } = {}
	local mutationsSet = false

	local part: any = {}

	function part.init(context: any)
		ctx = context
		local errors: { string } = {}
		for i, def in ctx.gameConfig.items do
			local err = ItemValidate.validateDef(def, false)
			if err then
				table.insert(errors, `items[{i}]: {err}`)
				continue
			end
			local frozen = Util.frozenCopy(def)
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
		if #errors > 0 then
			error("invalid GameConfig.items:\n  - " .. table.concat(errors, "\n  - "), 0)
		end
	end

	part.api = {
		get = function(id: string): any
			if type(id) ~= "string" then
				return nil
			end
			return byId[id]
		end,
		all = function(): { any }
			return table.clone(ordered)
		end,
		byTag = function(tag: string): { any }
			local list = if type(tag) == "string" then tagIndex[tag] else nil
			return if list then table.clone(list) else {}
		end,
		mutation = function(id: string): any
			if type(id) ~= "string" then
				return nil
			end
			return mutationById[id]
		end,
		mutations = function(): { any }
			return table.clone(mutationList)
		end,
		register = function()
			error(NO_LATE_ITEMS_ERROR, 2)
		end,
	}

	part.extensions = {
		-- Rarity's init: config.Rarity.mutations (validated there). Once per runtime.
		mutations = function(list: { any })
			assert(not mutationsSet, "[Items] mutations were already handed over")
			assert(type(list) == "table", "[Items] extensions.mutations(list): list must be a table")
			mutationsSet = true
			for _, m in list do
				if type(m) == "table" and type(m.id) == "string" and mutationById[m.id] == nil then
					local def = mutationDef(m)
					mutationById[def.id] = def
					table.insert(mutationList, def)
				end
			end
		end,
	}

	return part
end

return Items
