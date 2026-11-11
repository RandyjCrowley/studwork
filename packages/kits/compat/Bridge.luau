--!strict
--[[
	COMPAT BRIDGE. DELETED IN PHASE 2 with the rest of packages/kits/compat (core-v1.3.0 step
	4b-IIa). Until the Phase 1 kit agents rewrite the eleven kit modules, the UNCHANGED v1.2
	service internals (packages/kits/<kit>/server/<Service>/) run behind their defineModule
	wrappers through this one file. Nothing here is a public API: kits' ModuleServers call
	serverPart(), the multi-server sim reads compatServices().

	How a wrapper's server part works (packages/kits/<kit>/server/ModuleServers.luau):
	  loadServer(ref) -> Bridge.serverPart(name, loadService)
	    api           the v1.2 public functions (Modules.API list; init/start and *Into internals
	                  stay hidden) + `signals` (the v1.2 signals this module fires)
	    purchaseOps   Economy.grant(tx, amount, currency?), Inventory.addItem(tx, itemId, opts?),
	                  Rarity.roll(tx, tableId, luck?) -> (def?, info): v1.2 grantInto / addInto /
	                  rollInto on a v1.2 Tx built over the purchase tx (§7)
	    init(ctx)     the first one builds the v1.2-shaped ctx (below), then service.init(v12ctx)
	    start(ctx)    service.start()
	  The framework runs init/start in its topo order, which is the v1.2 BOOT_ORDER when a game
	  lists the kits in v1.2 order (they have no other ordering constraint).

	The v1.2-shaped ctx (packages/core/server/Context.luau's ServerContext), built from framework
	pieces of THIS server's runtime (CompatDoor):
	  config          V12Config.view (the v1.2 GameConfig view; validated by the v1.2
	                  ConfigValidate at boot, every error reported together)
	  services        Data = V12Data (flat view over the sections, framework transactions),
	                  Policy = framework policy, Analytics = framework analytics, the eleven v1.2
	                  service tables, a disabled module as the v1.2 erroring proxy
	  signals         the v1.2 signal set (DataLoaded, DataChanged, CurrencyChanged, ...);
	                  ProductGranted / EventStarted / EventEnded are forwarded from the framework
	  net             handle(event, fn) -> framework Net (rate limits, drop-before-load, pcall);
	                  feedback; events (framework Blink)
	  setReplicated / setReplicatedAll / sentReplicated
	                  routed to the OWNING module's ctx.replicate (ratePerSec/multiplier ->
	                  Economy, plotName -> Plot, odds -> Rarity (+ compliance.disclose), mailbox
	                  -> Mail); paidRandomRestricted / activeEvents are framework state already
	  console         register(name, help, fn) -> the one framework console (unprefixed v1.2 names)
	  isStudio, serverConfig, modules (v1.2 names), isEnabled(name)

	Compliance (module-api.md §14): every Rarity table is a Compliance random source whose
	`sample` is the v1.2 weighted pick with pity (Rarity.rollInto). Every roll goes through
	compliance.roll: free rolls (Rarity.roll, console `roll`), purchases (tx.use(Rarity).roll),
	and the coin-priced RequestRoll, which uses compliance.spendForRoll (spend + roll in ONE tx).
	Economy registers the spender of every GameConfig.compliance.paidCurrencies currency.
	Mail's v1.2 cross-server store becomes framework Data messages (owner "Mail").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CompatDoor = (require :: any)(ServerScriptService:WaitForChild("Framework"):WaitForChild("CompatDoor"))
local Tx = require(script.Parent.Tx)
local V12Config = require(script.Parent.shared.V12Config)
local V12Data = require(script.Parent.V12Data)

local Bridge = {}

-- v1.2 Modules.API (packages/core/shared/Modules.luau): the public functions per module.
Bridge.API = table.freeze({
	Items = { "get", "all", "byTag", "incomeOf" },
	Inventory = { "add", "remove", "get", "list", "count", "cap", "transfer", "canTrade", "sendGift" },
	Rarity = { "roll", "getOdds", "getOddsDetail", "tiers", "setLuck", "getLuck" },
	Economy = {
		"grant",
		"spend",
		"balance",
		"addIncomeSource",
		"removeIncomeSource",
		"addMultiplier",
		"removeMultiplier",
		"getMultiplier",
		"getRate",
	},
	Upgrades = { "level", "cost", "purchase" },
	Rebirth = { "canRebirth", "rebirth", "cost", "multiplier" },
	Offline = { "onReturn" },
	Streak = { "onDaily", "get" },
	Friends = { "onCoPlay", "friendsInServer" },
	Mail = { "send", "onReceive", "pending", "claim" },
	Plot = { "get", "owner", "display", "clearDisplay", "slots", "onAssigned" },
} :: { [string]: { string } })

-- The v1.2 signals each module fires (its api.signals).
Bridge.SIGNALS = table.freeze({
	Economy = { "CurrencyChanged" },
	Inventory = { "ItemAdded", "ItemRemoved" },
	Plot = { "ItemDisplayed", "ItemUndisplayed", "PlotAssigned", "PlotReleased" },
	Rebirth = { "Rebirthed" },
	Upgrades = { "UpgradePurchased" },
	Streak = { "StreakAdvanced" },
	Friends = { "CoPlay" },
})

-- v1.2 ReplicatedState extra keys -> the module whose ctx.replicate carries them.
Bridge.REPLICATED_OWNER = table.freeze({
	ratePerSec = "Economy",
	multiplier = "Economy",
	plotName = "Plot",
	odds = "Rarity",
	mailbox = "Mail",
})
local FRAMEWORK_STATE = { paidRandomRestricted = true, activeEvents = true }
local FOUNDATION = { Data = true, Policy = true, Analytics = true, Events = true, Shop = true, Net = true }

local NO_LATE_ITEMS_ERROR =
	"items must be declared in GameConfig.items; registering items after start is not supported in core-v1.3.0"

type State = {
	rt: any,
	services: { [string]: any },
	ctxs: { [string]: any },
	enabled: { [string]: boolean },
	signals: any,
	v12: any,
	config: any,
	data: any,
	current: string?,
	pendingRoll: any,
	spendReason: string?,
	warned: { [string]: boolean },
}

local states: { [any]: State } = setmetatable({}, { __mode = "k" }) :: any

local function kitChild(kit: string, ...: string): any
	local node: any = ServerScriptService:WaitForChild("Kits"):WaitForChild(kit)
	for _, name in { ... } do
		node = node:WaitForChild(name)
	end
	return (require :: any)(node)
end

local function stateFor(rt: any): State
	local st = states[rt]
	if st == nil then
		local compat = if type(rt.compat) == "table" then rt.compat else {}
		local signals = if type(compat.signals) == "function"
			then compat.signals()
			else (require :: any)(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Signals")).new()
		local created: State = {
			rt = rt,
			services = {},
			ctxs = {},
			enabled = {},
			signals = signals,
			v12 = nil,
			config = nil,
			data = nil,
			current = nil,
			pendingRoll = nil,
			spendReason = nil,
			warned = {},
		}
		st = created
		states[rt] = created
	end
	return st :: State
end

local function warnOnce(st: State, key: string, msg: string)
	if not st.warned[key] then
		st.warned[key] = true
		st.rt.logSink("warn", msg)
	end
end

local function disabledProxy(name: string): any
	local message = "[Core] " .. name .. " is not enabled in GameConfig.modules"
	return table.freeze(setmetatable({}, {
		__index = function()
			error(message, 2)
		end,
		__newindex = function()
			error(message, 2)
		end,
		__tostring = function()
			return "DisabledModule(" .. name .. ")"
		end,
	}) :: any)
end

-- A v1.2 Tx ({ player, data, after }) over an open framework tx.
local function tx12(st: State, tx: any): any
	return { player = tx.player, data = st.data.txView(tx), after = tx.after }
end

-- Shop's product tag for a purchase tx: the devProducts name, else the product id.
local function productTag(tx: any): string
	local ok, name = pcall(function(): any
		return tx.productName
	end)
	if ok and type(name) == "string" then
		return name
	end
	local okR, receipt = pcall(function(): any
		return tx.receipt
	end)
	return if okR and type(receipt) == "table" then tostring(receipt.ProductId) else "unknown"
end

--------------------------------------------------------------------------------
-- Rolls through Compliance
--------------------------------------------------------------------------------

local function rarityTable(st: State, tableId: any): any
	local tables = st.config and st.config.balance.rarityTables
	local t = if type(tables) == "table" and type(tableId) == "string" then tables[tableId] else nil
	return if type(t) == "table" then t else nil
end

local function rollFail(reason: string): (any, any)
	return nil, { ok = false, reason = reason, pity = false }
end

-- One roll of `tableId` inside the open tx, through ctx.compliance.roll (Rarity's ctx).
local function rollInTx(st: State, tx: any, tableId: string, luck: number?, opts: any?): (any, any)
	local Rarity = st.services.Rarity
	local t = rarityTable(st, tableId)
	if t == nil then
		return rollFail("unknown_table")
	end
	local o = if type(opts) == "table" then opts else {}
	local compliance = st.ctxs.Rarity.compliance
	local pricedInPaid = type(t.cost) == "table"
		and compliance.isPaidCurrency(t.cost.currency)
		and o.free ~= true
	local paid = o.paid == true or t.paid == true or pricedInPaid
	local RollMath = kitChild("Collection", "Rarity", "RollMath")
	local effective =
		RollMath.sanitizeLuck(if luck == nil then Rarity._rollLuck(tx.player, tableId, t, paid) else luck)
	local pending = { opts = o, result = nil :: any }
	st.pendingRoll = pending
	local packed = table.pack(pcall(compliance.roll, tx, tableId, effective))
	st.pendingRoll = nil
	if not packed[1] then
		error(packed[2], 0)
	end
	local result = pending.result
	if result ~= nil then
		return result.def, result.info
	end
	return rollFail(if type(packed[4]) == "string" then packed[4] else "no_outcome")
end

-- Rarity.roll (the public API, the console `roll`): one framework tx per roll.
local function bridgedRoll(st: State, tableId: any, player: any, luck: number?, opts: any?): (any, any)
	if rarityTable(st, tableId) == nil then
		return rollFail("unknown_table")
	end
	if not st.rt.data.isLoaded(player) then
		return rollFail("not_loaded")
	end
	local def, info = nil, nil
	local committed = st.rt.data.runTx(player, function(tx: any)
		def, info = rollInTx(st, tx, tableId, luck, opts)
	end)
	if not committed or info == nil then
		return rollFail("not_loaded")
	end
	return def, info
end

local function registerRaritySources(st: State, ctx: any)
	local Rarity = st.services.Rarity
	for tableId, t in st.config.balance.rarityTables or {} do
		ctx.compliance.registerRandomSource(tableId, {
			odds = function(player: any): any
				return Rarity.getOddsDetail(tableId, player)
			end,
			-- The actual randomness: v1.2 rollInto (weighted pick + pity + mutation, and the grant
			-- when the caller asked for one), writing into this tx's working copies.
			sample = function(_player: any, luck: number, tx: any): any
				local pending = st.pendingRoll
				local o = if pending then pending.opts else {}
				local def, info = Rarity.rollInto(tx12(st, tx), tableId, luck, o)
				if pending then
					pending.result = { def = def, info = info }
				end
				if def ~= nil and info ~= nil and info.ok then
					return { itemId = def.id, def = def, info = info }
				end
				return nil
			end,
			luckDisclosed = t.luckDisclosed == true,
		})
	end
end

-- RequestRoll (coin-priced tables), v1.2 Rarity's handler with the spend + roll in ONE tx.
local function requestRoll(st: State): (any, any) -> ()
	return function(player: any, tableId: any)
		local rt = st.rt
		local Validate = (require :: any)(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Validate"))
		if not Validate.isId(tableId) then
			return
		end
		local t = rarityTable(st, tableId)
		if t == nil or t.paid == true or type(t.cost) ~= "table" then
			return
		end
		local cost = t.cost
		if not Validate.isNonNegativeNumber(cost.amount) or type(cost.currency) ~= "string" then
			return
		end
		local compliance = st.ctxs.Rarity.compliance
		local paid = compliance.isPaidCurrency(cost.currency)
		if paid and rt.policy.paidRandomRestricted(player) then
			rt.net.feedback(player, "toast", "Not available in your region")
			return
		end
		if not st.enabled.Economy or not st.enabled.Inventory then
			return
		end
		local Inventory = st.services.Inventory
		if not rt.data.isLoaded(player) or Inventory.count(player) >= Inventory.cap(player) then
			return -- checked before spending, so a full inventory never costs currency
		end
		local RollMath = kitChild("Collection", "Rarity", "RollMath")
		local luck = RollMath.sanitizeLuck(st.services.Rarity._rollLuck(player, tableId, t, paid))
		if paid and luck ~= 1 then
			-- hard rule 11 checked before spending (v1.2 toast instead of the rule's error)
			local shown = compliance.disclosed(player, tableId)
			if t.luckDisclosed ~= true or type(shown) ~= "table" or shown.luck ~= luck then
				rt.net.feedback(player, "toast", "Odds are updating, try again in a moment")
				return
			end
		end
		if paid then
			local ok, err = pcall(function()
				rt.data.runTx(player, function(tx: any)
					st.spendReason = "roll:" .. tableId
					st.pendingRoll = { opts = { grant = true, reason = "roll", paid = true }, result = nil }
					compliance.spendForRoll(tx, cost.currency, cost.amount, tableId, luck)
				end)
			end)
			st.spendReason = nil
			st.pendingRoll = nil
			if not ok then
				rt.logSink(
					"warn",
					`[Compat.Rarity] RequestRoll {tableId} discarded (nothing spent): {tostring(err)}`
				)
			end
			return
		end
		-- a free (not Robux-buyable) currency: v1.2 spend, roll, refund on failure
		local Economy = st.services.Economy
		local reason = "roll:" .. tableId
		if not Economy.spend(player, cost.amount, reason, cost.currency) then
			return
		end
		local _, info = bridgedRoll(st, tableId, player, nil, { grant = true, reason = "roll", paid = false })
		if not info.ok then
			Economy.grant(player, cost.amount, "refund:" .. tableId, cost.currency)
		end
	end
end

--------------------------------------------------------------------------------
-- Economy: paid-currency spenders + starting currency
--------------------------------------------------------------------------------

local function registerSpenders(st: State, ctx: any)
	local RateMath = kitChild("Economy", "Economy", "RateMath")
	for _, currency in ctx.compliance.paidCurrencies() do
		ctx.compliance.registerCurrencySpender(currency, function(tx: any, amount: number): boolean
			local flat = st.data.txView(tx)
			local applied, newBalance = RateMath.applySpend(flat.currency, currency, amount)
			if not applied then
				return false
			end
			local reason = st.spendReason or "spend"
			local player = tx.player
			tx.after(function()
				st.signals.CurrencyChanged:Fire(player, currency, newBalance, -amount, reason)
				local kind, sku = RateMath.splitReason(reason)
				pcall(st.rt.analytics.api.economy, player, "Sink", currency, amount, kind, sku)
			end)
			return true
		end)
	end
end

-- v1.2 Schema.default/prepare: the primary currency exists; a first join gets startingCurrency,
-- an existing player gets 0 for a currency added later.
local function seedCurrency(st: State, ctx: any)
	ctx.data.onLoaded(function(player: any)
		local rt = st.rt
		local balance = st.config.balance
		local stats = rt.data.frameworkField(player, "stats")
		local first = type(stats) == "table" and stats.sessions == 1
		rt.data.runTx(player, function(tx: any)
			local s = ctx.section(tx)
			if type(s) ~= "table" then
				return
			end
			if type(s.currency) ~= "table" then
				s.currency = {}
			end
			if s.currency[balance.primaryCurrency] == nil then
				s.currency[balance.primaryCurrency] = 0
			end
			for id, amount in balance.startingCurrency or {} do
				if s.currency[id] == nil or (first and s.currency[id] == 0 and amount ~= 0) then
					s.currency[id] = if first then amount else 0
				end
			end
		end)
	end)
end

--------------------------------------------------------------------------------
-- Mail: the v1.2 cross-server store over framework Data messages
--------------------------------------------------------------------------------

local function wireMail(st: State)
	local rt = st.rt
	local Internal = require(script.Parent.MailInternal) :: any
	Internal.isMock = false
	Internal.store = {
		MessageAsync = function(_self: any, key: string, message: any): boolean
			local userId = tonumber(string.match(key, "^Player_(%d+)$"))
			if userId == nil then
				return false
			end
			return rt.data.sendMessage("Mail", userId, message)
		end,
	}
	Internal.nudgeSave = function(userId: number)
		rt.data.nudge(userId)
	end
	rt.data.onMessage("Mail", function(player: any, payload: any, processed: () -> ())
		local deliver = Internal.deliver
		if deliver ~= nil then
			deliver(player, payload, processed)
		end
	end)
end

--------------------------------------------------------------------------------
-- The v1.2-shaped ctx
--------------------------------------------------------------------------------

local function registerConsole(st: State, name: string, help: string, fn: (...any) -> any)
	local rt = st.rt
	if rt.console[name] ~= nil then
		warnOnce(
			st,
			"console:" .. name,
			`[Compat] console command '{name}' already registered; v1.2 copy skipped`
		)
		return
	end
	rt.console[name] = {
		owner = st.current or "Compat",
		fn = function(_player: any, ...: any): any
			return fn(...)
		end,
		help = help,
	}
end

local function targetPlayer(rt: any, userId: any): any
	local id = tonumber(userId)
	if id then
		return rt.platform.players.byUserId(id)
	end
	return rt.platform.players.list()[1]
end

-- v1.2 foundation console commands (Data, Policy, Shop, Events) on the framework services.
local function registerFoundationConsole(st: State)
	local rt = st.rt
	registerConsole(
		st,
		"receipt",
		"receipt <productName> [purchaseId] [userId]: simulate ProcessReceipt twice (Studio)",
		function(name: any, purchaseId: any, userId: any): string
			return rt.shop.consoleReceipt(name, purchaseId, userId)
		end
	)
	registerConsole(
		st,
		"restrict",
		"restrict <true|false|clear> [userId]: override the paid-random policy (Studio)",
		function(value: any, userId: any): string
			if not rt.isStudio then
				return "Studio-only"
			end
			local player = targetPlayer(rt, userId)
			if player == nil then
				return "no player"
			end
			if value == "true" then
				rt.policy.override(player, true)
			elseif value == "false" then
				rt.policy.override(player, false)
			elseif value == "clear" then
				rt.policy.override(player, nil)
			else
				return "usage: restrict <true|false|clear> [userId]"
			end
			return `{player.Name} paidRandomRestricted = {tostring(rt.policy.paidRandomRestricted(player))}`
		end
	)
	registerConsole(
		st,
		"event",
		"event [id]: trigger an event now (no id = list events)",
		function(id: any): string
			if id == nil then
				return rt.events.consoleList()
			end
			if rt.gameConfigPublic.events[id] == nil then
				return "unknown event " .. tostring(id)
			end
			if rt.events.trigger(id, rt.platform.players.list()[1]) then
				return `started {id}`
			end
			return tostring(id) .. " is already active"
		end
	)
	if not rt.isStudio then
		return
	end
	registerConsole(
		st,
		"data",
		"data <dump|reset> [userId]: print or wipe a player's data (dump: the sectioned save)",
		function(sub: any, userId: any): string
			local player = targetPlayer(rt, userId)
			if player == nil or not rt.data.isLoaded(player) then
				return "no loaded player"
			end
			if sub == "reset" then
				rt.data.runTx(player, function(tx: any)
					for _, ref in rt.order do
						if ref.data then
							local s = rt.data.section(tx, ref.data.key)
							if type(s) == "table" then
								table.clear(s)
								for k, v in ref.data.default do
									s[k] = if type(v) == "table" then table.clone(v) else v
								end
							end
						end
					end
				end)
				st.data.fireLoaded(player) -- "re-read everything", as v1.2
				return `reset data of {player.Name}`
			end
			return "usage: data <dump|reset> [userId]"
		end
	)
	registerConsole(
		st,
		"lastseen",
		"lastseen <secondsAgo> [userId]: set lastSeen back",
		function(ago: any, userId: any): string
			local seconds = tonumber(ago)
			local player = targetPlayer(rt, userId)
			if seconds == nil or seconds ~= seconds then
				return "usage: lastseen <secondsAgo> [userId]"
			end
			if player == nil or not rt.data.isLoaded(player) then
				return "no loaded player"
			end
			rt.data.compatSetLastSeen(player, rt.now() - seconds)
			return `lastSeen of {player.Name} = now - {seconds}s (kept through saves; rejoin to trigger Offline)`
		end
	)
end

local function buildV12(st: State, firstCtx: any)
	local rt = st.rt
	local gameConfig = rt.gameConfig
	local gm = rt.gameModule
	local view = V12Config.view(gameConfig, rt.configs, gm)
	local errors = V12Config.validateView(view)
	if #errors > 0 then
		error(
			"invalid GameConfig for the v1.2 kit services (compat bridge):\n  - "
				.. table.concat(errors, "\n  - "),
			0
		)
	end
	st.config = view
	st.data = V12Data.new({
		rt = rt,
		gameId = gameConfig.gameId,
		gameKey = if gm and gm.data then gm.data.key else nil,
		spawn = rt.platform.spawn,
		log = function(msg: string)
			rt.logSink("warn", msg)
		end,
		signals = st.signals,
	})

	local services: { [string]: any } = {
		Data = st.data,
		Policy = rt.policy.api,
		Analytics = rt.analytics.api,
	}
	for name in Bridge.API do
		services[name] = st.services[name] or disabledProxy(name)
	end

	local function route(key: string): any
		local owner = Bridge.REPLICATED_OWNER[key]
		local c = if owner then st.ctxs[owner] else nil
		if c == nil and not FRAMEWORK_STATE[key] then
			warnOnce(st, "repl:" .. key, `[Compat] replicated key '{key}' has no owning module; dropped`)
		end
		return c
	end

	st.v12 = {
		config = view,
		services = table.freeze(services),
		signals = st.signals,
		net = table.freeze({
			handle = function(eventName: string, handler: (...any) -> ())
				local fn = handler
				if eventName == "RequestRoll" then
					fn = requestRoll(st) -- spend + roll in one tx (compliance.spendForRoll)
				end
				rt.net.claim(st.current or "Compat", eventName, fn)
			end,
			feedback = function(player: any, kind: string, text: string, rarity: string?, position: any?)
				rt.net.feedback(player, kind, text, rarity, position)
			end,
			events = rt.platform.events,
			handleGame = function()
				error(
					"[Compat] Core.Net.handle is gone in core-v1.3.0: use ctx.net.handleEvent in a module",
					2
				)
			end,
		}),
		setReplicated = function(player: any, key: string, value: any)
			local c = route(key)
			if c then
				c.replicate.set(player, key, value)
				if key == "odds" then
					rt.compliance.disclose(player)
				end
			end
		end,
		setReplicatedAll = function(key: string, value: any)
			local c = route(key)
			if c then
				c.replicate.setAll(key, value)
				if key == "odds" then
					for _, p in rt.platform.players.list() do
						rt.compliance.disclose(p)
					end
				end
			end
		end,
		sentReplicated = function(player: any, key: string): any
			local c = route(key)
			return if c then c.replicate.sent(player, key) else nil
		end,
		console = table.freeze({
			register = function(name: string, help: string, fn: (...any) -> any)
				registerConsole(st, name, help, fn)
			end,
		}),
		isStudio = rt.isStudio,
		serverConfig = if type(rt.serverConfig) == "table" then rt.serverConfig else {},
		modules = view.modules,
		isEnabled = function(name: string): boolean
			return st.enabled[name] == true or FOUNDATION[name] == true
		end,
	}

	-- v1.2 signals fed by the framework
	rt.data.onChange(function(player: any)
		st.signals.DataChanged:Fire(player)
	end)
	for _, name in { "ProductGranted", "EventStarted", "EventEnded" } do
		rt.frameworkSignals[name]:Connect(function(...: any)
			st.signals[name]:Fire(...)
		end)
	end
	-- v1.2 Data.onLoaded / DataLoaded after the framework loaded (and migrated) the save
	firstCtx.lifecycle.onPlayerLoaded(function(player: any)
		st.data.fireLoaded(player)
	end)
	registerFoundationConsole(st)
end

local function initModule(st: State, name: string, ctx: any)
	st.ctxs[name] = ctx
	if st.v12 == nil then
		buildV12(st, ctx)
	end
	local service = st.services[name]
	if name == "Rarity" then
		-- every roll of the v1.2 service (its console, any internal caller) goes through Compliance
		service.roll = function(tableId: any, player: any, luck: number?, opts: any?): (any, any)
			return bridgedRoll(st, tableId, player, luck, opts)
		end
	elseif name == "Mail" then
		wireMail(st)
	end
	st.current = name
	service.init(st.v12)
	st.current = nil
	if name == "Rarity" then
		registerRaritySources(st, ctx)
	elseif name == "Economy" then
		registerSpenders(st, ctx)
		seedCurrency(st, ctx)
	end
end

local function startModule(st: State, name: string)
	st.current = name
	st.services[name].start()
	st.current = nil
end

local function buildApi(st: State, name: string, service: any): any
	local api: { [string]: any } = {}
	for _, fnName in Bridge.API[name] do
		assert(type(service[fnName]) == "function", `[Compat] {name}.{fnName} is not implemented`)
		if name == "Rarity" and fnName == "roll" then
			api.roll = function(tableId: any, player: any, luck: number?, opts: any?): (any, any)
				return bridgedRoll(st, tableId, player, luck, opts)
			end
		else
			api[fnName] = function(...: any): ...any
				return service[fnName](...)
			end
		end
	end
	if name == "Items" then
		api.register = function()
			error(NO_LATE_ITEMS_ERROR, 2)
		end
	end
	local own = Bridge.SIGNALS[name]
	if own then
		local signals = {}
		for _, s in own do
			signals[s] = st.signals[s]
		end
		api.signals = signals
	end
	return api
end

local function purchaseOps(st: State, name: string, service: any): any
	if name == "Economy" then
		return {
			grant = function(tx: any, amount: number, currency: string?): boolean
				return service.grantInto(tx12(st, tx), amount, "product:" .. productTag(tx), currency)
			end,
		}
	elseif name == "Inventory" then
		return {
			-- M5: the paid tag is derived from the tx ("paid:<product>"), never chosen by the caller
			addItem = function(tx: any, itemId: string, opts: any?): any
				local o: { [string]: any } = if type(opts) == "table" then table.clone(opts) else {}
				o.source = st.ctxs.Inventory.compliance.tagPaid(tx)
				return service.addInto(tx12(st, tx), itemId, o)
			end,
		}
	elseif name == "Rarity" then
		return {
			roll = function(tx: any, tableId: string, luck: number?): (any, any)
				return rollInTx(
					st,
					tx,
					tableId,
					luck,
					{ paid = true, grant = true, reason = "product:" .. productTag(tx) }
				)
			end,
		}
	end
	return nil
end

-- A wrapper's server part (ModuleServers.loadServer). Called while the framework resolves
-- modules, so the runtime is already attached to CompatDoor.
function Bridge.serverPart(name: string, loadService: () -> any): any
	assert(Bridge.API[name] ~= nil, "[Compat] no v1.2 service named " .. tostring(name))
	local st = stateFor(CompatDoor.runtime())
	local service = loadService()
	st.services[name] = service
	st.enabled[name] = true
	local part: { [string]: any } = {
		api = buildApi(st, name, service),
		init = function(ctx: any)
			initModule(st, name, ctx)
		end,
		start = function(_ctx: any)
			startModule(st, name)
		end,
	}
	local ops = purchaseOps(st, name, service)
	if ops then
		part.purchaseOps = ops
	end
	return part
end

-- v1.2 Shop.onProduct(product, handler(data, receipt, tx)) over the framework Shop, for code
-- still written against the v1.2 PurchaseTx (the multi-server sim's scenarios).
local function v12Shop(st: State): any
	local rt = st.rt
	local owner = if rt.gameModule then rt.gameModule.name else "Compat"
	local shop = rt.shop.forModule(owner)
	local function purchaseTx(ptx: any): any
		local t = tx12(st, ptx)
		return {
			player = ptx.player,
			receipt = ptx.receipt,
			productName = (pcall(function()
				return ptx.productName
			end)) and ptx.productName or nil,
			policyKnown = ptx.policyKnown,
			paidRandomRestricted = ptx.paidRandomRestricted,
			grant = function(amount: number, currency: string?): boolean
				return st.services.Economy.grantInto(t, amount, "product:" .. productTag(ptx), currency)
			end,
			addItem = function(itemId: string, opts: any?): any
				local o: { [string]: any } = if type(opts) == "table" then table.clone(opts) else {}
				o.source = "paid:" .. productTag(ptx)
				return st.services.Inventory.addInto(t, itemId, o)
			end,
			roll = function(tableId: string, luck: number?): (any, any)
				return rollInTx(
					st,
					ptx,
					tableId,
					luck,
					{ paid = true, grant = true, reason = "product:" .. productTag(ptx) }
				)
			end,
			retryLater = ptx.retryLater,
			after = ptx.after,
		}
	end
	return table.freeze({
		onProduct = function(product: any, handler: (any, any, any) -> ())
			shop.onProduct(product, function(ptx: any)
				handler(st.data.txView(ptx), ptx.receipt, purchaseTx(ptx))
			end)
		end,
		ownsPass = shop.ownsPass,
		onPassOwned = shop.onPassOwned,
	})
end

-- The v1.2 services of a runtime as ctx.services saw them (+ Shop, the v1.2 Shop over the
-- framework). Test-only (packages/framework/test/sim).
function Bridge.compatServices(rt: any): any
	local st = states[rt]
	assert(st ~= nil and st.v12 ~= nil, "[Compat] no v1.2 services booted on this runtime")
	local out = table.clone(st.v12.services)
	out.Shop = v12Shop(st)
	return out, st.signals
end

-- Tx is re-exported for kit code that still builds v1.2 transactions by hand.
Bridge.Tx = Tx

return Bridge
