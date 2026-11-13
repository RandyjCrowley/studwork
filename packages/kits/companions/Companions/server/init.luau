--!strict
local Modules = game:GetService("ReplicatedStorage").Modules
local Config = require(Modules.Companions.shared.Config)
local Looks = require(Modules.Companions.shared.Looks)
local Items = require(Modules.Items.module)
local Inventory = require(Modules.Inventory.module)
local Rarity = require(Modules.Rarity.module)
local Economy = require(Modules.Economy.module)
local Rebirth = require(Modules.Rebirth.module)
local Plot = require(Modules.Plot.module)
local Companions = {}
local function validId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 64
end
local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end
-- Resume once: callbacks must finish synchronously, including inside transactions.
local function sync(fn: any, ...: any): (boolean, any)
	local thread = coroutine.create(fn)
	local ok, result = coroutine.resume(thread, ...)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return false, nil
	end
	return ok, result
end
local function equal(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not equal(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end
function Companions.new(): any
	local ctx: any
	local loaded: { [any]: boolean } = {}
	local predicates: { [string]: any } = {}
	local scores: { [string]: any } = {}
	local registry: any
	local decorator: any
	local invalidate: any
	local changed: any
	local dirty = false
	local published: any = nil
	local previous: { [any]: any } = {}
	local api: any = {}
	local part: any = { api = api }
	api.signals = setmetatable({}, {
		__index = function(_, key)
			return if key == "EquippedChanged" then changed else nil
		end,
	})
	local function enabled(): boolean
		return ctx.config.flag == nil or ctx.flags.isOn(ctx.config.flag)
	end
	local function allowed(player: any, copy: any): boolean
		for _, fn in predicates do
			local ok, result = sync(fn, player, copy)
			if not ok or result ~= true then
				return false
			end
		end
		return true
	end
	local function eligible(player: any, copy: any): boolean
		local def = ctx.deps[Items].get(copy.itemId)
		return validId(copy.uid)
			and validId(copy.itemId)
			and (copy.mutation == nil or validId(copy.mutation))
			and def ~= nil
			and def.companions ~= nil
			and allowed(player, copy)
	end
	local function selected(player: any, uids: any, copies: any): { any }
		local byUid = {}
		for _, copy in copies do
			byUid[copy.uid] = copy
		end
		local result, seen = {}, {}
		for _, uid in uids do
			local copy = byUid[uid]
			if #result < ctx.config.slots and not seen[uid] and copy and eligible(player, copy) then
				seen[uid] = true
				table.insert(result, copy)
			end
		end
		return result
	end
	function api.equipped(player: any): { any }
		if not ctx.data.isLoaded(player) or not enabled() then
			return table.freeze({})
		end
		local result = {}
		for _, copy in selected(player, ctx.data.get(player).equipped, ctx.deps[Inventory].list(player)) do
			table.insert(
				result,
				table.freeze({ uid = copy.uid, itemId = copy.itemId, mutation = copy.mutation })
			)
		end
		return table.freeze(result)
	end
	function api.bonus(player: any): number
		local total = 1
		for _, copy in api.equipped(player) do
			local fields = ctx.deps[Items].get(copy.itemId).companions
			local value = fields.incomeBonus
			if finite(value) and value > 0 then
				total = math.min(ctx.config.bonusCap, total + value)
			end
		end
		return math.min(ctx.config.bonusCap, total)
	end
	-- setAll advances shared versions even for equal tables; compare before publishing.
	local function flush()
		local roster = {}
		for player in loaded do
			if ctx.data.isLoaded(player) and enabled() then
				roster[tostring(player.UserId)] = { userId = player.UserId, equipped = api.equipped(player) }
			end
		end
		if not equal(roster, published) then
			ctx.replicate.setAll("roster", roster)
			published = roster
		end
		dirty = false
	end
	local function notify(player: any)
		if not loaded[player] then
			return
		end
		local copies, bonus = api.equipped(player), api.bonus(player)
		local state = { copies = copies, bonus = bonus, enabled = enabled() }
		if not equal(state, previous[player]) then
			previous[player] = state
			ctx.replicate.set(player, "bonus", bonus)
			ctx.replicate.set(player, "enabled", enabled())
			if invalidate then
				invalidate(player)
			end
			changed:Fire(player, copies, bonus)
			dirty = true
		end
	end
	local function best(player: any, copies: any): { string }
		local tiers = if ctx.isEnabled(Rarity) then ctx.deps[Rarity].tiers() else ctx.theme.rarity.tiers
		local ranks = {}
		for i, tier in tiers do
			ranks[tier.id] = i
		end
		local ranked = {}
		for _, copy in copies do
			if eligible(player, copy) then
				local def = ctx.deps[Items].get(copy.itemId)
				local score = def.companions.score or 0
				for _, fn in scores do
					local ok, contribution = sync(fn, player, copy, def)
					if ok and finite(contribution) then
						score += math.max(0, contribution)
					end
				end
				table.insert(ranked, { uid = copy.uid, rank = ranks[def.rarity] or 0, score = score })
			end
		end
		table.sort(ranked, function(a, b)
			if a.rank ~= b.rank then
				return a.rank > b.rank
			end
			if a.score ~= b.score then
				return a.score > b.score
			end
			return a.uid < b.uid
		end)
		local result = {}
		for i = 1, math.min(#ranked, ctx.config.slots) do
			table.insert(result, ranked[i].uid)
		end
		return result
	end
	local function reconcileInto(tx: any, player: any, auto: boolean)
		local section = ctx.section(tx)
		local copies = ctx.depsTx[Inventory].list(tx)
		local uids = {}
		if auto and enabled() and ctx.config.autoEquipBest and not section.manual then
			uids = best(player, copies)
		else
			for _, copy in selected(player, section.equipped, copies) do
				table.insert(uids, copy.uid)
			end
		end
		if not equal(uids, section.equipped) then
			section.equipped = uids
		end
	end
	local function transact(player: any, fn: any): (boolean, string?)
		if not ctx.data.isLoaded(player) then
			return false, "not_loaded"
		end
		local ok, committed, why = pcall(ctx.tx, player, function(tx: any)
			local reason = fn(tx)
			if reason == nil then
				tx.after(function()
					notify(player)
				end)
			end
			return reason
		end)
		if not ok or not committed then
			return false, "transaction_failed"
		end
		return why == nil, why
	end
	-- Reservation callers rely on invalidation completing before they activate an offer.
	function api.refresh(player: any): (boolean, string?)
		local ok, why = transact(player, function(tx)
			reconcileInto(tx, player, false)
		end)
		if ok and invalidate then
			invalidate(player)
		end
		return ok, why
	end
	function api.equip(player: any, uid: any): (boolean, string?)
		if not enabled() then
			return false, "disabled"
		end
		if not validId(uid) then
			return false, "invalid_uid"
		end
		return transact(player, function(tx: any): string?
			local copy
			for _, owned in ctx.depsTx[Inventory].list(tx) do
				if owned.uid == uid then
					copy = owned
				end
			end
			if not copy then
				return "not_owned"
			end
			local def = ctx.deps[Items].get(copy.itemId)
			if not def or not def.companions then
				return "not_companion"
			end
			if not eligible(player, copy) then
				return "locked"
			end
			local section = ctx.section(tx)
			if table.find(section.equipped, uid) then
				return "already_equipped"
			end
			if #section.equipped >= ctx.config.slots then
				return "slots_full"
			end
			table.insert(section.equipped, uid)
			section.manual = true
			return nil
		end)
	end
	function api.unequip(player: any, uid: any): (boolean, string?)
		if not enabled() then
			return false, "disabled"
		end
		if not validId(uid) then
			return false, "invalid_uid"
		end
		return transact(player, function(tx: any): string?
			local section = ctx.section(tx)
			local index = table.find(section.equipped, uid)
			if not index then
				return "not_equipped"
			end
			table.remove(section.equipped, index)
			section.manual = true
			return nil
		end)
	end
	function api.equipBest(player: any): (boolean, string?)
		if not enabled() then
			return false, "disabled"
		end
		return transact(player, function(tx: any): string?
			local section = ctx.section(tx)
			section.equipped = best(player, ctx.depsTx[Inventory].list(tx))
			section.manual = true
			return nil
		end)
	end
	function api.registerLook(key: string, fn: any): any
		local connection = registry.registerLook(key, fn)
		if decorator then
			decorator:Invalidate()
		end
		local connected = true
		return {
			Disconnect = function()
				if not connected then
					return
				end
				connected = false
				connection:Disconnect()
				if decorator then
					decorator:Invalidate()
				end
			end,
		}
	end
	function api.applyLook(model: any, def: any, mutation: any)
		registry.applyLook(model, def, mutation)
	end
	local function register(store: any, id: string, fn: any): any
		assert(validId(id) and type(fn) == "function", "expected bounded id and callback")
		assert(store[id] == nil, "callback already registered")
		store[id] = fn
		local function refreshAll()
			for player in loaded do
				api.refresh(player)
			end
		end
		refreshAll()
		return {
			Disconnect = function()
				if store[id] == fn then
					store[id] = nil
					refreshAll()
				end
			end,
		}
	end
	part.extensions = {
		canEquipWith = function(id, fn)
			return register(predicates, id, fn)
		end,
		scoreWith = function(id, fn)
			return register(scores, id, fn)
		end,
	}
	part.actions = {
		equip = { limit = { rate = 4, burst = 8 }, handler = api.equip },
		unequip = { limit = { rate = 4, burst = 8 }, handler = api.unequip },
		equipBest = { limit = { rate = 1, burst = 2 }, handler = api.equipBest },
	}
	function part.init(context: any)
		ctx = context
		Config.validate(ctx.config, ctx.gameConfig, ctx.flags)
		registry = Looks.new()
		changed = ctx.signals.new("EquippedChanged")
		if ctx.isEnabled(Economy) and ctx.config.incomeBonusEnabled then
			invalidate = ctx.depsExt[Economy].rateFactor("companions", api.bonus)
		end
		ctx.depsExt[Inventory].onItemRemoved(function(tx, player, copy)
			local section = ctx.section(tx)
			local index = table.find(section.equipped, copy.uid)
			if index then
				table.remove(section.equipped, index)
				tx.after(function()
					notify(player)
				end)
			end
		end)
		if ctx.isEnabled(Rebirth) then
			ctx.depsExt[Rebirth].resetStep("companions", function(tx, player)
				reconcileInto(tx, player, false)
				tx.after(function()
					notify(player)
				end)
			end)
		end
		if ctx.isEnabled(Plot) then
			decorator = ctx.depsExt[Plot].decorate("companions", function(model, def, copy)
				api.applyLook(model, def, copy.mutation)
			end)
		end
		ctx.lifecycle.onPlayerLoaded(function(player)
			loaded[player] = true
			transact(player, function(tx)
				reconcileInto(tx, player, true)
			end)
			notify(player)
			flush()
		end)
		ctx.lifecycle.onPlayerRemoving(function(player)
			loaded[player] = nil
			previous[player] = nil
			flush()
		end)
		ctx.lifecycle.onTick(0.25, function()
			if dirty then
				flush()
			end
		end)
		if ctx.config.flag then
			ctx.flags.onChanged(ctx.config.flag, function()
				for player in loaded do
					api.refresh(player)
					notify(player)
				end
				flush()
			end)
		end
		ctx.console.register("debug", function(_caller, userId)
			local owners, copies, triangles, unknown = 0, 0, 0, 0
			for player in loaded do
				if userId == nil or tonumber(userId) == player.UserId then
					owners += 1
					for _, copy in api.equipped(player) do
						copies += 1
						local estimate = ctx.deps[Items].get(copy.itemId).companions.triangles
						if estimate then
							triangles += estimate
						else
							unknown += 1
						end
					end
				end
			end
			return `owners={owners} copies={copies} slots={ctx.config.slots} maxDrawn={ctx.config.maxDrawn} distance={ctx.config.drawDistance} nearHz={ctx.config.nearHz} farHz={ctx.config.farHz} estimatedTriangles={triangles} unknownEstimates={unknown}`
		end)
	end
	function part.start()
		ctx.deps[Inventory].signals.ItemAdded:Connect(function(player)
			if loaded[player] then
				transact(player, function(tx)
					reconcileInto(tx, player, true)
				end)
			end
		end)
	end
	return part
end
return Companions
