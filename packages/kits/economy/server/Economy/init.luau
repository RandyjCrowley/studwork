--!strict
--[[
	Core.Economy. OWNED BY AGENT B (core/b-economy). Public API: Types.EconomyAPI.

	Contract details:
	- Economy owns item income: it derives sources from PlayerData.displayed (income.source =
	  "displayed") or PlayerData.inventory ("owned") using Items.incomeOf. Other services do NOT
	  call addIncomeSource for items; addIncomeSource is for game-defined extra sources.
	- getMultiplier includes rebirth (Rebirth.multiplier), incomeMultiplier upgrades, boosts and
	  the co-play multiplier, stacked per balance.multiplierStacking ("multiply" default | "add").
	- Multipliers with persist == true or an expiresAt are saved in PlayerData.multipliers
	  (expired entries are ignored and pruned); others are session-only.
	- Economy replicates "ratePerSec" and "multiplier" via ctx.setReplicated when they change.
	- grant/spend reject non-finite or non-positive amounts, unknown currencies and unloaded
	  players; spend checks and deducts inside one Data.update (never goes negative).

	Performance: the rate is cached per player and recomputed only when invalidated (item /
	rebirth / upgrade / load signals, source or multiplier changes, the earliest boost expiry).
	One loop per tick walks loaded players: O(players) per tick, one Data.update each. Recompute
	is O(items + upgrades + boosts) and only runs on invalidation. See README.md.
]]

local Players = game:GetService("Players")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local RateMath = require(script.RateMath)
local Tx = require(game:GetService("ServerScriptService"):WaitForChild("CoreServer"):WaitForChild("Tx"))

-- Engineering constants (not balance).
local ANALYTICS_FLUSH_SECONDS = 60 -- income ticks are summed and logged once per this window
local MAX_TICK_CATCHUP = 2 -- pay at most this many ticks worth when the scheduler stalls

type State = {
	dirty: boolean,
	rate: number,
	mult: number,
	nextExpiry: number?, -- earliest unix time an active boost expires
	sources: { [string]: number },
	session: { [string]: Types.MultiplierEntry },
	sentRate: number?,
	sentMult: number?,
	incomeAccum: { [string]: number }, -- currency -> unflushed income for analytics
	lastFlush: number,
}

local Economy = {}

local ctx: any = nil
local states: { [Player]: State } = {}

local function primary(): string
	return ctx.config.balance.primaryCurrency
end

local function getState(player: Player): State
	local s = states[player]
	if s == nil then
		local created: State = {
			dirty = true,
			rate = 0,
			mult = 1,
			nextExpiry = nil,
			sources = {},
			session = {},
			sentRate = nil,
			sentMult = nil,
			incomeAccum = {},
			lastFlush = os.clock(),
		}
		-- never keep state for players that already left (avoids leaking on late calls)
		if player.Parent ~= nil then
			states[player] = created
		end
		return created
	end
	return s
end

local function invalidate(player: Player)
	local s = states[player]
	if s then
		s.dirty = true
	end
end

local function logEconomy(
	player: Player,
	flow: "Source" | "Sink",
	currency: string,
	amount: number,
	reason: string
)
	local analytics = ctx.services.Analytics
	if analytics == nil or amount <= 0 then
		return
	end
	local kind, sku = RateMath.splitReason(reason)
	pcall(analytics.economy, player, flow, currency, amount, kind, sku)
end

-- Recomputes multiplier + rate from PlayerData (never from Plot/Instance state), so it is correct
-- the moment data is loaded regardless of other services' onLoaded ordering.
local function recompute(player: Player, s: State)
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	local balance = ctx.config.balance
	local now = os.time()
	local factors: { number } = {}

	if ctx.isEnabled("Rebirth") then
		local rebirthMult = ctx.services.Rebirth.multiplier(player)
		if RateMath.isFinite(rebirthMult) and rebirthMult > 0 then
			table.insert(factors, rebirthMult)
		end
	end
	local base = 0
	if data then
		local upgrades = if ctx.isEnabled("Upgrades") then balance.upgrades else nil
		for id, upgrade in upgrades or {} do
			if upgrade.effect == "incomeMultiplier" then
				local level = data.upgrades[id] or 0
				if level > 0 then
					table.insert(factors, RateMath.upgradeFactor(level, upgrade.perLevel))
				end
			end
		end
		if ctx.isEnabled("Items") then
			base = RateMath.sumItems(
				data.displayed,
				data.inventory,
				(balance.income :: Types.IncomeConfig).source,
				ctx.services.Items.incomeOf
			)
		end
	end

	local e1 = RateMath.activeBoosts(factors, if data then data.multipliers else nil, now)
	local e2 = RateMath.activeBoosts(factors, s.session, now)
	if e1 and e2 then
		s.nextExpiry = math.min(e1, e2)
	else
		s.nextExpiry = e1 or e2
	end

	for _, perSec in s.sources do
		base += perSec
	end

	s.mult = RateMath.combine(factors, balance.multiplierStacking)
	s.rate = base * s.mult
	s.dirty = false

	if s.sentRate ~= s.rate then
		s.sentRate = s.rate
		ctx.setReplicated(player, "ratePerSec", s.rate)
	end
	if s.sentMult ~= s.mult then
		s.sentMult = s.mult
		ctx.setReplicated(player, "multiplier", s.mult)
	end
end

local function fresh(player: Player): State
	local s = getState(player)
	if s.dirty or (s.nextExpiry ~= nil and os.time() >= (s.nextExpiry :: number)) then
		recompute(player, s)
	end
	return s
end

local function flushAnalytics(player: Player, s: State)
	s.lastFlush = os.clock()
	for currency, amount in s.incomeAccum do
		logEconomy(player, "Source", currency, amount, "income")
	end
	table.clear(s.incomeAccum)
end

local function tick(dt: number)
	local now = os.time()
	local currency = primary()
	for player, s in states do
		if not ctx.services.Data.isLoaded(player) then
			continue
		end
		local expired = s.nextExpiry ~= nil and now >= (s.nextExpiry :: number)
		if s.dirty or expired then
			recompute(player, s)
		end
		local amount = s.rate * dt
		local pay = RateMath.isPositiveAmount(amount)
		if pay or expired then
			local newBalance = 0
			-- one write per player per tick: income + pruning of expired saved boosts
			local ok = ctx.services.Data.update(player, function(data: Types.PlayerData)
				if expired then
					RateMath.pruneExpired(data.multipliers, now)
				end
				if pay then
					local _, nb = RateMath.applyGrant(data.currency, currency, amount)
					newBalance = nb
					data.stats.totalEarned = (data.stats.totalEarned or 0) + amount
				end
			end)
			if ok and pay then
				s.incomeAccum[currency] = (s.incomeAccum[currency] or 0) + amount
				ctx.signals.CurrencyChanged:Fire(player, currency, newBalance, amount, "income")
			end
		end
		if os.clock() - s.lastFlush >= ANALYTICS_FLUSH_SECONDS then
			flushAnalytics(player, s)
		end
	end
end

local function onLoaded(player: Player)
	local s = getState(player)
	ctx.services.Data.update(player, function(data: Types.PlayerData)
		RateMath.pruneExpired(data.multipliers, os.time()) -- drop boosts that expired while away
	end)
	recompute(player, s)
end

-- Console helper: the last arg may be a user id of a player in the server.
local function findPlayer(args: { any }, minArgs: number): (Player?, { any })
	local list = Players:GetPlayers()
	local uid = tonumber(args[#args])
	if #args > minArgs and uid then
		for _, p in list do
			if p.UserId == uid then
				table.remove(args)
				return p, args
			end
		end
	end
	return list[1], args
end

function Economy.init(context: any)
	ctx = context
end

function Economy.start()
	local signals = ctx.signals
	ctx.services.Data.onLoaded(onLoaded)
	for _, name in
		{ "ItemAdded", "ItemRemoved", "ItemDisplayed", "ItemUndisplayed", "Rebirthed", "UpgradePurchased" }
	do
		signals[name]:Connect(invalidate)
	end
	signals.DataLoaded:Connect(invalidate)

	Players.PlayerRemoving:Connect(function(player: Player)
		local s = states[player]
		if s then
			flushAnalytics(player, s)
		end
		states[player] = nil
	end)

	task.spawn(function()
		local last = os.clock()
		while true do
			local step = ctx.config.balance.income.tickSeconds
			task.wait(step)
			local nowClock = os.clock()
			local dt = math.min(nowClock - last, step * MAX_TICK_CATCHUP)
			last = nowClock
			debug.profilebegin("Core.Economy.tick")
			tick(dt)
			debug.profileend()
		end
	end)

	if ctx.isStudio then
		ctx.console.register("grant", "grant <amount> [currency] [userId]: give currency", function(...)
			local player, args = findPlayer({ ... }, 1)
			if player == nil then
				return "no player"
			end
			local amount = tonumber(args[1])
			if amount == nil then
				return "usage: grant <amount> [currency] [userId]"
			end
			local currency = args[2]
			local ok = Economy.grant(player, amount, "console", currency)
			return string.format(
				"%s %s -> %s (%s = %s)",
				if ok then "granted" else "REFUSED",
				tostring(amount),
				player.Name,
				currency or primary(),
				tostring(Economy.balance(player, currency))
			)
		end)
		ctx.console.register("rate", "rate [userId]: print income rate and multiplier", function(...)
			local player = findPlayer({ ... }, 0)
			if player == nil then
				return "no player"
			end
			local s = fresh(player)
			local names = {}
			for id in s.session do
				table.insert(names, id)
			end
			local data: Types.PlayerData? = ctx.services.Data.get(player)
			if data then
				for id in data.multipliers do
					table.insert(names, id .. "(saved)")
				end
			end
			return string.format(
				"%s: rate %.3f/s, multiplier x%.3f, boosts [%s]",
				player.Name,
				s.rate,
				s.mult,
				table.concat(names, ", ")
			)
		end)
	end
end

local function resolveCurrency(currency: any, data: Types.PlayerData): string?
	local id = if currency == nil then primary() else currency
	if not RateMath.isKnownCurrency(id, primary(), ctx.config.balance.startingCurrency, data.currency) then
		return nil
	end
	return id
end

function Economy.balance(player: Player, currency: string?): number
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if data == nil then
		return 0
	end
	local id = if currency == nil then primary() else currency
	return data.currency[id] or 0
end

-- ctx-only (Context.EconomyInternal): grant inside an open transaction; signals/analytics run
-- after the transaction commits (tx.after).
function Economy.grantInto(tx: Tx.Tx, amount: number, reason: string, currency: string?): boolean
	if not RateMath.isPositiveAmount(amount) or type(reason) ~= "string" then
		return false
	end
	local d: Types.PlayerData = tx.data
	local id = resolveCurrency(currency, d)
	if id == nil then
		return false
	end
	local cid: string = id
	local applied, newBalance = RateMath.applyGrant(d.currency, cid, amount)
	if not applied then
		return false
	end
	if cid == primary() then
		d.stats.totalEarned = (d.stats.totalEarned or 0) + amount
	end
	local player = tx.player
	tx.after(function()
		ctx.signals.CurrencyChanged:Fire(player, cid, newBalance, amount, reason)
		if reason == "income" then
			local s = states[player]
			if s then
				s.incomeAccum[cid] = (s.incomeAccum[cid] or 0) + amount
			end
		else
			logEconomy(player, "Source", cid, amount, reason)
		end
	end)
	return true
end

function Economy.grant(player: Player, amount: number, reason: string, currency: string?): boolean
	if not RateMath.isPositiveAmount(amount) or type(reason) ~= "string" then
		return false
	end
	local committed, granted = Tx.run(ctx.services.Data, player, function(tx)
		return Economy.grantInto(tx, amount, reason, currency)
	end)
	return committed and granted == true
end

function Economy.spend(player: Player, amount: number, reason: string, currency: string?): boolean
	if not RateMath.isPositiveAmount(amount) or type(reason) ~= "string" then
		return false
	end
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if data == nil then
		return false
	end
	local id = resolveCurrency(currency, data)
	if id == nil then
		return false
	end
	local cid: string = id
	local applied, newBalance = false, 0
	local ok = ctx.services.Data.update(player, function(d: Types.PlayerData)
		applied, newBalance = RateMath.applySpend(d.currency, cid, amount)
	end)
	if not (ok and applied) then
		return false
	end
	ctx.signals.CurrencyChanged:Fire(player, cid, newBalance, -amount, reason)
	logEconomy(player, "Sink", cid, amount, reason)
	return true
end

function Economy.addIncomeSource(player: Player, sourceId: string, perSec: number)
	if type(sourceId) ~= "string" or not RateMath.isFinite(perSec) or perSec < 0 then
		return
	end
	local s = getState(player)
	if s.sources[sourceId] ~= perSec then
		s.sources[sourceId] = perSec
		s.dirty = true
	end
end

function Economy.removeIncomeSource(player: Player, sourceId: string)
	local s = states[player]
	if s and s.sources[sourceId] ~= nil then
		s.sources[sourceId] = nil
		s.dirty = true
	end
end

function Economy.addMultiplier(
	player: Player,
	id: string,
	mult: number,
	expiresAt: number?,
	persist: boolean?
)
	if type(id) ~= "string" or not RateMath.isPositiveAmount(mult) then
		return
	end
	if expiresAt ~= nil and not RateMath.isFinite(expiresAt) then
		return
	end
	local s = getState(player)
	local entry: Types.MultiplierEntry = { mult = mult, expiresAt = expiresAt }
	if persist == true or expiresAt ~= nil then
		s.session[id] = nil
		local ok = ctx.services.Data.update(player, function(data: Types.PlayerData)
			data.multipliers[id] = entry
		end)
		if not ok then
			s.session[id] = entry -- data not loaded: keep it for this session only
		end
	else
		s.session[id] = entry
		local data: Types.PlayerData? = ctx.services.Data.get(player)
		if data and data.multipliers[id] ~= nil then
			ctx.services.Data.update(player, function(d: Types.PlayerData)
				d.multipliers[id] = nil -- same id is now session-only
			end)
		end
	end
	s.dirty = true
end

function Economy.removeMultiplier(player: Player, id: string)
	local s = states[player]
	if s then
		s.session[id] = nil
		s.dirty = true
	end
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if data and data.multipliers[id] ~= nil then
		ctx.services.Data.update(player, function(d: Types.PlayerData)
			d.multipliers[id] = nil
		end)
	end
end

function Economy.getMultiplier(player: Player): number
	return fresh(player).mult
end

function Economy.getRate(player: Player): number
	return fresh(player).rate
end

return Economy
