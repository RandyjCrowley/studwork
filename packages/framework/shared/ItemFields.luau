--!strict
--[[
	Item definitions and namespaced item fields (module-api.md §12). Pure.

	Base ItemDef fields live in the framework (§17 Q1): { id, name, rarity, model, icon, tags,
	source, keepOnRebirth }. Modules extend items under a namespace they declare in
	`itemFields.item` (e.g. Economy: item.economy.incomePerSec). An item table carrying a namespace
	that no ENABLED module declared is a boot error naming the field.

	Breaking (v1.3.0, CHANGELOG): items exist ONLY through GameConfig.items, validated once at
	boot. There is no register function anywhere; `ItemFields.catalog` returns a frozen list whose
	register-/add-style lookups raise NO_LATE_ITEMS_ERROR instead of silently returning nil.
]]

local DefineModule = require(script.Parent.defineModule)
local Freeze = require(script.Parent.Freeze)
local Schema = require(script.Parent.Schema)

local ItemFields = {}

ItemFields.BASE = DefineModule.BASE_ITEM_FIELDS
ItemFields.NO_LATE_ITEMS_ERROR =
	"items must be declared in GameConfig.items; registering items after start is not supported in v1.3.0"

export type Namespaces = { [string]: { owner: string, schema: any } }

-- Collects every enabled module's item/mutation namespaces; a namespace claimed twice is an error.
function ItemFields.collect(order: { any }, errors: { string }): (Namespaces, Namespaces)
	local item: Namespaces = {}
	local mutation: Namespaces = {}
	for _, ref in order do
		local fields = ref.itemFields
		if fields == nil then
			continue
		end
		for _, pair in { { "item", item }, { "mutation", mutation } } :: { { any } } do
			local kind: string, target: Namespaces = pair[1] :: any, pair[2] :: any
			local declared: { [string]: any } = fields[kind] or {}
			for ns, schema in declared do
				local prev = target[ns]
				if prev then
					table.insert(
						errors,
						`itemFields.{kind}.{ns} is declared by both '{prev.owner}' and '{ref.name}': namespaces must be unique`
					)
				else
					target[ns] = { owner = ref.name, schema = schema }
				end
			end
		end
	end
	return item, mutation
end

local function enabledList(ns: Namespaces): string
	local names = {}
	for k in ns do
		table.insert(names, k)
	end
	table.sort(names)
	return if #names == 0 then "none" else table.concat(names, ", ")
end

-- Validates GameConfig.items (a list) against the base fields plus the enabled namespaces.
function ItemFields.validateItems(items: any, namespaces: Namespaces, errors: { string })
	if items == nil then
		return
	end
	if type(items) ~= "table" then
		table.insert(errors, "items must be a list of item definitions")
		return
	end
	local ids: { [string]: boolean } = {}
	for i, item in items do
		local where = `items[{tostring(i)}]`
		if type(i) ~= "number" then
			table.insert(errors, `items must be a list (array), got key {tostring(i)}`)
			continue
		end
		if type(item) ~= "table" then
			table.insert(errors, where .. " must be a table")
			continue
		end
		for field, entry in ItemFields.BASE do
			Schema.checkEntry(entry, item[field], `{where}.{field}`, errors)
		end
		if type(item.id) == "string" then
			if not DefineModule.isId(item.id) then
				table.insert(errors, `{where}.id must be a short id string`)
			elseif ids[item.id] then
				table.insert(errors, `{where}.id duplicate '{item.id}'`)
			else
				ids[item.id] = true
			end
		end
		for field, value in item do
			if ItemFields.BASE[field] ~= nil then
				continue
			end
			local ns = if type(field) == "string" then namespaces[field] else nil
			if ns == nil then
				table.insert(
					errors,
					`{where}.{tostring(field)}: no enabled module declares the item field namespace '{tostring(
						field
					)}' (declared: {enabledList(namespaces)})`
				)
			else
				Schema.validate(ns.schema, value, `{where}.{field}`, errors, errors)
			end
		end
	end
end

local function isRegistrationAttempt(key: any): boolean
	if type(key) ~= "string" then
		return false
	end
	local k = string.lower(key)
	return string.find(k, "register", 1, true) ~= nil
		or string.sub(k, 1, 3) == "add"
		or string.sub(k, 1, 6) == "insert"
		or k == "define"
end
ItemFields.isRegistrationAttempt = isRegistrationAttempt

-- Frozen read-only item list for ctx.gameConfig.items. Indexing a register/add-style name errors
-- with NO_LATE_ITEMS_ERROR; byId(id) looks one up.
function ItemFields.catalog(items: any): any
	local list = {}
	local byId: { [string]: any } = {}
	for i, item in items or {} do
		local frozen = Freeze.freezeCopy(item)
		list[i] = frozen
		if type(item) == "table" and type(item.id) == "string" then
			byId[item.id] = frozen
		end
	end
	local function lookup(id: string): any
		return byId[id]
	end
	setmetatable(
		list,
		table.freeze({
			__index = function(_, key): any
				if key == "byId" then
					return lookup
				end
				if isRegistrationAttempt(key) then
					error(ItemFields.NO_LATE_ITEMS_ERROR, 2)
				end
				return nil
			end,
			__newindex = function()
				error(ItemFields.NO_LATE_ITEMS_ERROR, 2)
			end,
		})
	)
	return table.freeze(list)
end

return ItemFields
