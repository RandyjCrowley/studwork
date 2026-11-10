--!strict
--[[
	Core.Rarity. OWNED BY AGENT C (core/c-items). Public API: Types.RarityAPI.

	roll(tableId, player, luck?, opts?) -> (ItemDef?, RollInfo). Order of checks:
		unknown table -> "unknown_table"; opts.paid and Policy restricted -> "restricted";
		player data not loaded -> "not_loaded"; opts.grant and inventory full -> "inventory_full"
		(checked BEFORE rolling, so pity is not consumed); table with no rollable entries ->
		"empty_table". Then: weighted pick (RollMath; luck multiplies tiers >= luckMinTier),
		pity restriction (see RollMath header for the exact rule; PlayerData.pity[tableId] is
		updated through Data.update only after the roll succeeds), mutation (mutationChance,
		weighted by Mutation.weight). With opts.grant the item is added via Inventory.add with
		source = "paid:<tableId>" when opts.paid, else opts.reason or "roll", and the player gets
		ctx.net.feedback(player, "item", def.name, def.rarity).
		opts.paid without grant: the caller grants and MUST use source "paid:<tableId>".
	getOdds(tableId, luck?) -> exact per-item probabilities of the non-pity roll (sum to 1).
	getOddsDetail(tableId) -> Types.OddsDetail (no luck; RollMath.oddsDetail). Replicated at start
		as ReplicatedState.odds[tableId] for every table with a cost or paid = true.
	tiers() -> RarityTiers.all().
	RequestRoll (client): tableId must be a table with a currency `cost` and paid ~= true.
		Capacity is checked first (no spend if full), then Economy.spend, then roll+grant; if the
		roll still fails the cost is refunded with Economy.grant.
	Studio console: `roll <tableId> [userId]`, `odds <tableId> [luck]`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = ReplicatedStorage:WaitForChild("Core")
local RarityTiers = require(Core:WaitForChild("RarityTiers"))
local Types = require(Core:WaitForChild("Types"))
local Validate = require(Core:WaitForChild("Validate"))
local RollMath = require(script.RollMath)
local Tx = require(script.Parent.Tx)

local Rarity = {}

local ctx: any = nil
local random = Random.new()
local function nextNumber(): number
	return random:NextNumber()
end

local function fail(reason: string): (Types.ItemDef?, Types.RollInfo)
	return nil, { ok = false, reason = reason, pity = false }
end

local function getTable(tableId: any): Types.RarityTableConfig?
	if type(tableId) ~= "string" then
		return nil
	end
	local t = ctx.config.balance.rarityTables[tableId]
	return if type(t) == "table" then t else nil
end

local function tierOf(itemId: string): Types.RarityTier?
	local def = ctx.services.Items.get(itemId)
	return if def then def.rarity else nil
end

local function weightsFor(t: Types.RarityTableConfig, luck: any): RollMath.WeightedList
	return RollMath.buildWeights(t.entries, tierOf, luck, t.luckMinTier)
end

local function hasRoom(player: Player): boolean
	local Inventory = ctx.services.Inventory
	return Inventory.count(player) < Inventory.cap(player)
end

function Rarity.init(context: any)
	ctx = context
end

local function validateTables()
	for tableId, t in ctx.config.balance.rarityTables do
		for _, entry in t.entries do
			if ctx.services.Items.get(entry.itemId) == nil then
				warn(
					"[Core.Rarity] table '"
						.. tostring(tableId)
						.. "' references unknown item "
						.. tostring(entry.itemId)
				)
			end
		end
		if t.pity ~= nil and not RollMath.validPity(t.pity) then
			warn(
				"[Core.Rarity] table '" .. tostring(tableId) .. "' has an invalid pity config; pity disabled"
			)
		end
	end
end

local function currencyIsPaid(currency: any): boolean
	local list = ctx.config.balance.paidCurrencies
	return type(list) == "table" and table.find(list, currency) ~= nil
end

-- Every table a player can pay for (a currency cost or Robux) is disclosed to every client.
local function replicateOdds()
	local all: { [string]: Types.OddsDetail } = {}
	for tableId, t in ctx.config.balance.rarityTables do
		if type(t) == "table" and (t.paid == true or type(t.cost) == "table") then
			local detail = Rarity.getOddsDetail(tableId)
			if detail then
				all[tableId] = detail
			end
		end
	end
	ctx.setReplicatedAll("odds", all)
end

local function targetPlayer(userId: any): Player?
	local id = tonumber(userId)
	if id then
		return Players:GetPlayerByUserId(id)
	end
	return Players:GetPlayers()[1]
end

function Rarity.start()
	validateTables()
	replicateOdds()

	ctx.net.handle("RequestRoll", function(player: Player, tableId: any)
		if not Validate.isId(tableId) then
			return
		end
		local t = getTable(tableId)
		if t == nil or t.paid == true or type(t.cost) ~= "table" then
			return
		end
		local cost = t.cost
		if not Validate.isNonNegativeNumber(cost.amount) or type(cost.currency) ~= "string" then
			return
		end
		-- A roll paid with a currency that can be bought with Robux is a paid random item
		-- (balance.paidCurrencies): restricted players can't roll, results are tagged "paid:".
		local paid = currencyIsPaid(cost.currency)
		if paid and ctx.services.Policy.paidRandomRestricted(player) then
			ctx.net.feedback(player, "toast", "Not available in your region")
			return
		end
		-- ConfigValidate requires both for costed tables; stay defensive anyway
		if not ctx.isEnabled("Economy") or not ctx.isEnabled("Inventory") then
			return
		end
		if not ctx.services.Data.isLoaded(player) or not hasRoom(player) then
			return -- checked before spending, so a full inventory never costs currency
		end
		local reason = "roll:" .. tableId
		if not ctx.services.Economy.spend(player, cost.amount, reason, cost.currency) then
			return
		end
		local _, info = Rarity.roll(
			tableId,
			player,
			nil,
			{ grant = true, reason = "roll", paid = paid } :: Types.RollOptions
		)
		if not info.ok then
			ctx.services.Economy.grant(player, cost.amount, "refund:" .. tableId, cost.currency)
		end
	end)

	if ctx.isStudio then
		ctx.console.register(
			"roll",
			"roll <tableId> [userId]: roll and grant (Studio)",
			function(tableId: any, userId: any)
				local player = targetPlayer(userId)
				if player == nil then
					return "no player"
				end
				local def, info =
					Rarity.roll(tostring(tableId), player, nil, { grant = true, reason = "console" })
				if not info.ok then
					return "roll failed: " .. tostring(info.reason)
				end
				return string.format(
					"%s rolled %s (%s) mutation=%s pity=%s",
					player.Name,
					def and def.id or "?",
					def and def.rarity or "?",
					tostring(info.mutation),
					tostring(info.pity)
				)
			end
		)
		ctx.console.register(
			"odds",
			"odds <tableId> [luck]: print exact odds",
			function(tableId: any, luck: any)
				local odds = Rarity.getOdds(tostring(tableId), tonumber(luck))
				local ids = {}
				for id in odds do
					table.insert(ids, id)
				end
				if #ids == 0 then
					return "unknown or empty table"
				end
				table.sort(ids, function(a, b)
					return odds[a] > odds[b]
				end)
				local lines = {}
				for _, id in ids do
					table.insert(lines, string.format("  %s %.4f%%", id, odds[id] * 100))
				end
				return table.concat(lines, "\n")
			end
		)
	end
end

local function countOf(data: Types.PlayerData): number
	local n = 0
	for _ in data.inventory do
		n += 1
	end
	return n
end

-- ctx-only (Context.RarityInternal): roll inside an open transaction. Pity and the granted item
-- are written into tx.data; the feedback and ItemAdded run after the transaction commits.
function Rarity.rollInto(
	tx: Tx.Tx,
	tableId: string,
	luck: number?,
	opts: Types.RollOptions?
): (Types.ItemDef?, Types.RollInfo)
	local o: Types.RollOptions = if type(opts) == "table" then opts else {}
	local t = getTable(tableId)
	if t == nil then
		return fail("unknown_table")
	end
	-- a table marked paid (Robux) is always treated as paid, whatever the caller passed
	if t.paid == true and o.paid ~= true then
		o = table.clone(o)
		o.paid = true
	end
	local player = tx.player
	if o.paid == true and ctx.services.Policy.paidRandomRestricted(player) then
		return fail("restricted")
	end
	local data: Types.PlayerData = tx.data
	if o.grant == true then
		if not ctx.isEnabled("Inventory") then
			error("[Core.Rarity] roll with grant = true needs the Inventory module", 2)
		end
		if countOf(data) >= ctx.services.Inventory.cap(player) then
			return fail("inventory_full") -- checked before rolling, so pity is not consumed
		end
	end

	local list = weightsFor(t, luck)
	local pityCfg = if t.pity ~= nil and RollMath.validPity(t.pity) then t.pity else nil
	local pityCount = if pityCfg then ((data.pity or {})[tableId] or 0) else 0
	local result =
		RollMath.step(list, pityCfg, pityCount, t.mutationChance, ctx.config.balance.mutations, nextNumber)
	local def: Types.ItemDef? = if result then ctx.services.Items.get(result.entry.itemId) else nil
	if result == nil or def == nil then
		return fail("empty_table")
	end
	local forced, mutation = result.forced, result.mutation
	local info: Types.RollInfo = { ok = true, pity = forced, mutation = mutation }

	if o.grant == true then
		local source = if o.paid == true then "paid:" .. tableId else (o.reason or "roll")
		local instance = ctx.services.Inventory.addInto(tx, def.id, {
			mutation = mutation,
			source = source,
			reason = o.reason,
		})
		if instance == nil then
			return def, { ok = false, reason = "inventory_full", pity = forced, mutation = mutation }
		end
		info.instance = instance
	end

	if pityCfg then
		if data.pity == nil then
			data.pity = {}
		end
		data.pity[tableId] = result.pityCount
	end
	if o.grant == true then
		local name, rarity = def.name, def.rarity
		tx.after(function()
			ctx.net.feedback(player, "item", name, rarity)
		end)
	end
	return def, info
end

function Rarity.roll(
	tableId: string,
	player: Player,
	luck: number?,
	opts: Types.RollOptions?
): (Types.ItemDef?, Types.RollInfo)
	local def: Types.ItemDef? = nil
	local info: Types.RollInfo? = nil
	local queue: { () -> () } = {}
	local committed = ctx.services.Data.update(player, function(d: Types.PlayerData)
		def, info = Rarity.rollInto(Tx.new(player, d, queue), tableId, luck, opts)
	end)
	if not committed or info == nil then
		if getTable(tableId) == nil then
			return fail("unknown_table")
		end
		return fail("not_loaded")
	end
	Tx.flush(queue)
	return def, info :: Types.RollInfo
end

function Rarity.getOdds(tableId: string, luck: number?): { [string]: number }
	local t = getTable(tableId)
	if t == nil then
		return {}
	end
	return RollMath.odds(weightsFor(t, luck))
end

-- Full disclosure of a table's odds (no luck): base item odds, mutation odds, every
-- (item, mutation) outcome on a normal roll and the forced-roll odds of a pity rule that can apply.
function Rarity.getOddsDetail(tableId: string): Types.OddsDetail?
	local t = getTable(tableId)
	if t == nil then
		return nil
	end
	local paid = t.paid == true or (type(t.cost) == "table" and currencyIsPaid(t.cost.currency))
	return RollMath.oddsDetail(
		tableId,
		paid,
		weightsFor(t, nil),
		t.pity,
		t.mutationChance,
		ctx.config.balance.mutations
	)
end

function Rarity.tiers(): { Types.RarityTierDef }
	return RarityTiers.all()
end

return Rarity
