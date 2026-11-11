--!strict
--[[
	Inventory server part (collection kit; module-api.md §5.1, §6, §8, §14). Inventory.new() -> a
	fresh part per runtime (the framework loader calls it, module-api.md §19.9).

	Save section 'inventory' = { inventory = { [uid]: ItemInstance } }, written only through ctx.tx.
	ItemInstance = { uid, itemId, mutation?, acquiredAt, source?, meta? }.

	api (frozen; ctx.deps[Inventory])
	  add(player, itemId, opts?) -> ItemInstance?   one ctx.tx (txApi.add)
	  remove(player, uid, reason?) -> ItemInstance?  one ctx.tx (txApi.remove)
	  get(player, uid) -> ItemInstance?      FROZEN read-only views in every environment (N8/H2):
	  list(player) -> { ItemInstance }       ctx.data.get's section view, cached by section version;
	  count(player) -> number                list() is one frozen array per version, not a copy per read
	  cap(player) -> number                  config.Inventory.inventory.cap + Σ extensions.capBonus
	  canTrade(player) -> boolean            in this server and loaded
	  transfer(from, to, uid, reason) -> (ok, why?)   InventoryRules.transferCheck reasons; the SAME
	                                         instance moves (sender's tx, then receiver's tx)
	  sendGift(from, toUserId, uid, reason?) -> (ok, why?)   InventoryRules.giftCheck reasons; ONE
	                                         tx removes the item and queues the "core_gift" message
	                                         in the sender's Mail outbox (Mail.txApi.send)
	  signals.ItemAdded(player, instance), signals.ItemRemoved(player, instance)   after commit
	txApi
	  add(tx, itemId, opts?) -> ItemInstance?   opts { mutation?, meta?, source?, reason? }; nil when
	                                         the item is unknown, the mutation unknown, meta too big,
	                                         or the inventory is at cap (checked on the tx copy)
	  remove(tx, uid, reason?) -> boolean    runs every onItemRemoved hook inside this tx
	  list(tx) -> { ItemInstance }           frozen views of the tx working copy
	  count(tx) -> number
	purchaseOps.addItem(tx, itemId, opts?) -> ItemInstance?
	extensions
	  onItemRemoved(fn(tx, player, instance))   inverted (§8): fires inside the REMOVING tx for every
	                                         removal (remove, transfer, sendGift); an error in a hook
	                                         discards that tx (nothing is removed)
	  capBonus(id, fn(player) -> number)     adds to cap(player) (Upgrades' "inventoryCap"); one per id

	Source tag: derived from the tx by ctx.compliance.tagPaid, never chosen by the caller:
	"paid:<product>" inside a purchase, "paidcur:<sourceId>" after a compliance.spendForRoll in the
	same tx, else the caller's opts.source (or nil). A caller-chosen source that starts with
	"paid:"/"paidcur:" outside such a tx is refused (add returns nil).
	Gift rules: no "paid:"/"paidcur:" copies by mail (restricted_source); transfer refuses paid
	copies when either player is paid-random restricted. "core_gift" is registered with
	ctx.depsExt[Mail].registerKind when Mail is enabled (claim: same instance, idempotent by uid,
	false = full -> stays in the mailbox).
	Starter items: on a player's first session (ctx.framework.sessions == 1) with an empty inventory.
	Client action `gift(toUserId, uid)` (own net.blink event Gift, 1/s burst 3): toUserId a positive integer, not self, receiver in THIS
	server; GIFT_COOLDOWN_SEC per sender on top of Net's rate limit; Mail on -> sendGift (crash-safe
	outbox), off -> transfer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ItemsRef = require(Modules:WaitForChild("Items"):WaitForChild("module"))
local MailRef = require(Modules:WaitForChild("Mail"):WaitForChild("module"))
local Gift = require(script.Gift)
local InventoryRules = require(script.InventoryRules)
local Util = require(script.Util)

local Inventory = {}

Inventory.GIFT_COOLDOWN_SEC = 2 -- anti-spam rail between successful gifts per sender

local function countOf(map: { [any]: any }?): number
	local n = 0
	local t: { [any]: any } = map or {}
	for _ in t do
		n += 1
	end
	return n
end

local function lazySignals(store: { [string]: any }): any
	-- Kept by identity by the framework's api wrapper (it has a metatable), so the signals created
	-- in init with ctx.signals.new are reachable through api.signals afterwards.
	return setmetatable({}, {
		__index = function(_, key: any): any
			return store[key]
		end,
		__newindex = function()
			error("Inventory.signals is read-only", 2)
		end,
	})
end

function Inventory.new(): any
	local ctx: any = nil
	local signals: { [string]: any } = {}
	local removedHooks: { (any, any, any) -> () } = {}
	local capBonuses: { { id: string, fn: (any) -> number } } = {}
	local loaded: { [any]: boolean } = {}
	local lastGiftAt: { [any]: number } = {}
	local listCache: { [any]: { version: number, list: { any }, count: number } } = setmetatable(
		{},
		{ __mode = "k" }
	) :: any
	local baseCap = 0

	local part: any = {}
	local api: any = {}
	local txApi: any = {}

	local function items(): any
		return ctx.deps[ItemsRef]
	end

	local function mailOn(): boolean
		return ctx.isEnabled(MailRef)
	end

	local function view(player: any): any
		if not ctx.data.isLoaded(player) then
			return nil
		end
		return ctx.data.get(player)
	end

	local function cached(player: any): any
		local v = view(player)
		if v == nil then
			return nil
		end
		local version = ctx.data.sectionVersion(player)
		local hit = listCache[player]
		if hit == nil or hit.version ~= version then
			local list = {}
			for _, instance in v.inventory do
				table.insert(list, instance) -- already frozen (ctx.data.get is a frozen view)
			end
			hit = { version = version, list = table.freeze(list), count = #list }
			listCache[player] = hit
		end
		return hit
	end

	local function fire(name: string, ...: any)
		local s = signals[name]
		if s then
			s:Fire(...)
		end
	end

	local function capOf(player: any): number
		local total = baseCap
		for _, bonus in capBonuses do
			local ok, value = pcall(bonus.fn, player)
			if ok and Util.isFiniteNumber(value) then
				total += value
			elseif not ok then
				ctx.log.warn(`capBonus '{bonus.id}' failed: {tostring(value)}`)
			end
		end
		return math.max(0, math.floor(total))
	end

	-- Inside an open tx. Returns the frozen new instance or nil (nothing written).
	local function addInTx(tx: any, itemId: any, opts: any?): any
		if type(itemId) ~= "string" or items().get(itemId) == nil then
			return nil
		end
		local o = if type(opts) == "table" then opts else {}
		if o.mutation ~= nil and (type(o.mutation) ~= "string" or items().mutation(o.mutation) == nil) then
			ctx.log.warn("unknown mutation " .. tostring(o.mutation))
			return nil
		end
		if o.source ~= nil and not Util.isShortString(o.source, InventoryRules.MAX_SOURCE_LENGTH) then
			return nil
		end
		local metaOk, metaErr = InventoryRules.validateMeta(o.meta)
		if not metaOk then
			ctx.log.warn("rejected meta: " .. tostring(metaErr))
			return nil
		end
		-- M5: the paid tag comes from the tx, never from the caller
		local derived = ctx.compliance.tagPaid(tx)
		local source: string?
		if InventoryRules.isPaidSource(derived) then
			source = derived
		elseif InventoryRules.isPaidSource(o.source) then
			ctx.log.warn(
				`refused add of '{itemId}' with source '{o.source}': paid tags are derived from the purchase / spendForRoll tx`
			)
			return nil
		else
			source = o.source
		end
		local s = ctx.section(tx)
		if countOf(s.inventory) >= capOf(tx.player) then
			return nil
		end
		local instance = {
			uid = Util.newUid(),
			itemId = itemId,
			mutation = o.mutation,
			acquiredAt = ctx.now(),
			source = source,
			meta = if o.meta then table.clone(o.meta) else nil,
		}
		s.inventory[instance.uid] = instance
		local frozen = Util.frozenCopy(table.clone(instance))
		local player = tx.player
		tx.after(function()
			fire("ItemAdded", player, frozen)
		end)
		return frozen
	end

	-- Inside an open tx: removes uid and runs every onItemRemoved hook in this tx.
	local function removeInTx(tx: any, uid: any): any
		if type(uid) ~= "string" then
			return nil
		end
		local s = ctx.section(tx)
		local instance = s.inventory[uid]
		if instance == nil then
			return nil
		end
		s.inventory[uid] = nil
		local frozen = Util.frozenCopy(table.clone(instance))
		local player = tx.player
		for _, hook in table.clone(removedHooks) do
			hook(tx, player, frozen)
		end
		tx.after(function()
			fire("ItemRemoved", player, frozen)
		end)
		return frozen
	end

	local function playerByUserId(userId: number): any
		for player in loaded do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end

	-- the "core_gift" claim, inside Mail's claim tx (registerKind)
	local function claimGift(tx: any, player: any, payload: any, _info: any): boolean
		local s = ctx.section(tx)
		local result, instance = Gift.receiveInto({ inventory = s.inventory }, payload, {
			itemExists = function(itemId: string): boolean
				return items().get(itemId) ~= nil
			end,
			cap = capOf(player),
			now = ctx.now(),
		})
		if result == "full" then
			return false
		end
		if result == "added" and instance then
			local frozen = Util.frozenCopy(table.clone(instance))
			local def = items().get(instance.itemId)
			local name = if def and type(def.name) == "string" then def.name else instance.itemId
			tx.after(function()
				fire("ItemAdded", player, frozen)
				ctx.net.feedback(player, "toast", "You received a gift: " .. name)
			end)
		end
		return true
	end

	------------------------------------------------------------------ api

	function api.add(player: any, itemId: string, opts: any?): any
		if not ctx.data.isLoaded(player) then
			return nil
		end
		local committed, instance = ctx.tx(player, function(tx: any): any
			return addInTx(tx, itemId, opts)
		end)
		return if committed then instance else nil
	end

	function api.remove(player: any, uid: string, _reason: string?): any
		if type(uid) ~= "string" or api.get(player, uid) == nil then
			return nil
		end
		local committed, removed = ctx.tx(player, function(tx: any): any
			return removeInTx(tx, uid)
		end)
		return if committed then removed else nil
	end

	function api.get(player: any, uid: string): any
		if type(uid) ~= "string" then
			return nil
		end
		local v = view(player)
		return if v then v.inventory[uid] else nil
	end

	function api.list(player: any): { any }
		local hit = cached(player)
		return if hit then hit.list else table.freeze({})
	end

	function api.count(player: any): number
		local hit = cached(player)
		return if hit then hit.count else 0
	end

	function api.cap(player: any): number
		return capOf(player)
	end

	function api.canTrade(player: any): boolean
		return loaded[player] == true and ctx.data.isLoaded(player)
	end

	local function transferCheck(from: any, to: any, uid: string): (boolean, string?)
		local instance = api.get(from, uid)
		return InventoryRules.transferCheck({
			fromLoaded = api.canTrade(from),
			toLoaded = api.canTrade(to),
			samePlayer = from == to,
			owned = instance ~= nil,
			source = if instance then instance.source else nil,
			fromRestricted = ctx.policy.paidRandomRestricted(from),
			toRestricted = ctx.policy.paidRandomRestricted(to),
			toCount = api.count(to),
			toCap = capOf(to),
		})
	end

	function api.transfer(from: any, to: any, uid: string, _reason: string?): (boolean, string?)
		if type(uid) ~= "string" then
			return false, "not_owned"
		end
		local ok, why = transferCheck(from, to, uid)
		if not ok then
			return false, why
		end
		-- sender's tx (hooks run inside it), then the receiver's: never two open at once (§5.1)
		local committed, removed = ctx.tx(from, function(tx: any): any
			return removeInTx(tx, uid)
		end)
		if not committed or removed == nil then
			return false, "not_owned"
		end
		local plain = table.clone(removed)
		if plain.meta then
			plain.meta = table.clone(plain.meta)
		end
		local added = ctx.tx(to, function(tx: any)
			local s = ctx.section(tx)
			s.inventory[plain.uid] = plain
			tx.after(function()
				fire("ItemAdded", to, removed)
			end)
		end)
		if not added then
			-- receiver left between the check and the write: give the copy back to the sender
			ctx.tx(from, function(tx: any)
				ctx.section(tx).inventory[plain.uid] = table.clone(plain)
				tx.after(function()
					fire("ItemAdded", from, removed)
				end)
			end)
			return false, "failed"
		end
		return true, nil
	end

	local function giftCheck(from: any, toUserId: any, uid: any): (boolean, string?)
		local isLoaded = api.canTrade(from)
		local instance = if isLoaded and type(uid) == "string" then api.get(from, uid) else nil
		return InventoryRules.giftCheck({
			mailEnabled = mailOn(),
			fromLoaded = isLoaded,
			fromUserId = from.UserId,
			toUserId = toUserId,
			owned = instance ~= nil,
			source = if instance then instance.source else nil,
		})
	end

	function api.sendGift(from: any, toUserId: number, uid: string, reason: string?): (boolean, string?)
		local ok, why = giftCheck(from, toUserId, uid)
		if not ok then
			return false, why
		end
		local giftReason = if type(reason) == "string" and #reason <= 32 then reason else nil
		local success, committed, removed = pcall(ctx.tx, from, function(tx: any): any
			local s = ctx.section(tx)
			local key = Gift.KEY_PREFIX .. Util.newUid() -- once, inside the tx
			local shim = { player = tx.player, data = { inventory = s.inventory } }
			local taken = Gift.takeInto(
				shim,
				toUserId,
				uid,
				key,
				giftReason,
				function(_t: any, to: number, kind: string, payload: any, k: string): boolean
					return ctx.depsTx[MailRef].send(tx, to, kind, payload, k)
				end
			)
			if taken == nil then
				return nil
			end
			local frozen = Util.frozenCopy(table.clone(taken))
			for _, hook in table.clone(removedHooks) do
				hook(tx, from, frozen)
			end
			tx.after(function()
				fire("ItemRemoved", from, frozen)
				pcall(ctx.analytics.custom, from, "GiftSent", 1)
			end)
			return frozen
		end)
		if not success then
			ctx.log.warn("sendGift failed: " .. tostring(committed))
			return false, "failed"
		end
		if not committed then
			return false, "not_loaded"
		end
		if removed == nil then
			return false, "not_owned"
		end
		return true, nil
	end

	api.signals = lazySignals(signals)

	------------------------------------------------------------------ txApi

	function txApi.add(tx: any, itemId: string, opts: any?): any
		return addInTx(tx, itemId, opts)
	end

	function txApi.remove(tx: any, uid: string, _reason: string?): boolean
		return removeInTx(tx, uid) ~= nil
	end

	function txApi.list(tx: any): { any }
		local list = {}
		for _, instance in ctx.section(tx).inventory do
			table.insert(list, Util.frozenCopy(table.clone(instance)))
		end
		return table.freeze(list)
	end

	function txApi.count(tx: any): number
		return countOf(ctx.section(tx).inventory)
	end

	------------------------------------------------------------------ parts

	part.api = api
	part.txApi = txApi
	part.purchaseOps = {
		-- M5: the "paid:<product>" tag is derived from the purchase tx
		addItem = function(tx: any, itemId: string, opts: any?): any
			return addInTx(tx, itemId, opts)
		end,
	}
	part.extensions = {
		onItemRemoved = function(fn: (any, any, any) -> ())
			assert(type(fn) == "function", "Inventory.onItemRemoved(fn): fn must be a function")
			table.insert(removedHooks, fn)
		end,
		capBonus = function(id: string, fn: (any) -> number)
			assert(type(id) == "string" and id ~= "", "Inventory.capBonus(id, fn): id must be a string")
			assert(type(fn) == "function", "Inventory.capBonus(id, fn): fn must be a function(player)")
			for _, b in capBonuses do
				assert(b.id ~= id, `Inventory.capBonus: '{id}' is already registered`)
			end
			table.insert(capBonuses, { id = id, fn = fn })
		end,
	}

	-- Client action `gift(toUserId, uid)` (own net.blink event Gift; v1.3.1 R19, was the framework
	-- event RequestGift). Same rate limit as before (1/s, burst 3).
	local function requestGift(player: any, toUserId: any, uid: any)
		if not InventoryRules.validGiftTarget(player.UserId, toUserId) or not Util.isId(uid) then
			return
		end
		local now = os.clock()
		local last = lastGiftAt[player]
		if last and now - last < Inventory.GIFT_COOLDOWN_SEC then
			return
		end
		if api.get(player, uid) == nil then
			return
		end
		local target = playerByUserId(toUserId)
		if target == nil or target == player then
			-- the client never mails an arbitrary user id (a typo would send the item into a
			-- profile nobody loads); cross-server gifts are server decisions (sendGift)
			return
		end
		local ok, why
		if mailOn() then
			ok, why = api.sendGift(player, toUserId, uid, "gift")
		else
			ok, why = api.transfer(player, target, uid, "gift")
		end
		if ok then
			lastGiftAt[player] = now
			ctx.net.feedback(player, "toast", "Gift sent")
		elseif why == "restricted" or why == "restricted_source" then
			ctx.net.feedback(player, "toast", "This item can't be gifted")
		elseif why == "inventory_full" then
			ctx.net.feedback(player, "toast", "Their inventory is full")
		end
	end
	part.actions = {
		gift = { limit = { rate = 1, burst = 3 }, handler = requestGift },
	}

	function part.init(context: any)
		ctx = context
		signals.ItemAdded = ctx.signals.new("ItemAdded")
		signals.ItemRemoved = ctx.signals.new("ItemRemoved")
		local inv = ctx.config.inventory
		if type(inv) ~= "table" or not Util.isNonNegativeNumber(inv.cap) then
			error("config.Inventory.inventory.cap must be a finite number >= 0", 0)
		end
		baseCap = inv.cap
		local starters = ctx.config.starterItems
		local known: { [string]: boolean } = {}
		for _, def in ctx.gameConfig.items do
			known[def.id] = true
		end
		for i, itemId in starters do
			if not known[itemId] then
				error(`config.Inventory.starterItems[{i}]: unknown item '{tostring(itemId)}'`, 0)
			end
		end

		ctx.lifecycle.onPlayerLoaded(function(player: any)
			loaded[player] = true
			if ctx.framework.sessions(player) ~= 1 or api.count(player) ~= 0 then
				return
			end
			for _, itemId in starters do
				if api.add(player, itemId, { source = "starter", reason = "starter" }) == nil then
					ctx.log.warn("could not grant starter item " .. tostring(itemId))
				end
			end
		end)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			loaded[player] = nil
			lastGiftAt[player] = nil
			listCache[player] = nil
		end)
	end

	function part.start(_context: any)
		if mailOn() then
			ctx.depsExt[MailRef].registerKind(Gift.KIND, claimGift)
		end
	end

	return part
end

return Inventory
