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

local function targetPlayer(userId: any): Player?
	local id = tonumber(userId)
	if id then
		return Players:GetPlayerByUserId(id)
	end
	return Players:GetPlayers()[1]
end

function Rarity.start()
	validateTables()

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
		if not ctx.services.Data.isLoaded(player) or not hasRoom(player) then
			return -- checked before spending, so a full inventory never costs currency
		end
		local reason = "roll:" .. tableId
		if not ctx.services.Economy.spend(player, cost.amount, reason, cost.currency) then
			return
		end
		local _, info = Rarity.roll(tableId, player, nil, { grant = true, reason = "roll" })
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

function Rarity.roll(
	tableId: string,
	player: Player,
	luck: number?,
	opts: Types.RollOptions?
): (Types.ItemDef?, Types.RollInfo)
	local o: Types.RollOptions = if type(opts) == "table" then opts else {}
	local t = getTable(tableId)
	if t == nil then
		return fail("unknown_table")
	end
	if o.paid == true and ctx.services.Policy.paidRandomRestricted(player) then
		return fail("restricted")
	end
	local Data = ctx.services.Data
	local data: Types.PlayerData? = Data.get(player)
	if data == nil then
		return fail("not_loaded")
	end
	if o.grant == true and not hasRoom(player) then
		return fail("inventory_full")
	end

	local list = weightsFor(t, luck)
	local pityCfg = if t.pity ~= nil and RollMath.validPity(t.pity) then t.pity else nil
	local pityCount = if pityCfg then ((data.pity or {})[tableId] or 0) else 0
	local forced = false
	if pityCfg and RollMath.pityForces(pityCount, pityCfg.threshold) then
		local restrictedList = RollMath.restrictTo(list, pityCfg.minTier)
		if restrictedList then
			list = restrictedList
			forced = true
		end
	end
	local entry = RollMath.pick(list, nextNumber())
	local def: Types.ItemDef? = if entry then ctx.services.Items.get(entry.itemId) else nil
	if entry == nil or def == nil then
		return fail("empty_table")
	end
	local mutation = RollMath.rollMutation(t.mutationChance, ctx.config.balance.mutations, nextNumber)
	local info: Types.RollInfo = { ok = true, pity = forced, mutation = mutation }

	if o.grant == true then
		local source = if o.paid == true then "paid:" .. tableId else (o.reason or "roll")
		local instance = ctx.services.Inventory.add(player, def.id, {
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
		local nextCount = RollMath.pityAfter(pityCount, def.rarity, pityCfg.minTier)
		Data.update(player, function(d: Types.PlayerData)
			if d.pity == nil then
				d.pity = {}
			end
			d.pity[tableId] = nextCount
		end)
	end
	if o.grant == true then
		ctx.net.feedback(player, "item", def.name, def.rarity)
	end
	return def, info
end

function Rarity.getOdds(tableId: string, luck: number?): { [string]: number }
	local t = getTable(tableId)
	if t == nil then
		return {}
	end
	return RollMath.odds(weightsFor(t, luck))
end

function Rarity.tiers(): { Types.RarityTierDef }
	return RarityTiers.all()
end

return Rarity
