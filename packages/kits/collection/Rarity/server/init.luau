--!strict
--[[
	Rarity server part (collection kit; module-api.md §13, §14). Rarity.new() -> a fresh part per
	runtime (the framework loader calls it, module-api.md §19.9).

	Tiers: config.Rarity.tiers ("standard7" or a custom ordered list, shared/Tiers.luau). Every
	item's `rarity` must be a tier of that list (boot error otherwise). Luck and pity compare
	tiers by list order (RollMath.withTiers). The definition contributes theme.rarity.tiers =
	the resolved config.Rarity.tiers (theme = function(config), framework Phase 2), so a custom
	list is written once, in config; it is also replicated as extra `tiers`.

	Compliance (§14): every rarity table is a random source (ctx.compliance.registerRandomSource,
	odds = getOddsDetail(tableId, player), sample = the weighted pick + pity + mutation + grant,
	luckDisclosed = table.luckDisclosed). Every outcome comes from ctx.compliance.roll /
	spendForRoll; nothing here samples outside a source. There is no opts.free (C3).

	api (frozen)
	  roll(tableId, player, luck?, opts?) -> (ItemDef?, RollInfo)   one ctx.tx; opts { grant?,
	        reason? }. Reasons: unknown_table, not_loaded, restricted, inventory_full (grant;
	        checked before rolling, so pity isn't spent), empty_table, policy_unknown.
	  getOdds(tableId, luck?) -> { [itemId]: probability }
	  getOddsDetail(tableId, player?) -> OddsDetail?   (with a player and a luckDisclosed table:
	        that player's luck)
	  tiers() -> { TierDef }   the resolved ordered list
	  setLuck(player, luck, tableId?) / getLuck(player, tableId?)   session luck (LuckRegistry);
	        setLuck re-sends that player's odds (replicated extra + compliance.disclose)
	txApi.roll(tx, tableId, luck?, opts?) -> (def?, info)   free unless tx is a purchase / spend;
	        no grant unless opts.grant
	purchaseOps.roll(tx, tableId, luck?) -> (def?, info)   grants (source "paid:<product>", M5)
	Paid rolls: a purchase tx, a table with paid = true, or a cost in a
	GameConfig.compliance.paidCurrencies currency (action roll -> compliance.spendForRoll: the spend
	and the roll commit together). Hard rule 11 (paid roll with luck ~= 1 needs luckDisclosed AND
	the client shown that luck) is enforced by Compliance for purchases / spendForRoll and here
	(LuckRule) for a paid = true table rolled outside a purchase.
	Replicated extra `odds` = { [tableId]: OddsDetail } for every table with a cost, paid = true or
	luckDisclosed = true (shared, luck 1), with a per-player override while that player's luck ~= 1
	on a luckDisclosed table (OddsSync). Section 'rarity' = { pity = { [tableId]: count } }.
	Client action `roll(tableId)` (own net.blink event Roll, 4/s burst 8): a table with a currency cost and paid ~= true. Capacity and
	the luck rule are checked before anything is spent; a paid currency goes through
	compliance.spendForRoll, a free one through Economy.txApi.spend in the SAME tx as the roll (no
	refund step: a failed roll discards the spend).
	Studio console: `rarity roll <tableId> [userId]`, `rarity odds <tableId> [luck|userId]`,
	`rarity luck <userId> <luck> [tableId]`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ItemsRef = require(Modules:WaitForChild("Items"):WaitForChild("module"))
local InventoryRef = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local EconomyRef = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local Tiers = require(Modules:WaitForChild("Rarity"):WaitForChild("shared"):WaitForChild("Tiers"))
local LuckRegistry = require(script.LuckRegistry)
local LuckRule = require(script.LuckRule)
local OddsSync = require(script.OddsSync)
local RollMath = require(script.RollMath)
local Util = require(script.Util)

local Rarity = {}

local function fail(reason: string): (any, any)
	return nil, { ok = false, reason = reason, pity = false }
end

local function isDisclosed(t: any): boolean
	return type(t) == "table" and (t.paid == true or type(t.cost) == "table" or t.luckDisclosed == true)
end

local function newRng(): () -> number
	local R = Random :: any
	if R ~= nil then
		local r = R.new()
		return function(): number
			return r:NextNumber()
		end
	end
	return function(): number
		return math.random()
	end
end

function Rarity.new(): any
	local ctx: any = nil
	local RM: any = RollMath
	local tierList: { any } = Tiers.PRESETS.standard7
	local tables: { [string]: any } = {}
	local mutations: { any } = {}
	local itemTier: { [string]: string } = {}
	local luckRegistry = LuckRegistry.new(RollMath.sanitizeLuck)
	local sharedOdds: { [string]: any } = {}
	local overridden: { [any]: boolean } = {}
	local loaded: { [any]: boolean } = {}
	local pending: any = nil
	local nextNumber = newRng()

	local part: any = {}
	local api: any = {}

	local function tierOf(itemId: string): string?
		return itemTier[itemId]
	end

	local function weightsFor(t: any, luck: any): any
		return RM.buildWeights(t.entries, tierOf, luck, t.luckMinTier)
	end

	local function isPaidTable(t: any): boolean
		return t.paid == true or (type(t.cost) == "table" and ctx.compliance.isPaidCurrency(t.cost.currency))
	end

	local function pityOf(t: any): any
		return if t.pity ~= nil and RM.validPity(t.pity) then t.pity else nil
	end

	-- Luck a roll uses when its `luck` argument is nil (review R5): an all-table luck boost never
	-- reaches a PAID roll on a table without luckDisclosed (it would make every such purchase error
	-- under hard rule 11); only a luck set for exactly that table does (and then errors, loudly).
	local function rollLuck(player: any, tableId: string, t: any, paid: boolean): number
		if paid and t.luckDisclosed ~= true then
			return luckRegistry:getTableOnly(player, tableId)
		end
		return luckRegistry:get(player, tableId)
	end

	function api.getLuck(player: any, tableId: string?): number
		return luckRegistry:get(player, tableId)
	end

	function api.getOdds(tableId: string, luck: number?): { [string]: number }
		local t = if type(tableId) == "string" then tables[tableId] else nil
		if t == nil then
			return {}
		end
		return RM.odds(weightsFor(t, luck))
	end

	function api.getOddsDetail(tableId: string, player: any?): any
		local t = if type(tableId) == "string" then tables[tableId] else nil
		if t == nil then
			return nil
		end
		local disclosed = t.luckDisclosed == true
		local luck = if player ~= nil and disclosed then luckRegistry:get(player, tableId) else 1
		return RM.oddsDetail(
			tableId,
			isPaidTable(t),
			weightsFor(t, luck),
			t.pity,
			t.mutationChance,
			mutations,
			luck,
			disclosed
		)
	end

	-- The player's odds: the shared map, or the shared map with their luck-adjusted details for
	-- luckDisclosed tables (only while some luck ~= 1); then Compliance's disclosure (the luck rule
	-- compares against what the client was last sent).
	local function sendPlayerOdds(player: any)
		local merged = OddsSync.playerOdds(sharedOdds, function(tableId: string): number
			return luckRegistry:get(player, tableId)
		end, function(tableId: string): any
			return api.getOddsDetail(tableId, player)
		end)
		if merged ~= nil then
			ctx.replicate.set(player, "odds", merged)
			overridden[player] = true
		elseif overridden[player] then
			ctx.replicate.set(player, "odds", nil) -- falls back to the shared map
			overridden[player] = nil
		end
		ctx.compliance.disclose(player)
	end

	local function replicateOdds()
		local all: { [string]: any } = {}
		for tableId, t in tables do
			if isDisclosed(t) then
				all[tableId] = api.getOddsDetail(tableId)
			end
		end
		sharedOdds = all
		ctx.replicate.setAll("odds", all)
	end

	function api.setLuck(player: any, luck: number, tableId: string?)
		if player == nil or type(player) == "string" or type(player) == "number" then
			error("[Rarity] setLuck: player must be a Player", 2)
		end
		if tableId ~= nil and type(tableId) ~= "string" then
			error("[Rarity] setLuck: tableId must be a string or nil", 2)
		end
		luckRegistry:set(player, luck, tableId)
		if loaded[player] then
			sendPlayerOdds(player)
		end
	end

	function api.tiers(): { any }
		return tierList
	end

	-- The randomness of one table (Compliance calls it from roll / spendForRoll, inside the tx).
	local function sampleFor(tableId: string): (any, number, any) -> any
		return function(player: any, luck: number, tx: any): any
			local p = pending
			pending = nil -- a nested roll (another source's sample) never sees these opts
			local o = if p then p.opts else {}
			local t = tables[tableId]
			local s = ctx.section(tx)
			local list = weightsFor(t, luck)
			local pityCfg = pityOf(t)
			local pityCount = if pityCfg then (s.pity[tableId] or 0) else 0
			local result = RM.step(list, pityCfg, pityCount, t.mutationChance, mutations, nextNumber)
			local def = if result then ctx.deps[ItemsRef].get(result.entry.itemId) else nil
			if result == nil or def == nil then
				if p then
					p.result = { def = nil, info = { ok = false, reason = "empty_table", pity = false } }
				end
				return nil
			end
			local forced, mutation = result.forced, result.mutation
			local info: any = { ok = true, pity = forced, mutation = mutation }
			if o.grant == true then
				-- source: "paid:<product>" / "paidcur:<tableId>" derived by Inventory from the tx (M5)
				local instance = ctx.depsTx[InventoryRef].add(tx, def.id, {
					mutation = mutation,
					source = if type(o.reason) == "string" then o.reason else "roll",
				})
				if instance == nil then
					if p then
						p.result = {
							def = def,
							info = {
								ok = false,
								reason = "inventory_full",
								pity = forced,
								mutation = mutation,
							},
						}
					end
					return nil -- pity untouched; a spendForRoll is discarded with it
				end
				info.instance = instance
				local name, rarity = def.name, def.rarity
				tx.after(function()
					ctx.net.feedback(player, "item", name, rarity)
				end)
			end
			if pityCfg then
				s.pity[tableId] = result.pityCount
			end
			if p then
				p.result = { def = def, info = info }
			end
			return { itemId = def.id, def = def, info = info }
		end
	end

	-- One roll of tableId inside the open tx. opts: { grant?, reason?, spend = { currency, amount }? }
	local function rollInTx(tx: any, tableId: any, luck: number?, opts: any?): (any, any)
		local t = if type(tableId) == "string" then tables[tableId] else nil
		if t == nil then
			return fail("unknown_table")
		end
		local o = if type(opts) == "table" then opts else {}
		local player = tx.player
		local derived = ctx.compliance.tagPaid(tx)
		local inPurchase = string.sub(derived, 1, 5) == "paid:"
		local paid = inPurchase or t.paid == true or o.spend ~= nil
		if t.paid == true and not inPurchase and ctx.policy.paidRandomRestricted(player) then
			return fail("restricted")
		end
		local effective = RM.sanitizeLuck(if luck == nil then rollLuck(player, tableId, t, paid) else luck)
		if t.paid == true and not inPurchase and o.spend == nil then
			-- hard rule 11 for a Robux table rolled outside a purchase (Compliance gates the rest)
			local sent = if effective ~= 1 then ctx.compliance.disclosed(player, tableId) else nil
			local ok, why = LuckRule.check({
				paid = true,
				luck = effective,
				luckDisclosed = t.luckDisclosed == true,
				sent = sent,
			})
			if not ok then
				error(LuckRule.message(tableId, effective, why or "?"), 2)
			end
		end
		if o.grant == true then
			if not ctx.isEnabled(InventoryRef) then
				error("[Rarity] roll with grant = true needs the Inventory module", 2)
			end
			if ctx.depsTx[InventoryRef].count(tx) >= ctx.deps[InventoryRef].cap(player) then
				return fail("inventory_full") -- checked before rolling, so pity is not consumed
			end
		end
		local mine = { opts = o, result = nil :: any }
		local outer = pending
		pending = mine
		local packed
		if o.spend ~= nil then
			packed = table.pack(
				pcall(ctx.compliance.spendForRoll, tx, o.spend.currency, o.spend.amount, tableId, effective)
			)
		else
			packed = table.pack(pcall(ctx.compliance.roll, tx, tableId, effective))
		end
		pending = outer
		if not packed[1] then
			error(packed[2], 0)
		end
		if mine.result ~= nil then
			return mine.result.def, mine.result.info
		end
		return fail(if type(packed[4]) == "string" then packed[4] else "no_outcome")
	end

	function api.roll(tableId: string, player: any, luck: number?, opts: any?): (any, any)
		if type(tableId) ~= "string" or tables[tableId] == nil then
			return fail("unknown_table")
		end
		if not ctx.data.isLoaded(player) then
			return fail("not_loaded")
		end
		local o = if type(opts) == "table" then { grant = opts.grant, reason = opts.reason } else nil
		local def, info = nil, nil
		local committed = ctx.tx(player, function(tx: any)
			def, info = rollInTx(tx, tableId, luck, o)
		end)
		if info == nil then
			return fail("not_loaded")
		end
		if not committed and info.ok then
			return fail("not_loaded")
		end
		return def, info
	end

	local function byUserId(userId: any): any
		local id = tonumber(userId)
		for player in loaded do
			if id == nil or player.UserId == id then
				return player
			end
		end
		return nil
	end

	local function requestRoll(player: any, tableId: any)
		if not Util.isId(tableId) then
			return
		end
		local t = tables[tableId]
		if t == nil or t.paid == true or type(t.cost) ~= "table" then
			return
		end
		local cost = t.cost
		if not Util.isNonNegativeNumber(cost.amount) or type(cost.currency) ~= "string" then
			return
		end
		local paid = ctx.compliance.isPaidCurrency(cost.currency)
		if paid and ctx.policy.paidRandomRestricted(player) then
			ctx.net.feedback(player, "toast", "Not available in your region")
			return
		end
		if not ctx.isEnabled(InventoryRef) or (not paid and not ctx.isEnabled(EconomyRef)) then
			return
		end
		local inventory = ctx.deps[InventoryRef]
		if not ctx.data.isLoaded(player) or inventory.count(player) >= inventory.cap(player) then
			return -- checked before spending, so a full inventory never costs currency
		end
		local luck = RM.sanitizeLuck(rollLuck(player, tableId, t, paid))
		if paid and luck ~= 1 then
			-- hard rule 11 before spending (a toast instead of the rule's error)
			local ok = LuckRule.check({
				paid = true,
				luck = luck,
				luckDisclosed = t.luckDisclosed == true,
				sent = ctx.compliance.disclosed(player, tableId),
			})
			if not ok then
				ctx.net.feedback(player, "toast", "Odds are updating, try again in a moment")
				return
			end
		end
		local reason = "roll:" .. tableId
		local ok, err = pcall(ctx.tx, player, function(tx: any)
			local spend = nil
			if paid then
				spend = { currency = cost.currency, amount = cost.amount }
			elseif not ctx.depsTx[EconomyRef].spend(tx, cost.amount, reason, cost.currency) then
				return -- not enough: nothing written
			end
			local _, info = rollInTx(tx, tableId, luck, { grant = true, reason = "roll", spend = spend })
			if not info.ok and not paid then
				error(`roll failed ({tostring(info.reason)}); the spend is discarded`, 0)
			end
		end)
		if not ok then
			ctx.log.warn(`roll {tableId} discarded (nothing spent): {tostring(err)}`)
		end
	end

	-- Client action `roll(tableId)` (own net.blink event Roll; core-v1.3.1 R19, was the framework
	-- event RequestRoll). Same rate limit as before (4/s, burst 8).
	part.actions = {
		roll = { limit = { rate = 4, burst = 8 }, handler = requestRoll },
	}

	------------------------------------------------------------------ validation

	local function validate(errors: { string })
		local resolved, tierErrors = Tiers.resolve(ctx.config.tiers)
		for _, e in tierErrors do
			table.insert(errors, e)
		end
		if resolved == nil then
			return
		end
		tierList = resolved
		RM = RollMath.withTiers(resolved)
		local names = {}
		for _, t in resolved do
			table.insert(names, t.id)
		end
		local tierNames = table.concat(names, ", ")
		for i, def in ctx.gameConfig.items do
			if def.rarity ~= nil then
				if not RM.isTier(def.rarity) then
					table.insert(
						errors,
						`items[{i}] '{tostring(def.id)}': rarity '{tostring(def.rarity)}' is not a tier of config.Rarity.tiers ({tierNames})`
					)
				else
					itemTier[def.id] = def.rarity
				end
			end
		end
		for tableId, t in ctx.config.rarityTables do
			local where = `config.Rarity.rarityTables.{tostring(tableId)}`
			if not Util.isId(tableId) then
				table.insert(errors, where .. ": table ids must be short id strings")
				continue
			end
			if type(t) ~= "table" or type(t.entries) ~= "table" then
				table.insert(errors, where .. ".entries must be a list of { itemId, weight }")
				continue
			end
			for j, entry in t.entries do
				if type(entry) ~= "table" or type(entry.itemId) ~= "string" then
					table.insert(
						errors,
						`{where}.entries[{tostring(j)}] must be a table with itemId and weight`
					)
				elseif itemTier[entry.itemId] == nil and ctx.gameConfig.items.byId(entry.itemId) == nil then
					ctx.log.warn(`table '{tableId}' references unknown item {entry.itemId}`)
				end
			end
			if t.luckMinTier ~= nil and not RM.isTier(t.luckMinTier) then
				table.insert(
					errors,
					`{where}.luckMinTier '{tostring(t.luckMinTier)}' is not a tier ({tierNames})`
				)
			end
			if t.pity ~= nil and not RM.validPity(t.pity) then
				ctx.log.warn(`table '{tableId}' has an invalid pity config; pity disabled`)
			end
			if t.cost ~= nil then
				local c = t.cost
				if
					type(c) ~= "table"
					or type(c.currency) ~= "string"
					or not Util.isNonNegativeNumber(c.amount)
				then
					table.insert(errors, where .. ".cost must be { currency = string, amount = number >= 0 }")
				end
			end
			tables[tableId] = t
		end
		local seen: { [string]: boolean } = {}
		for i, m in ctx.config.mutations do
			local where = `config.Rarity.mutations[{tostring(i)}]`
			if type(i) ~= "number" then
				table.insert(errors, "config.Rarity.mutations must be a list")
			elseif type(m) ~= "table" or not Util.isId(m.id) then
				table.insert(errors, where .. ".id must be a short id string")
			elseif seen[m.id] then
				table.insert(errors, `{where}.id duplicate '{m.id}'`)
			elseif m.weight ~= nil and not Util.isFiniteNumber(m.weight) then
				table.insert(errors, where .. ".weight must be a finite number")
			else
				seen[m.id] = true
				table.insert(mutations, m)
			end
		end
	end

	------------------------------------------------------------------ parts

	part.api = api
	part.txApi = {
		roll = function(tx: any, tableId: string, luck: number?, opts: any?): (any, any)
			local o = if type(opts) == "table" then { grant = opts.grant, reason = opts.reason } else nil
			return rollInTx(tx, tableId, luck, o)
		end,
	}
	part.purchaseOps = {
		roll = function(tx: any, tableId: string, luck: number?): (any, any)
			return rollInTx(tx, tableId, luck, { grant = true, reason = "product" })
		end,
	}

	function part.init(context: any)
		ctx = context
		local errors: { string } = {}
		validate(errors)
		if #errors > 0 then
			error("invalid Rarity config:\n  - " .. table.concat(errors, "\n  - "), 0)
		end
		ctx.depsExt[ItemsRef].mutations(mutations)
		for tableId, t in tables do
			ctx.compliance.registerRandomSource(tableId, {
				odds = function(player: any): any
					return api.getOddsDetail(tableId, player)
				end,
				sample = sampleFor(tableId),
				luckDisclosed = t.luckDisclosed == true,
			})
		end
		ctx.lifecycle.onPlayerLoaded(function(player: any)
			loaded[player] = true
		end)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			loaded[player] = nil
			overridden[player] = nil
			luckRegistry:clear(player)
		end)

		if ctx.isStudio then
			ctx.console.register("roll", function(caller: any, tableId: any, userId: any): string
				local player = if userId ~= nil then byUserId(userId) else (caller or byUserId(nil))
				if player == nil then
					return "no player"
				end
				local def, info =
					api.roll(tostring(tableId), player, nil, { grant = true, reason = "console" })
				if not info.ok then
					return "roll failed: " .. tostring(info.reason)
				end
				return string.format(
					"%s rolled %s (%s) mutation=%s pity=%s",
					player.Name,
					def and def.id or "?",
					def and tostring(def.rarity) or "?",
					tostring(info.mutation),
					tostring(info.pity)
				)
			end, "rarity roll <tableId> [userId]: roll and grant (Studio)")
			ctx.console.register("odds", function(_caller: any, tableId: any, arg: any): string
				local id = tostring(tableId)
				local n = tonumber(arg)
				-- luck is clamped to MAX_LUCK, so a larger integer can only be a userId
				local byUser = if n and n > RM.MAX_LUCK and n == math.floor(n) then byUserId(n) else nil
				local header: string
				local odds: { [string]: number }
				if byUser then
					local detail = api.getOddsDetail(id, byUser)
					odds = if detail then detail.items else {}
					header = string.format(
						"%s odds for %s (luck x%s, luckDisclosed=%s)",
						id,
						byUser.Name,
						tostring(detail and detail.luck or 1),
						tostring(detail and detail.luckDisclosed or false)
					)
				else
					local luck = RM.sanitizeLuck(n)
					odds = api.getOdds(id, luck)
					header = string.format("%s odds at luck x%s", id, tostring(luck))
				end
				local ids = {}
				for itemId in odds do
					table.insert(ids, itemId)
				end
				if #ids == 0 then
					return "unknown or empty table"
				end
				table.sort(ids, function(a, b)
					return odds[a] > odds[b]
				end)
				local lines = { header }
				for _, itemId in ids do
					table.insert(lines, string.format("  %s %.4f%%", itemId, odds[itemId] * 100))
				end
				return table.concat(lines, "\n")
			end, "rarity odds <tableId> [luck|userId]: print exact odds")
			ctx.console.register("luck", function(_caller: any, userId: any, luck: any, tableId: any): string
				local player = byUserId(userId)
				if player == nil then
					return "no player"
				end
				local tid = if tableId ~= nil then tostring(tableId) else nil
				api.setLuck(player, tonumber(luck) :: any, tid)
				return string.format(
					"%s luck = x%s (%s)",
					player.Name,
					tostring(api.getLuck(player, tid)),
					tid or "all tables"
				)
			end, "rarity luck <userId> <luck> [tableId]: set a player's session luck (Studio)")
		end
	end

	function part.start(_context: any)
		replicateOdds()
		local wire = {}
		for i, t in tierList do
			wire[i] = {
				id = t.id,
				color = t.color,
				glow = t.glow,
				glowStrength = t.glowStrength,
				soundKey = t.soundKey,
			}
		end
		ctx.replicate.setAll("tiers", wire)
	end

	return part
end

return Rarity
