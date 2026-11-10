--!strict
--[[
	Framework Shop (module-api.md §7, §7.1), ported from v1.2 core/server/Shop. Framework internal;
	modules see ctx.shop = { onProduct, onPassOwned, ownsPass }.

	Developer products (receipt flow: Receipt.luau, unchanged from v1.2):
	  ctx.shop.onProduct(product, handler(tx))   product = a name in GameConfig.products.devProducts
	      (or a numeric id). One handler per product, owned by the registering module. Ids of 0
	      mean "not created on Roblox yet": kept by name (console `shop receipt <name>`), warned once.
	  The handler gets a PurchaseTx: the sealed data tx (ctx.section(tx) works for the handler's
	  own module) plus read-only fields
	      tx.player, tx.paid (= true), tx.paidRandomRestricted, tx.policyKnown, tx.productName,
	      tx.receipt (frozen copy), tx.after(fn), tx.retryLater(reason?), tx.use(ref)
	  tx.use(ref) -> that module's purchaseOps bound to this tx (ref must be enabled and be the
	  handler's own module or one it declares in dependsOn/optional). Random grants go through the
	  owning module's ops, which must use ctx.compliance.roll (paid: the purchase is the payment).
	  The handler and _framework.purchases[PurchaseId] = now run in ONE non-yielding transaction:
	  handler error -> nothing written, NotProcessedYet "handler_error"; yield -> "handler_yielded";
	  tx.retryLater(reason) -> "retry_later" (raises; survives a pcall in the handler). The receipt
	  is PurchaseGranted only after Data.saveAsync confirms the save; a failed save keeps the
	  in-memory record so the retry is a "duplicate" (handler not run twice). One PurchaseId is never
	  processed concurrently. tx.after effects, the framework signal ProductGranted, a toast and
	  analytics ProductPurchased run exactly once, when the grant is saved.
	  N9: tx.after effects of a grant whose save wasn't confirmed before the player left are DROPPED
	  (best effort, documented): the grant itself is persisted by the session-end save and the
	  next server only sees a duplicate. Only the purchase analytics is logged for it.

	ProcessReceipt (§7.1, revised in step 4b): Shop assigns MarketplaceService.ProcessReceipt once,
	at the very end of boot (after every module's init AND start), so no module code that runs
	during boot can win against it; tools/lint bans assigning it anywhere else. The design's
	runtime replacement check can't be built: ProcessReceipt is a write-only callback (reading it
	errors "you can only set the callback value, get is not available", and it fires no Changed
	signal; verified in Studio). Shop does NOT re-assign periodically, because a blind re-assert
	would be exactly the silent fight the design rejects. See decisions.md (step 4b).

	Gamepasses: ownsPass(player, pass) cached per player per pass (UserOwnsGamePassAsync once, with
	retries; failures not cached); PromptGamePassPurchaseFinished(true) marks it owned;
	onPassOwned(pass, fn) runs once per player per pass (owned at join, after data load, or bought).

	Shop.new(opts): opts.data, opts.policy, opts.products, opts.marketplace (platform), opts.players
	({ byUserId, list }), opts.isPlayer, opts.feedback, opts.analytics, opts.signals, opts.purchaseOps
	(ref -> ops), opts.canUse(callerName, ref) -> boolean, opts.isEnabled(ref), opts.now, opts.spawn,
	opts.wait, opts.log, opts.isStudio, opts.guid().
]]

local Receipt = require(script.Receipt)

local Shop = {}

Shop.PASS_CHECK_ATTEMPTS = 3
Shop.PASS_RETRY_DELAY = 1
Shop.PURCHASES_CAP = 200

function Shop.new(opts: any): any
	local data = opts.data
	local policy = opts.policy
	local marketplace = opts.marketplace
	local players = opts.players
	local log: (string) -> () = opts.log
	local spawn: (...any) -> () = opts.spawn
	local now: () -> number = opts.now
	local products = opts.products or { passes = {}, devProducts = {} }
	products.passes = products.passes or {}
	products.devProducts = products.devProducts or {}

	local handlersById: { [number]: { owner: string, fn: (any) -> () } } = {}
	local handlersByName: { [string]: { owner: string, fn: (any) -> () } } = {}
	local passHandlers: { [number]: { (any) -> () } } = {}
	local passCache: { [any]: { [number]: boolean } } = {}
	local passFired: { [any]: { [any]: boolean } } = {}
	local inFlight: { [string]: boolean } = {}
	local pending: { [string]: Receipt.Pending } = {}
	local warned: { [string]: boolean } = {}
	local simulatedName: string? = nil
	local claimed = false

	local s: any = {}

	local function warnOnce(key: string, message: string)
		if not warned[key] then
			warned[key] = true
			log("[StudWork.Shop] " .. message)
		end
	end

	local function productName(id: number): string?
		if simulatedName then
			return simulatedName
		end
		if id <= 0 then
			return nil
		end
		for name, pid in products.devProducts do
			if pid == id then
				return name
			end
		end
		return nil
	end

	local function passId(pass: number | string): number?
		if type(pass) == "number" then
			return if pass > 0 then pass else nil
		end
		local id = products.passes[pass]
		if id == nil then
			warnOnce("pass:" .. pass, "unknown pass '" .. pass .. "' (not in products.passes)")
			return nil
		end
		if id == 0 then
			warnOnce("pass0:" .. pass, "pass '" .. pass .. "' has id 0 (not created yet); treated as not owned")
			return nil
		end
		return id
	end

	local function firePassOwned(player: any, id: number)
		local fired = passFired[player]
		local list = passHandlers[id]
		if fired == nil or list == nil then
			return
		end
		for _, fn in list do
			if not fired[fn] then
				fired[fn] = true
				spawn(fn, player)
			end
		end
	end

	local function grantFeedback(player: any, receipt: any)
		opts.signals.ProductGranted:Fire(player, receipt.ProductId, receipt.PurchaseId)
		local name = productName(receipt.ProductId) or "Purchase"
		pcall(opts.feedback, player, "toast", "Thanks! " .. name .. " received")
		pcall(opts.analytics.custom, player, "ProductPurchased", receipt.CurrencySpent)
	end

	local function flush(effects: { () -> () })
		for _, fn in effects do
			local ok, err = pcall(fn :: any)
			if not ok then
				log("[StudWork.Shop] post-grant effect failed: " .. tostring(err))
			end
		end
	end

	-- The PurchaseTx: a sealed data tx with purchase fields (Data.runTx extras) + internal meta.
	-- Receipt.commit (pure, unchanged from v1.2) drives it: `update` opens ONE framework tx whose
	-- `data` argument is the _framework working section (purchases[PurchaseId] lands in the same
	-- commit as the handler's writes); buildTx hands Receipt the tx handle and its after queue.
	local function commitWith(entry: { owner: string, fn: (any) -> () }, player: any, receipt: any): (string, any, string?)
		local name = productName(receipt.ProductId)
		local tag = name or tostring(receipt.ProductId)
		local handle: any = nil
		local afterQueue: { () -> () } = {}
		local control: any = { retry = false }
		local function use(ref: any): any
			if type(ref) ~= "table" or not opts.isEnabled(ref) then
				error(
					`tx.use: {if type(ref) == "table" then tostring(ref.name) else tostring(ref)} is not enabled in GameConfig.modules`,
					2
				)
			end
			if not opts.canUse(entry.owner, ref) then
				error(`tx.use({ref.name}): {entry.owner} must declare {ref.name} in dependsOn/optional to use its purchase ops`, 2)
			end
			local ops = opts.purchaseOps(ref)
			local bound = {}
			for k, fn in ops do
				bound[k] = function(...: any): ...any
					return fn(handle, ...)
				end
			end
			return table.freeze(bound)
		end
		local extras = {
			paid = true,
			paidRandomRestricted = policy.paidRandomRestricted(player),
			policyKnown = policy.isKnown(player),
			productName = name,
			receipt = table.freeze(table.clone(receipt)),
			use = use,
			after = function(fn: () -> ())
				if type(fn) ~= "function" then
					error("tx.after expects a function", 2)
				end
				table.insert(afterQueue, fn)
			end,
			retryLater = function(reason: string?)
				-- the flag (not the raised value) is what Receipt.commit checks: survives a pcall
				control.retry = true
				control.reason = if type(reason) == "string" then reason else nil
				error("[StudWork.Shop] retryLater", 0)
			end,
		}
		local function update(p: any, fn: (data: any) -> ()): boolean
			local committed = data.runTx(p, function(tx: any)
				handle = tx
				fn(data.section(tx, "_framework"))
			end, { extras = extras, meta = { purchase = true, product = tag } })
			return committed
		end
		local function buildTx(_p: any, _r: any, _data: any, queue: { () -> () }, ctl: any): any
			afterQueue = queue
			control = ctl
			return handle
		end
		local function handler(_fw: any, _r: any, tx: any)
			entry.fn(tx)
		end
		return Receipt.commit(update, handler, buildTx, player, receipt, now())
	end

	local function processWith(receipt: any, override: { owner: string, fn: (any) -> () }?): Receipt.Result
		local entry = override or (if type(receipt) == "table" and type(receipt.ProductId) == "number" then handlersById[receipt.ProductId] else nil)
		local res = Receipt.process(receipt, {
			inFlight = inFlight,
			pending = pending,
			findPlayer = function(userId: number): any
				return players.byUserId(userId)
			end,
			isLoaded = function(player: any): boolean
				return data.isLoaded(player)
			end,
			isRecorded = function(player: any, purchaseId: string): boolean
				local purchases = data.frameworkField(player, "purchases")
				return type(purchases) == "table" and purchases[purchaseId] ~= nil
			end,
			hasHandler = entry ~= nil,
			commit = function(player: any, r: any)
				return commitWith(entry :: any, player, r)
			end,
			save = function(player: any): boolean
				return data.saveAsync(player) == true
			end,
		})
		if res.effects then
			flush(res.effects) -- the grant is saved: exactly once per real grant
			local player = players.byUserId(receipt.PlayerId)
			if player then
				grantFeedback(player, receipt)
			end
		end
		local quiet = res.reason == "not_in_server" or res.reason == "in_flight" or res.reason == "retry_later"
		if res.decision == "NotProcessedYet" and not quiet then
			log(
				`[StudWork.Shop] receipt {tostring(receipt and receipt.PurchaseId)} (product {tostring(receipt and receipt.ProductId)}) not processed: {res.reason}`
					.. (if res.detail then ` ({res.detail})` else "")
			)
		end
		return res
	end

	-- What MarketplaceService.ProcessReceipt returns: "PurchaseGranted" | "NotProcessedYet".
	function s.processReceipt(receipt: any): string
		return processWith(receipt, nil).decision
	end

	-- §7.1: assigned once, at the very end of boot.
	function s.claim()
		claimed = true
		marketplace.setProcessReceipt(function(receipt: any): any
			return marketplace.decision(s.processReceipt(receipt))
		end)
	end

	function s.isClaimed(): boolean
		return claimed
	end

	function s.ownsPass(player: any, pass: number | string): boolean
		local id = passId(pass)
		if id == nil then
			return false
		end
		local cache = passCache[player]
		if cache and cache[id] ~= nil then
			return cache[id]
		end
		local delay = Shop.PASS_RETRY_DELAY
		for attempt = 1, Shop.PASS_CHECK_ATTEMPTS do
			local ok, owns = pcall(marketplace.ownsPass, player.UserId, id)
			if ok then
				local current = passCache[player]
				if current then
					current[id] = current[id] == true or owns == true
					return current[id]
				end
				return owns == true
			end
			if attempt < Shop.PASS_CHECK_ATTEMPTS then
				opts.wait(delay)
				delay *= 2
			end
		end
		log("[StudWork.Shop] UserOwnsGamePassAsync failed for pass " .. id .. "; treating as not owned for now")
		return false
	end

	local function checkPass(player: any, id: number)
		spawn(function()
			if s.ownsPass(player, id) then
				firePassOwned(player, id)
			end
		end)
	end

	function s.playerAdded(player: any)
		passCache[player] = passCache[player] or {}
		passFired[player] = passFired[player] or {}
	end

	function s.playerLoaded(player: any)
		s.playerAdded(player)
		for id in passHandlers do
			checkPass(player, id)
		end
	end

	function s.playerRemoving(player: any)
		passCache[player] = nil
		passFired[player] = nil
		for _, dropped in Receipt.forgetPlayer(pending, player.UserId) do
			pcall(opts.analytics.custom, player, "ProductPurchased", dropped.currencySpent or 0)
		end
	end

	function s.passPurchased(player: any, gamePassId: number, wasPurchased: boolean)
		if wasPurchased ~= true or type(gamePassId) ~= "number" then
			return
		end
		local cache = passCache[player]
		if cache == nil then
			return
		end
		cache[gamePassId] = true
		pcall(opts.feedback, player, "toast", "Gamepass unlocked!")
		pcall(opts.analytics.custom, player, "PassPurchased", 1)
		firePassOwned(player, gamePassId)
	end

	-- Studio `shop receipt <productName> [purchaseId] [userId]`: process the receipt twice.
	function s.consoleReceipt(name: any, purchaseIdArg: any, userIdArg: any): string
		if not opts.isStudio then
			return "receipt is Studio-only"
		end
		if type(name) ~= "string" then
			return "usage: shop receipt <productName> [purchaseId] [userId]"
		end
		local player = if tonumber(userIdArg) then players.byUserId(tonumber(userIdArg) :: number) else players.list()[1]
		if player == nil then
			return "no player in server"
		end
		local id = products.devProducts[name] or tonumber(name) or 0
		local entry = handlersById[id] or handlersByName[name]
		if entry == nil then
			return "no handler registered for product " .. name
		end
		local purchaseId = if type(purchaseIdArg) == "string" and purchaseIdArg ~= "" then purchaseIdArg else "studio-" .. opts.guid()
		local receipt = {
			PlayerId = player.UserId,
			PurchaseId = purchaseId,
			ProductId = id,
			CurrencySpent = 0,
			PlaceIdWherePurchased = 0,
		}
		simulatedName = if products.devProducts[name] ~= nil then name else nil
		local ok, first, second = pcall(function()
			return processWith(receipt, entry), processWith(receipt, entry)
		end)
		simulatedName = nil
		if not ok then
			return "receipt simulation errored: " .. tostring(first)
		end
		return `{purchaseId}: 1st {first.decision} ({first.reason}), 2nd {second.decision} ({second.reason})`
	end

	function s.forModule(owner: string): any
		return table.freeze({
			onProduct = function(product: number | string, handler: (tx: any) -> ())
				if type(handler) ~= "function" then
					error("ctx.shop.onProduct: handler must be a function(tx)", 2)
				end
				local entry = { owner = owner, fn = handler }
				if type(product) == "number" then
					if handlersById[product] ~= nil then
						error(`ctx.shop.onProduct: product {product} already has a handler (owned by {handlersById[product].owner})`, 2)
					end
					handlersById[product] = entry
					return
				end
				if type(product) ~= "string" then
					error("ctx.shop.onProduct: product must be an id or a devProducts name", 2)
				end
				local id = products.devProducts[product]
				if id == nil then
					error(`ctx.shop.onProduct: unknown product '{product}' (not in products.devProducts)`, 2)
				end
				if handlersByName[product] ~= nil then
					error(`ctx.shop.onProduct: product '{product}' already has a handler (owned by {handlersByName[product].owner})`, 2)
				end
				handlersByName[product] = entry
				if id == 0 then
					warnOnce("product0:" .. product, "product '" .. product .. "' has id 0 (not created yet)")
					return
				end
				if handlersById[id] ~= nil then
					error(`ctx.shop.onProduct: product id {id} already has a handler`, 2)
				end
				handlersById[id] = entry
			end,
			onPassOwned = function(pass: number | string, handler: (player: any) -> ())
				if type(handler) ~= "function" then
					error("ctx.shop.onPassOwned: handler must be a function(player)", 2)
				end
				local id = passId(pass)
				if id == nil then
					return
				end
				passHandlers[id] = passHandlers[id] or {}
				table.insert(passHandlers[id], handler)
				for _, player in players.list() do
					if passFired[player] and data.isLoaded(player) then
						checkPass(player, id)
					end
				end
			end,
			ownsPass = function(player: any, pass: number | string): boolean
				return s.ownsPass(player, pass)
			end,
		})
	end

	return s
end

return Shop
