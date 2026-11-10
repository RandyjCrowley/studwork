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
		source = "paid:<tableId>" for Robux rolls (paid table / Shop tx.roll), "paidcur:<tableId>"
		for rolls priced in a paid currency, else opts.reason or "roll", and the player gets
		ctx.net.feedback(player, "item", def.name, def.rarity).
		opts.paid without grant: the caller grants and MUST use source "paid:<tableId>".
	getOdds(tableId, luck?) -> exact per-item probabilities of the non-pity roll (sum to 1).
	getOddsDetail(tableId, player?) -> Types.OddsDetail (RollMath.oddsDetail). With a player and a
		luckDisclosed table the odds include getLuck(player, tableId) (detail.luck); else luck 1.
	setLuck(player, luck, tableId?) / getLuck(player, tableId?): session-only luck registry
		(LuckRegistry; per-table wins; sanitised; cleared on PlayerRemoving). roll/rollInto with
		luck == nil use getLuck. setLuck re-sends that player's odds.
	Replication (OddsSync): ReplicatedState.odds = shared luck-free map (setReplicatedAll) for
		every table with a cost, paid = true or luckDisclosed = true; a per-player override
		(setReplicated) only while the player's luck ~= 1 on a luckDisclosed table. Rebuilt and
		re-sent on every Items.register after start (N3).
	Hard rule 11 (LuckRule): a paid roll (opts.paid or t.paid) with effective luck ~= 1 ERRORS in
		rollInto unless t.luckDisclosed and ctx.sentReplicated(player, "odds")[tableId] carries
		exactly that luck. RequestRoll checks the rule before spending (toast, no spend).
	tiers() -> RarityTiers.all().
	RequestRoll (client): tableId must be a table with a currency `cost` and paid ~= true.
		Capacity and the luck rule are checked first (no spend), then Economy.spend, then
		roll+grant; if the roll still fails the cost is refunded with Economy.grant.
	Studio console: `roll <tableId> [userId]`, `odds <tableId> [luck|userId]`,
		`luck <userId> <luck> [tableId]`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = ReplicatedStorage:WaitForChild("Core")
local RarityTiers = require(Core:WaitForChild("RarityTiers"))
local Types = require(Core:WaitForChild("Types"))
local Validate = require(Core:WaitForChild("Validate"))
local LuckRegistry = require(script.LuckRegistry)
local LuckRule = require(script.LuckRule)
local OddsSync = require(script.OddsSync)
local RollMath = require(script.RollMath)
local Tx = require(script.Parent.Tx)

local Rarity = {}

local ctx: any = nil
local luckRegistry = LuckRegistry.new(RollMath.sanitizeLuck)
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

-- Every table a player can pay for (a currency cost or Robux) or that discloses luck is
-- disclosed to every client (shared, luck 1); see OddsSync for the per-player overrides.
local sharedOdds: { [string]: Types.OddsDetail } = {}
local overridden: { [Player]: boolean } = {}

local function isDisclosed(t: any): boolean
	return type(t) == "table" and (t.paid == true or type(t.cost) == "table" or t.luckDisclosed == true)
end

-- Sends `player` the odds their rolls use: the shared map, or the shared map with their
-- luck-adjusted details for luckDisclosed tables (only while some luck ~= 1).
local function sendPlayerOdds(player: Player)
	local merged = OddsSync.playerOdds(sharedOdds, function(tableId: string): number
		return Rarity.getLuck(player, tableId)
	end, function(tableId: string): any
		return Rarity.getOddsDetail(tableId, player)
	end)
	if merged ~= nil then
		ctx.setReplicated(player, "odds", merged)
		overridden[player] = true
	elseif overridden[player] then
		ctx.setReplicated(player, "odds", nil) -- falls back to the shared map
		overridden[player] = nil
	end
end

local function replicateOdds()
	local all: { [string]: Types.OddsDetail } = {}
	for tableId, t in ctx.config.balance.rarityTables do
		if isDisclosed(t) then
			local detail = Rarity.getOddsDetail(tableId)
			if detail then
				all[tableId] = detail
			end
		end
	end
	sharedOdds = all
	ctx.setReplicatedAll("odds", all)
	for _, player in Players:GetPlayers() do
		if overridden[player] or luckRegistry:has(player) then
			sendPlayerOdds(player)
		end
	end
end

-- The luck rule for a roll of `tableId` by `player` with an already-sanitised luck.
local function luckRuleOk(
	player: Player,
	tableId: string,
	t: any,
	paid: boolean,
	luck: number
): (boolean, string?)
	local sent: any = nil
	if paid and luck ~= 1 then
		local odds = ctx.sentReplicated(player, "odds")
		sent = if type(odds) == "table" then odds[tableId] else nil
	end
	return LuckRule.check({ paid = paid, luck = luck, luckDisclosed = t.luckDisclosed == true, sent = sent })
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
	-- N3: items registered after start change the odds; rebuild and re-send everything.
	ctx.services.Items.onRegistered(function(_defs: { Types.ItemDef })
		replicateOdds()
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		luckRegistry:clear(player)
		overridden[player] = nil
	end)

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
		-- hard rule 11, checked before spending: rollInto would error after the spend otherwise
		if not luckRuleOk(player, tableId, t, paid, Rarity.getLuck(player, tableId)) then
			ctx.net.feedback(player, "toast", "Odds are updating, try again in a moment")
			return
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
			"odds <tableId> [luck|userId]: print exact odds (a userId shows that player's disclosed odds)",
			function(tableId: any, arg: any)
				local id = tostring(tableId)
				local n = tonumber(arg)
				-- luck is clamped to MAX_LUCK, so a larger integer can only be a userId
				local byUser = if n
						and n > RollMath.MAX_LUCK
						and n == math.floor(n)
					then Players:GetPlayerByUserId(n)
					else nil
				local header: string
				local odds: { [string]: number }
				if byUser then
					local detail = Rarity.getOddsDetail(id, byUser)
					odds = if detail then detail.items else {}
					header = string.format(
						"%s odds for %s (luck x%s, luckDisclosed=%s)",
						id,
						byUser.Name,
						tostring(detail and detail.luck or 1),
						tostring(detail and detail.luckDisclosed or false)
					)
				else
					local luck = RollMath.sanitizeLuck(n)
					odds = Rarity.getOdds(id, luck)
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
			end
		)
		ctx.console.register(
			"luck",
			"luck <userId> <luck> [tableId]: set a player's session luck (Studio)",
			function(userId: any, luck: any, tableId: any)
				local player = targetPlayer(userId)
				if player == nil then
					return "no player"
				end
				local tid = if tableId ~= nil then tostring(tableId) else nil
				Rarity.setLuck(player, tonumber(luck) :: any, tid)
				return string.format(
					"%s luck = x%s (%s)",
					player.Name,
					tostring(Rarity.getLuck(player, tid)),
					tid or "all tables"
				)
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
	-- luck nil = the player's session luck; hard rule 11 before anything is written
	local effectiveLuck = RollMath.sanitizeLuck(if luck == nil then Rarity.getLuck(player, tableId) else luck)
	local ruleOk, ruleReason = luckRuleOk(player, tableId, t, o.paid == true, effectiveLuck)
	if not ruleOk then
		error(LuckRule.message(tableId, effectiveLuck, ruleReason or "?"), 2)
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

	local list = weightsFor(t, effectiveLuck)
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
		-- "paid:" = bought with Robux (a paid table or a Shop PurchaseTx roll): kept on rebirth.
		-- "paidcur:" = priced in a balance.paidCurrencies currency: same policy/trade rules, but
		-- wiped by rebirth like other earned items (review N5).
		local robux = t.paid == true or string.sub(o.reason or "", 1, 8) == "product:"
		local source = if o.paid ~= true
			then (o.reason or "roll")
			elseif robux then "paid:" .. tableId
			else "paidcur:" .. tableId
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

-- Full disclosure of a table's odds: base item odds, mutation odds, every (item, mutation)
-- outcome on a normal roll and the forced-roll odds of a pity rule that can apply. With a player
-- and a luckDisclosed table the probabilities include that player's luck; otherwise luck 1.
function Rarity.getOddsDetail(tableId: string, player: Player?): Types.OddsDetail?
	local t = getTable(tableId)
	if t == nil then
		return nil
	end
	local paid = t.paid == true or (type(t.cost) == "table" and currencyIsPaid(t.cost.currency))
	local disclosed = t.luckDisclosed == true
	local luck = if player ~= nil and disclosed then Rarity.getLuck(player, tableId) else 1
	return RollMath.oddsDetail(
		tableId,
		paid,
		weightsFor(t, luck),
		t.pity,
		t.mutationChance,
		ctx.config.balance.mutations,
		luck,
		disclosed
	)
end

-- v1.2 (N4): session luck registry. Setting luck re-sends that player's odds.
function Rarity.setLuck(player: Player, luck: number, tableId: string?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		error("[Core.Rarity] setLuck: player must be a Player", 2)
	end
	if tableId ~= nil and type(tableId) ~= "string" then
		error("[Core.Rarity] setLuck: tableId must be a string or nil", 2)
	end
	luckRegistry:set(player, luck, tableId)
	if ctx ~= nil and player.Parent == Players then
		sendPlayerOdds(player)
	end
end

function Rarity.getLuck(player: Player, tableId: string?): number
	return luckRegistry:get(player, tableId)
end

function Rarity.tiers(): { Types.RarityTierDef }
	return RarityTiers.all()
end

return Rarity
