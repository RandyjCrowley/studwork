--!strict
--[[
	COMPAT ADAPTER for the Collection kit (Items, Inventory, Rarity). Owned by Phase 1 agent A; DELETED IN PHASE 2 with
	the rest of packages/kits/compat.

	Once a module of this kit is REAL (its ModuleServers.loadServer returns a real server part,
	not Bridge.serverPart), the compat bridge calls this function to build the v1.2-shaped
	`services.<Module>` that the still-bridged v1.2 services (ctx.services.<Module> inside the
	bridge) and the multi-server sim (Bridge.compatServices(rt)) use:

	  adapter(name, rt, api, txApi, extensions) -> { [v1.2 function name]: fn }?

	All three Collection modules are real (core-v1.3.0 Phase 1, agent A). What this serves:

	Items      get / all / byTag / mutation / mutations (api), and
	           incomeOf(instance) = item.economy.incomePerSec x mutation.economy.incomeMultiplier
	           (removed from Items, Breaking; the bridged v1.2 Economy still calls it until the
	           Economy kit is real), onRegistered(fn) = a no-op (no items after boot, §12)
	Inventory  add / remove / get / list / count / cap / transfer / canTrade / sendGift (api);
	           add keeps the v1.2 meaning of an explicit "paid:"/"paidcur:" opts.source (sim specs
	           seed paid copies that way; the real api refuses it, M5);
	           addInto(tx12, itemId, opts) over the flat view (the v1.2 Shop of the sim and the
	           bridge's RequestRoll fallback): writes tx12.data.inventory, the working copy of the
	           'inventory' section in that framework tx;
	           and two glue pieces while siblings are bridged:
	             - the real ItemAdded / ItemRemoved are forwarded to the v1.2 signal set (bridged
	               Economy recomputes rates, bridged Plot auto-displays / clears its slot);
	             - the bridged Upgrades' "inventoryCap" effect becomes Inventory.capBonus
	               ("Upgrades"), read from config.Upgrades.upgrades + Upgrades.level. REMOVE this
	               when the Economy kit's Upgrades is real (it registers its own capBonus).
	Rarity     roll / getOdds / getOddsDetail / tiers / setLuck / getLuck (api)
]]

local ServerScriptService = game:GetService("ServerScriptService")

local function refNamed(rt: any, name: string): any
	for _, ref in rt.order or {} do
		if ref.name == name then
			return ref
		end
	end
	return nil
end

-- packages/kits/collection/server/<path...>
local function kitServer(...: string): any
	local node: any = ServerScriptService:WaitForChild("Kits"):WaitForChild("Collection")
	for _, part in { ... } do
		node = node:WaitForChild(part)
	end
	return (require :: any)(node)
end

local function forward(names: { string }, rt: any, api: any)
	local v12: any = nil
	local function v12Signals(): any
		if v12 == nil then
			local compat = rt.compat
			if type(compat) == "table" and type(compat.signals) == "function" then
				v12 = compat.signals()
			else
				-- production: the bridge's own v1.2 signal set (compatServices' second value)
				local Bridge = (require :: any)(script.Parent.Parent:WaitForChild("Bridge"))
				local _, signals = Bridge.compatServices(rt)
				v12 = signals
			end
		end
		return v12
	end
	for _, name in names do
		local own = api.signals and api.signals[name]
		if own == nil then
			rt.logSink(
				"warn",
				`[Compat.Collection] Inventory.signals.{name} missing; v1.2 listeners won't hear it`
			)
			continue
		end
		own:Connect(function(...: any)
			local set = v12Signals()
			local target = set and set[name]
			if target then
				target:Fire(...)
			end
		end)
	end
end

local function itemsAdapter(api: any): any
	return {
		get = api.get,
		all = api.all,
		byTag = api.byTag,
		mutation = api.mutation,
		mutations = api.mutations,
		incomeOf = function(instance: any): number
			if type(instance) ~= "table" then
				return 0
			end
			local def = api.get(instance.itemId)
			local econ = if def then def.economy else nil
			local income = if type(econ) == "table" and type(econ.incomePerSec) == "number"
				then econ.incomePerSec
				else 0
			local mult = 1
			if instance.mutation then
				local m = api.mutation(instance.mutation)
				local mEcon = if m then m.economy else nil
				if type(mEcon) == "table" and type(mEcon.incomeMultiplier) == "number" then
					mult = mEcon.incomeMultiplier
				end
			end
			return income * mult
		end,
		onRegistered = function(_fn: any)
			return { Connected = false, Disconnect = function() end }
		end,
	}
end

local function inventoryAdapter(rt: any, api: any, txApi: any, extensions: any): any
	local Util = kitServer("Util")
	local InventoryRules = kitServer("Inventory", "InventoryRules")

	forward({ "ItemAdded", "ItemRemoved" }, rt, api)

	-- bridged Upgrades' inventoryCap effect (remove once Upgrades is a real module)
	local upgradesRef = refNamed(rt, "Upgrades")
	if upgradesRef ~= nil then
		local cfg = rt.configs and rt.configs.Upgrades
		local upgrades = if type(cfg) == "table" then cfg.upgrades else nil
		local ok, err = pcall(extensions.capBonus, "Upgrades", function(player: any): number
			local upgradesApi = rt.apis[upgradesRef]
			return InventoryRules.capacity(0, upgrades, function(id: string): number
				local okLevel, level = pcall(upgradesApi.level, player, id)
				return if okLevel and type(level) == "number" then level else 0
			end)
		end)
		if not ok then
			rt.logSink("warn", "[Compat.Collection] Upgrades cap bonus not registered: " .. tostring(err))
		end
	end

	local function itemsApi(): any
		local ref = refNamed(rt, "Items")
		return if ref then rt.apis[ref] else nil
	end

	return {
		remove = api.remove,
		get = api.get,
		list = api.list,
		count = api.count,
		cap = api.cap,
		transfer = api.transfer,
		canTrade = api.canTrade,
		sendGift = api.sendGift,
		add = function(player: any, itemId: string, opts: any?): any
			local source = if type(opts) == "table" then opts.source else nil
			if not InventoryRules.isPaidSource(source) then
				return api.add(player, itemId, opts)
			end
			-- v1.2: an explicit paid source was stored as given (test seeding of paid copies)
			local o = table.clone(opts :: any)
			o.source = nil
			local added: any = nil
			local committed = rt.data.runTx(player, function(tx: any)
				added = txApi.add(tx, itemId, o)
				if added then
					rt.data.section(tx, "inventory").inventory[added.uid].source = source
				end
			end)
			return if committed and added then api.get(player, added.uid) else nil
		end,
		-- v1.2 InventoryInternal.addInto over the flat view of an open framework tx
		addInto = function(tx12: any, itemId: string, opts: any?): any
			local items = itemsApi()
			if type(itemId) ~= "string" or items == nil or items.get(itemId) == nil then
				return nil
			end
			local o = if type(opts) == "table" then opts else {}
			if o.mutation ~= nil and items.mutation(o.mutation) == nil then
				return nil
			end
			if o.source ~= nil and not Util.isShortString(o.source, InventoryRules.MAX_SOURCE_LENGTH) then
				return nil
			end
			if not (InventoryRules.validateMeta(o.meta)) then
				return nil
			end
			local inventory = tx12.data.inventory
			local n = 0
			for _ in inventory do
				n += 1
			end
			if n >= api.cap(tx12.player) then
				return nil
			end
			local instance = {
				uid = Util.newUid(),
				itemId = itemId,
				mutation = o.mutation,
				acquiredAt = os.time(),
				source = o.source,
				meta = if o.meta then table.clone(o.meta) else nil,
			}
			inventory[instance.uid] = instance
			local frozen = Util.frozenCopy(table.clone(instance))
			local player = tx12.player
			tx12.after(function()
				api.signals.ItemAdded:Fire(player, frozen)
			end)
			return frozen
		end,
	}
end

return function(name: string, rt: any, api: any, txApi: any, extensions: any): any
	if name == "Items" then
		return itemsAdapter(api)
	elseif name == "Inventory" then
		return inventoryAdapter(rt, api, txApi, extensions)
	elseif name == "Rarity" then
		return {
			roll = api.roll,
			getOdds = api.getOdds,
			getOddsDetail = api.getOddsDetail,
			tiers = api.tiers,
			setLuck = api.setLuck,
			getLuck = api.getLuck,
		}
	end
	return nil
end
