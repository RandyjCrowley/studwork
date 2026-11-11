--!strict
--[[
	Economy (economy kit), server part. core-v1.3.0 Phase 1: a real StudWork module (module-api.md
	§3-§8): its own save section (`economy` = { currency, multipliers }), its own config
	(config.Economy), ctx only. Built per runtime by Economy.new() (ModuleServers.loadServer).

	api (PHASE1-CONTRACT "Economy"; v1.2 names and meanings)
	  grant(player, amount, reason, currency?) -> boolean
	  spend(player, amount, reason, currency?) -> boolean   ERRORS for a currency listed in
	      GameConfig.compliance.paidCurrencies (§14 C3: "spend a paid currency only through
	      compliance.spendForRoll")
	  balance(player, currency?) -> number
	  addIncomeSource(player, id, perSec) / removeIncomeSource(player, id)
	  addMultiplier(player, id, mult, expiresAt?, persist?) / removeMultiplier(player, id)
	  getMultiplier(player) -> number, getRate(player) -> number
	  primaryCurrency() -> string, startingBalance(currency) -> number      (additions)
	  signals.CurrencyChanged(player, currency, newBalance, delta, reason)
	txApi
	  grant(tx, amount, reason, currency?) -> boolean
	  spend(tx, amount, reason, currency?) -> boolean       same paid-currency refusal (a
	      non-random good priced in a paid currency goes through ctx.compliance.spendPaid, which
	      any module can call; Phase 2 final review 5/7)
	  balance(tx, currency?) -> number                      (addition: the tx working copy)
	purchaseOps.grant(tx, amount, currency?) -> boolean     reason "product:<product>"
	extensions
	  rateFactor(id, fn(player) -> number | {number}) -> invalidate(player)
	      A multiplier factor read when the rate is recomputed (Rebirth: its multiplier;
	      Upgrades: one factor per incomeMultiplier upgrade). Call `invalidate(player)` after the
	      inputs change so the cached rate is recomputed.
	  displayedSource(fn(player) -> { [slotId]: uid }) -> invalidate(player)
	      The displayed set used by income.source = "displayed" (Plot registers it; Plot
	      declares optional = { Economy }, §8). One provider.
	Compliance: registers the currency spender of every compliance.paidCurrencies currency, so
	compliance.spendForRoll can spend it (in the roll's tx).

	Income (v1.2 rules, RateMath): rate = (Σ item income + Σ addIncomeSource) × combine(factors,
	multiplierStacking), where
	  item income = item.economy.incomePerSec × mutation.economy.incomeMultiplier (1 without a
	      mutation or without Items), over Inventory.list (income.source = "owned") or over the
	      displayed set's Inventory.get (source = "displayed"); an item without an `economy`
	      table earns nothing (a collection-only item is valid, §12)
	  factors = every rateFactor, the active saved boosts (economy.multipliers) and the session
	      boosts.
	Item defs come from ctx.gameConfig.items (the same frozen catalog Items.get serves); the
	mutation multiplier from Items.mutation(id) (optional Items). Paid once per income.tickSeconds
	on the shared ticker (ctx.lifecycle.onTick), one section write per loaded player per tick.

	Replicated: data.currency, data.multipliers; extra.ratePerSec, extra.multiplier.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RateMath = require(script.RateMath)

local Collection = ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Collection")
local ItemsRef = require(Collection:WaitForChild("Items")) :: any
local InventoryRef = require(Collection:WaitForChild("Inventory")) :: any

local ANALYTICS_FLUSH_SECONDS = 60 -- income is summed and logged once per this much ticked time

export type MultiplierEntry = { mult: number, expiresAt: number? }

type State = {
	dirty: boolean,
	rate: number,
	mult: number,
	nextExpiry: number?,
	sources: { [string]: number },
	session: { [string]: MultiplierEntry },
	sentRate: number?,
	sentMult: number?,
	incomeAccum: { [string]: number },
	sinceFlush: number,
}

local Economy = {}

Economy.PAID_SPEND_ERROR = "spend a paid currency only through compliance.spendForRoll"

local isFinite = RateMath.isFinite

-- "paid:<product>" (compliance.tagPaid inside a purchase) -> v1.2's "product:<product>" reason
local function productReason(tag: string): string
	return "product:" .. (string.match(tag, "^paid:(.+)$") or tag)
end

-- A fresh server part (one per runtime).
function Economy.new(): any
	local ctx: any = nil
	local states: { [any]: State } = {}
	local factors: { { id: string, fn: (any) -> any } } = {}
	local displayedProvider: ((any) -> any)? = nil
	local created: { [string]: any } = {}

	-- api.signals is copied by the framework before init: a proxy (kept by identity) that serves
	-- the signals init creates with ctx.signals.new.
	local signals = setmetatable({}, {
		__index = function(_, key: any): any
			return created[key]
		end,
	})

	local function primary(): string
		return ctx.config.primaryCurrency
	end

	local function isPaid(currency: any): boolean
		return type(currency) == "string" and ctx.compliance.isPaidCurrency(currency)
	end

	local function getState(player: any): State
		local s = states[player]
		if s == nil then
			local entry: State = {
				dirty = true,
				rate = 0,
				mult = 1,
				nextExpiry = nil,
				sources = {},
				session = {},
				sentRate = nil,
				sentMult = nil,
				incomeAccum = {},
				sinceFlush = 0,
			}
			if ctx.data.isLoaded(player) then
				states[player] = entry -- never keep state for a player who isn't (or is no longer) here
			end
			return entry
		end
		return s
	end

	local function invalidate(player: any)
		local s = states[player]
		if s then
			s.dirty = true
		end
	end

	local function view(player: any): any
		if not ctx.data.isLoaded(player) then
			return nil
		end
		return ctx.data.get(player)
	end

	local function logEconomy(
		player: any,
		flow: "Source" | "Sink",
		currency: string,
		amount: number,
		ending: number,
		reason: string
	)
		if amount <= 0 then
			return
		end
		local kind, sku = RateMath.splitReason(reason)
		pcall(ctx.analytics.economy, player, flow, currency, amount, ending, kind, sku)
	end

	local function itemDef(itemId: any): any
		if type(itemId) ~= "string" then
			return nil
		end
		return ctx.gameConfig.items.byId(itemId)
	end

	local function incomeOf(instance: any): number
		if type(instance) ~= "table" then
			return 0
		end
		local def = itemDef(instance.itemId)
		local economy = if def then def.economy else nil
		local perSec = if type(economy) == "table" then economy.incomePerSec else nil
		if not isFinite(perSec) then
			return 0 -- no economy table: the item earns nothing (cards, cosmetics, quest items)
		end
		local mult = 1
		if instance.mutation ~= nil and ctx.isEnabled(ItemsRef) then
			local m = ctx.deps[ItemsRef].mutation(instance.mutation)
			local me = if type(m) == "table" then m.economy else nil
			if type(me) == "table" and isFinite(me.incomeMultiplier) then
				mult = me.incomeMultiplier
			end
		end
		return perSec * mult
	end

	local function itemIncome(player: any): number
		if not ctx.isEnabled(InventoryRef) then
			return 0
		end
		local inventory = ctx.deps[InventoryRef]
		local total = 0
		local function add(instance: any)
			local v = incomeOf(instance)
			if isFinite(v) and v > 0 then
				total += v
			end
		end
		if ctx.config.income.source == "owned" then
			for _, instance in inventory.list(player) do
				add(instance)
			end
		elseif displayedProvider ~= nil then
			local ok, displayed = pcall(displayedProvider :: any, player)
			if ok and type(displayed) == "table" then
				for _, uid in displayed do
					add(inventory.get(player, uid))
				end
			end
		end
		return total
	end

	-- Recomputes multiplier + rate from save data and registered factors (never from world
	-- state), so it is right the moment data is loaded, whatever order onLoaded handlers run in.
	local function recompute(player: any, s: State)
		local data = view(player)
		local now = ctx.now()
		local list: { number } = {}
		for _, f in factors do
			local ok, value = pcall(f.fn, player)
			if ok then
				if type(value) == "table" then
					for _, v in value do
						if isFinite(v) and v > 0 then
							table.insert(list, v)
						end
					end
				elseif isFinite(value) and value > 0 then
					table.insert(list, value)
				end
			end
		end
		local base = if data then itemIncome(player) else 0
		local e1 = RateMath.activeBoosts(list, if data then data.multipliers else nil, now)
		local e2 = RateMath.activeBoosts(list, s.session, now)
		if e1 and e2 then
			s.nextExpiry = math.min(e1, e2)
		else
			s.nextExpiry = e1 or e2
		end
		for _, perSec in s.sources do
			base += perSec
		end
		s.mult = RateMath.combine(list, ctx.config.multiplierStacking)
		s.rate = base * s.mult
		s.dirty = false
		if data then
			if s.sentRate ~= s.rate then
				s.sentRate = s.rate
				ctx.replicate.set(player, "ratePerSec", s.rate)
			end
			if s.sentMult ~= s.mult then
				s.sentMult = s.mult
				ctx.replicate.set(player, "multiplier", s.mult)
			end
		end
	end

	local function fresh(player: any): State
		local s = getState(player)
		if s.dirty or (s.nextExpiry ~= nil and ctx.now() >= (s.nextExpiry :: number)) then
			recompute(player, s)
		end
		return s
	end

	local function flushAnalytics(player: any, s: State)
		s.sinceFlush = 0
		local data = view(player)
		for currency, amount in s.incomeAccum do
			local ending = if data then data.currency[currency] or 0 else 0
			logEconomy(player, "Source", currency, amount, ending, "income")
		end
		table.clear(s.incomeAccum)
	end

	-- A known currency: the primary, a startingCurrency key, or one the player already holds.
	local function resolveCurrency(currency: any, balances: any): string?
		local id = if currency == nil then primary() else currency
		if not RateMath.isKnownCurrency(id, primary(), ctx.config.startingCurrency, balances) then
			return nil
		end
		return id
	end

	local function sectionOf(tx: any): any
		local s = ctx.section(tx)
		if type(s.currency) ~= "table" then
			s.currency = {}
		end
		if type(s.multipliers) ~= "table" then
			s.multipliers = {}
		end
		return s
	end

	------------------------------------------------------------------------------------------
	-- txApi
	------------------------------------------------------------------------------------------

	local function txGrant(tx: any, amount: number, reason: string, currency: string?): boolean
		if not RateMath.isPositiveAmount(amount) or type(reason) ~= "string" then
			return false
		end
		local s = sectionOf(tx)
		local id = resolveCurrency(currency, s.currency)
		if id == nil then
			return false
		end
		local cid: string = id
		local applied, newBalance = RateMath.applyGrant(s.currency, cid, amount)
		if not applied then
			return false
		end
		local player = tx.player
		tx.after(function()
			created.CurrencyChanged:Fire(player, cid, newBalance, amount, reason)
			if reason == "income" then
				local st = states[player]
				if st then
					st.incomeAccum[cid] = (st.incomeAccum[cid] or 0) + amount
				end
			else
				logEconomy(player, "Source", cid, amount, newBalance, reason)
			end
		end)
		return true
	end

	-- The spend itself, any currency. Reached for a paid currency only through Compliance's
	-- registered spender (spendForRoll / spendPaid); txSpend below refuses paid currencies.
	local function applySpend(tx: any, amount: number, reason: string, currency: string?): boolean
		if not RateMath.isPositiveAmount(amount) or type(reason) ~= "string" then
			return false
		end
		local s = sectionOf(tx)
		local id = resolveCurrency(currency, s.currency)
		if id == nil then
			return false
		end
		local cid: string = id
		local applied, newBalance = RateMath.applySpend(s.currency, cid, amount)
		if not applied then
			return false
		end
		local player = tx.player
		tx.after(function()
			created.CurrencyChanged:Fire(player, cid, newBalance, -amount, reason)
			logEconomy(player, "Sink", cid, amount, newBalance, reason)
		end)
		return true
	end

	local function txSpend(tx: any, amount: number, reason: string, currency: string?): boolean
		if isPaid(if currency == nil then primary() else currency) then
			error(Economy.PAID_SPEND_ERROR, 3)
		end
		return applySpend(tx, amount, reason, currency)
	end

	local function txBalance(tx: any, currency: string?): number
		local s = ctx.section(tx)
		local id = if currency == nil then primary() else currency
		local balances = if type(s.currency) == "table" then s.currency else {}
		return balances[id] or 0
	end

	------------------------------------------------------------------------------------------
	-- api
	------------------------------------------------------------------------------------------

	local api: { [string]: any } = { signals = signals }

	function api.balance(player: any, currency: string?): number
		local data = view(player)
		if data == nil then
			return 0
		end
		local id = if currency == nil then primary() else currency
		return data.currency[id] or 0
	end

	-- (additions) config.Economy facts other modules need without reading Economy's config
	function api.primaryCurrency(): string
		return primary()
	end

	function api.startingBalance(currency: string): number
		local starting = ctx.config.startingCurrency
		local v = if type(starting) == "table" then starting[currency] else nil
		return if isFinite(v) then v else 0
	end

	function api.grant(player: any, amount: number, reason: string, currency: string?): boolean
		if not RateMath.isPositiveAmount(amount) or type(reason) ~= "string" then
			return false
		end
		local committed, granted = ctx.tx(player, function(tx: any)
			return txGrant(tx, amount, reason, currency)
		end)
		return committed and granted == true
	end

	function api.spend(player: any, amount: number, reason: string, currency: string?): boolean
		if isPaid(if currency == nil then primary() else currency) then
			error(Economy.PAID_SPEND_ERROR, 2)
		end
		if not RateMath.isPositiveAmount(amount) or type(reason) ~= "string" then
			return false
		end
		local committed, spent = ctx.tx(player, function(tx: any)
			return txSpend(tx, amount, reason, currency)
		end)
		return committed and spent == true
	end

	function api.addIncomeSource(player: any, sourceId: string, perSec: number)
		if type(sourceId) ~= "string" or not isFinite(perSec) or perSec < 0 then
			return
		end
		local s = getState(player)
		if s.sources[sourceId] ~= perSec then
			s.sources[sourceId] = perSec
			s.dirty = true
		end
	end

	function api.removeIncomeSource(player: any, sourceId: string)
		local s = states[player]
		if s and s.sources[sourceId] ~= nil then
			s.sources[sourceId] = nil
			s.dirty = true
		end
	end

	function api.addMultiplier(player: any, id: string, mult: number, expiresAt: number?, persist: boolean?)
		if type(id) ~= "string" or not RateMath.isPositiveAmount(mult) then
			return
		end
		if expiresAt ~= nil and not isFinite(expiresAt) then
			return
		end
		local s = getState(player)
		local entry: MultiplierEntry = { mult = mult, expiresAt = expiresAt }
		if persist == true or expiresAt ~= nil then
			s.session[id] = nil
			local ok = ctx.data.update(player, function(section: any)
				if type(section.multipliers) ~= "table" then
					section.multipliers = {}
				end
				section.multipliers[id] = table.clone(entry)
			end)
			if not ok then
				s.session[id] = entry -- data not loaded: keep it for this session only
			end
		else
			s.session[id] = entry
			local data = view(player)
			if data and data.multipliers[id] ~= nil then
				ctx.data.update(player, function(section: any)
					section.multipliers[id] = nil -- the same id is now session-only
				end)
			end
		end
		s.dirty = true
	end

	function api.removeMultiplier(player: any, id: string)
		local s = states[player]
		if s then
			s.session[id] = nil
			s.dirty = true
		end
		local data = view(player)
		if data and data.multipliers[id] ~= nil then
			ctx.data.update(player, function(section: any)
				section.multipliers[id] = nil
			end)
		end
	end

	function api.getMultiplier(player: any): number
		return fresh(player).mult
	end

	function api.getRate(player: any): number
		return fresh(player).rate
	end

	------------------------------------------------------------------------------------------
	-- extensions
	------------------------------------------------------------------------------------------

	local extensions = {}

	function extensions.rateFactor(id: string, fn: (player: any) -> any): (player: any) -> ()
		assert(type(id) == "string" and id ~= "", "Economy.rateFactor(id, fn): id must be a string")
		assert(type(fn) == "function", "Economy.rateFactor(id, fn): fn must be a function(player)")
		for _, f in factors do
			assert(f.id ~= id, "Economy.rateFactor: '" .. id .. "' is already registered")
		end
		table.insert(factors, { id = id, fn = fn })
		for player in states do
			invalidate(player)
		end
		return invalidate
	end

	function extensions.displayedSource(fn: (player: any) -> any): (player: any) -> ()
		assert(type(fn) == "function", "Economy.displayedSource(fn): fn must be a function(player)")
		assert(displayedProvider == nil, "Economy.displayedSource: a provider is already registered")
		displayedProvider = fn
		for player in states do
			invalidate(player)
		end
		return invalidate
	end

	------------------------------------------------------------------------------------------
	-- lifecycle
	------------------------------------------------------------------------------------------

	local function tick(dt: number)
		local now = ctx.now()
		local currency = primary()
		for player, s in states do
			if not ctx.data.isLoaded(player) then
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
				local paid = false
				-- one write per player per tick: income + pruning of expired saved boosts
				local ok = ctx.data.update(player, function(section: any)
					if expired and type(section.multipliers) == "table" then
						RateMath.pruneExpired(section.multipliers, now)
					end
					if pay then
						if type(section.currency) ~= "table" then
							section.currency = {}
						end
						paid, newBalance = RateMath.applyGrant(section.currency, currency, amount)
					end
				end)
				if ok and paid then
					s.incomeAccum[currency] = (s.incomeAccum[currency] or 0) + amount
					created.CurrencyChanged:Fire(player, currency, newBalance, amount, "income")
				end
			end
			s.sinceFlush += dt
			if s.sinceFlush >= ANALYTICS_FLUSH_SECONDS then
				flushAnalytics(player, s)
			end
		end
	end

	-- v1.2 Schema.default/prepare: the primary currency exists; a first join gets
	-- startingCurrency, an existing player gets 0 for a currency added later. Boosts that expired
	-- while away are dropped.
	local function onLoaded(player: any)
		local first = ctx.framework.sessions(player) == 1
		local starting = ctx.config.startingCurrency or {}
		ctx.data.update(player, function(section: any)
			if type(section.currency) ~= "table" then
				section.currency = {}
			end
			if type(section.multipliers) ~= "table" then
				section.multipliers = {}
			end
			local balances = section.currency
			if balances[primary()] == nil then
				balances[primary()] = 0
			end
			for id, amount in starting do
				if balances[id] == nil or (first and balances[id] == 0 and amount ~= 0) then
					balances[id] = if first then amount else 0
				end
			end
			RateMath.pruneExpired(section.multipliers, ctx.now())
		end)
		recompute(player, getState(player))
	end

	local function registerConsole()
		local Players = game:GetService("Players")
		local function target(args: { any }, minArgs: number): (any, { any })
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
		ctx.console.register("grant", function(_caller: any, ...: any): string
			local player, args = target({ ... }, 1)
			if player == nil then
				return "no player"
			end
			local amount = tonumber(args[1])
			if amount == nil then
				return "usage: economy grant <amount> [currency] [userId]"
			end
			local currency = args[2]
			local ok = api.grant(player, amount, "console", currency)
			return string.format(
				"%s %s -> %s (%s = %s)",
				if ok then "granted" else "REFUSED",
				tostring(amount),
				player.Name,
				currency or primary(),
				tostring(api.balance(player, currency))
			)
		end, "economy grant <amount> [currency] [userId]: give currency")
		ctx.console.register("rate", function(_caller: any, ...: any): string
			local player = target({ ... }, 0)
			if player == nil then
				return "no player"
			end
			local s = fresh(player)
			local names = {}
			for id in s.session do
				table.insert(names, id)
			end
			local data = view(player)
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
		end, "economy rate [userId]: print income rate and multiplier")
	end

	local part: { [string]: any } = {}

	function part.init(context: any)
		ctx = context
		created.CurrencyChanged = ctx.signals.new("CurrencyChanged")
		-- §14 C3: compliance.spendForRoll / spendPaid spend a paid currency through Economy, in the
		-- caller's tx
		for _, currency in ctx.compliance.paidCurrencies() do
			ctx.compliance.registerCurrencySpender(
				currency,
				function(tx: any, amount: number, reason: string?): boolean
					return applySpend(tx, amount, reason or "roll", currency)
				end
			)
		end
		ctx.data.onLoaded(onLoaded)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			local s = states[player]
			if s then
				flushAnalytics(player, s)
			end
			states[player] = nil
		end)
		ctx.lifecycle.onTick(ctx.config.income.tickSeconds, tick)
		if ctx.isStudio then
			registerConsole()
		end
	end

	function part.start(_context: any)
		if ctx.isEnabled(InventoryRef) then
			local inv = ctx.deps[InventoryRef].signals
			for _, name in { "ItemAdded", "ItemRemoved" } do
				local signal = if inv then inv[name] else nil
				if signal ~= nil then
					signal:Connect(function(player: any)
						invalidate(player)
					end)
				end
			end
		end
	end

	part.api = api
	part.txApi = {
		grant = txGrant,
		spend = txSpend,
		balance = txBalance,
	}
	part.purchaseOps = {
		grant = function(tx: any, amount: number, currency: string?): boolean
			return txGrant(tx, amount, productReason(ctx.compliance.tagPaid(tx)), currency)
		end,
	}
	part.extensions = extensions
	return part
end

return Economy
