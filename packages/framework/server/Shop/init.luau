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

	ProcessReceipt (§7.1, revised in v1.3.0): Shop assigns MarketplaceService.ProcessReceipt once,
	at the very end of boot (after every module's init AND start), so no module code that runs
	during boot can win against it; tools/lint bans assigning it anywhere else. The design's
	runtime replacement check can't be built: ProcessReceipt is a write-only callback (reading it
	errors "you can only set the callback value, get is not available", and it fires no Changed
	signal; verified in Studio). Shop does NOT re-assign periodically, because a blind re-assert
	would be exactly the silent fight the design rejects. See decisions.md, "Purchases and receipts".

	Gamepasses: ownsPass(player, pass) cached per player per pass (UserOwnsGamePassAsync once, with
	retries; failures not cached); every products.passes entry is fetched at join, before the save
	loads (v1.6.0, at most PASS_PREFETCH_SECONDS), so ownsPass of a loaded player never yields; a call that WOULD yield inside a tx (or a
	non-yieldable context) errors "ctx.shop.ownsPass yields: call it outside a transaction ...";
	PromptGamePassPurchaseFinished(true) marks it owned;
	onPassOwned(pass, fn) runs once per player per pass (owned at join, after data load, or bought).

	Shop.new(opts): opts.data, opts.policy, opts.products, opts.marketplace (platform), opts.players
	({ byUserId, list }), opts.isPlayer, opts.feedback, opts.analytics, opts.signals, opts.purchaseOps
	(ref -> ops), opts.canUse(callerName, ref) -> boolean, opts.isEnabled(ref), opts.now, opts.spawn,
	opts.wait, opts.log, opts.isStudio, opts.guid(). platform.marketplace.getProcessReceipt() -> (readable,
	fn?) is optional (no check without it).

	v1.6.0 purchase bridge (docs/framework/adopting.md §4): opts.legacy (the read-only Legacy reader),
	opts.hasLegacyImport() -> boolean (asked at claim time, the end of boot).
	  A PurchaseId in _framework.purchases OR _framework.legacyPurchases is recorded (duplicate).
	  ctx.shop.legacyReceipts({ name, scope?, key, until?, checkDays? }): once per game, before the
	      claim; checkDays (v1.6.1, default Legacy.RECEIPT_KEEP_DAYS = 90) is how long after until the
	      store is still checked; every
	      unrecorded receipt is checked against the old history store first (Receipt step 5b).
	  ctx.shop.onLegacyProduct(product, fn(receiptInfo, player), { writesLegacyData = boolean }):
	      a development bridge for an old product handler (Receipt.legacyCommit). One handler per
	      product across onProduct and onLegacyProduct. Boot warning per product; boot error at
	      claim when hasLegacyImport() and any writesLegacyData = true.
	      v1.6.1: a writesLegacyData = false handler that writes an old store anyway fails loudly
	      (NotProcessedYet, nothing recorded, an error naming product/module/store/key): with a
	      test mock (reader.canWatch) every write while the handler runs is reported (the
	      legacyReceipts history store excepted); in Studio the importLegacy sources' keys are
	      read before and after the handler and compared (a failed read -> NotProcessedYet).
	      Live servers: no check (A's boot warning; --verify refuses any bridge).
]]

local Receipt = require(script.Receipt)
local Legacy = require(script.Parent.Legacy)

local Shop = {}

Shop.PASS_CHECK_ATTEMPTS = 3
Shop.PASS_RETRY_DELAY = 1
Shop.PASS_PREFETCH_SECONDS = 5 -- (v1.6.0) longest a join waits for its pass answers before loading
Shop.PURCHASES_CAP = 200
Shop.RECEIPT_CHECK_SECONDS = 2 -- §7.1 runtime ProcessReceipt owner check interval

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

	-- legacy (v1.6.0): an onLegacyProduct entry; fn is then the old handler(receiptInfo, player)
	type Entry = { owner: string, fn: (...any) -> ...any, legacy: boolean?, writesLegacyData: boolean? }
	local handlersById: { [number]: Entry } = {}
	local handlersByName: { [string]: Entry } = {}
	local legacyStore: { name: string, scope: string?, key: string, ["until"]: number?, checkDays: number }? =
		nil
	local legacyProducts: { { product: string, owner: string, writes: boolean } } = {}
	local passHandlers: { [number]: { (any) -> () } } = {}
	local passCache: { [any]: { [number]: boolean } } = {}
	local passFailed: { [any]: { [number]: boolean } } = {} -- (v1.6.0) lookups that failed at join
	local passFired: { [any]: { [any]: boolean } } = {}
	local inFlight: { [string]: boolean } = {}
	local pending: { [string]: Receipt.Pending } = {}
	local parkedProduct: { [string]: number } = {} -- PurchaseId -> ProductId of a parked grant
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
			warnOnce(
				"pass0:" .. pass,
				"pass '" .. pass .. "' has id 0 (not created yet); treated as not owned"
			)
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

	-- v1.6.1 (adopting.md §4.3, final review M1): an onLegacyProduct handler that declared
	-- writesLegacyData = false must not write the old stores. Wraps the old handler; a detected
	-- write (or a failed Studio key read) raises, so Receipt.legacyCommit answers
	-- legacy_not_granted (NotProcessedYet, nothing recorded). Detection only ever READS.
	local function guardUndeclared(entry: Entry, tag: string, player: any): (any, any) -> any
		local reader = opts.legacy
		if reader == nil then
			return entry.fn
		end
		local history = legacyStore
		local historyId = if history then Legacy.storeId(history.name, history.scope) else nil
		local function fail(where: string): any
			local msg =
				`[StudWork.Shop] UNDECLARED LEGACY WRITE: legacy product {tag} ({entry.owner}) declared writesLegacyData = false but its old handler wrote {where}; receipt NOT granted (NotProcessedYet). Declare writesLegacyData = true or remove the write (adopting.md §4.3)`
			log(msg)
			error(msg, 0)
		end
		if reader.canWatch() then
			return function(receiptInfo: any, p: any): any
				local hits: { string } = {}
				local stop = reader.watchWrites(function(ev: any)
					if ev.store ~= historyId then
						table.insert(hits, `store {ev.store} key {ev.key} ({ev.op})`)
					end
				end)
				local ok, answer = pcall(entry.fn, receiptInfo, p)
				stop()
				if #hits > 0 then
					return fail(hits[1])
				end
				if not ok then
					error(answer, 0)
				end
				return answer
			end
		end
		if not opts.isStudio or opts.data == nil or opts.data.legacyImportSpecs == nil then
			return entry.fn -- live: declared only (boot warning, --verify refuses any bridge)
		end
		local sources: { any } = {}
		for _, imp in opts.data.legacyImportSpecs() do
			local list = Legacy.sourceList(imp.source)
			for _, item in list do
				table.insert(sources, item.source)
			end
		end
		if #sources == 0 then
			return entry.fn -- no import: nothing to lose (the old save isn't imported)
		end
		local function stampAll(): (boolean, any)
			local all = {}
			for _, src in sources do
				local ok, st = reader.stamp(src, player.UserId)
				if not ok then
					return false, st
				end
				for _, x in st do
					table.insert(all, x)
				end
			end
			return true, all
		end
		return function(receiptInfo: any, p: any): any
			local ok, before = stampAll()
			if not ok and before == Legacy.NO_ACCESS then
				-- no API access in Studio: the old handler can't write either, and the import is
				-- skipped this session (Legacy reader), so nothing can be lost
				return entry.fn(receiptInfo, p)
			end
			if not ok then
				local msg =
					`[StudWork.Shop] legacy product {tag} ({entry.owner}): could not read the old save keys before the handler (writesLegacyData = false check): {tostring(
						before
					)}; NotProcessedYet`
				log(msg)
				error(msg, 0)
			end
			local hok, answer = pcall(entry.fn, receiptInfo, p)
			local ok2, after = stampAll()
			if not ok2 then
				local msg =
					`[StudWork.Shop] legacy product {tag} ({entry.owner}): could not read the old save keys after the handler (writesLegacyData = false check): {tostring(
						after
					)}; NotProcessedYet`
				log(msg)
				error(msg, 0)
			end
			local unchanged, where = Legacy.sameStamp(before, after)
			if not unchanged then
				return fail(`store/key {tostring(where)}`)
			end
			if not hok then
				error(answer, 0)
			end
			return answer
		end
	end

	-- The PurchaseTx: a sealed data tx with purchase fields (Data.runTx extras) + internal meta.
	-- Receipt.commit (pure, unchanged from v1.2) drives it: `update` opens ONE framework tx whose
	-- `data` argument is the _framework working section (purchases[PurchaseId] lands in the same
	-- commit as the handler's writes); buildTx hands Receipt the tx handle and its after queue.
	local function commitWith(entry: Entry, player: any, receipt: any): (Receipt.CommitStatus, any, string?)
		local name = productName(receipt.ProductId)
		local tag = name or tostring(receipt.ProductId)
		if entry.legacy then
			-- §4.3: the old handler runs outside a tx; only the record is a framework tx
			local function recordUpdate(p: any, fn: (data: any) -> ()): boolean
				return (
					data.runTx(p, function(tx: any)
						fn(data.section(tx, "_framework"))
					end, { meta = { purchase = true, product = tag, legacyProduct = true } })
				)
			end
			local oldHandler = if entry.writesLegacyData == false
				then guardUndeclared(entry, tag, player)
				else entry.fn
			return Receipt.legacyCommit(recordUpdate, oldHandler :: any, player, receipt, now())
		end
		local handle: any = nil
		-- Receipt.commit's after queue and control, handed over in buildTx (before the handler runs)
		local live: { queue: { () -> () }?, control: any } = { queue = nil, control = nil }
		local function use(ref: any): any
			if type(ref) ~= "table" or not opts.isEnabled(ref) then
				error(
					`tx.use: {if type(ref) == "table" then tostring(ref.name) else tostring(ref)} is not enabled in GameConfig.modules`,
					2
				)
			end
			if not opts.canUse(entry.owner, ref) then
				error(
					`tx.use({ref.name}): {entry.owner} must declare {ref.name} in dependsOn/optional to use its purchase ops`,
					2
				)
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
				table.insert(live.queue :: { () -> () }, fn)
			end,
			retryLater = function(reason: string?)
				-- the flag (not the raised value) is what Receipt.commit checks: survives a pcall
				live.control.retry = true
				live.control.reason = if type(reason) == "string" then reason else nil
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
			live.queue = queue
			live.control = ctl
			return handle
		end
		local function handler(_fw: any, _r: any, tx: any)
			entry.fn(tx)
		end
		return Receipt.commit(update, handler, buildTx, player, receipt, now())
	end

	-- §4.2: the old history store check (Receipt step 5b). nil = no store registered.
	local function legacyCheck(player: any, purchaseId: string): (Receipt.LegacyCheck, string?)
		local spec = legacyStore :: any
		local cutover = spec["until"]
		if cutover ~= nil and now() > cutover + spec.checkDays * 86400 then
			return "skip", nil
		end
		local key = Legacy.expand(spec.key, { userId = player.UserId, purchaseId = purchaseId })
		local ok, value, err = opts.legacy.readKey(spec.name, spec.scope, key)
		if not ok then
			return "error", tostring(err)
		end
		return if value ~= nil then "found" else "none", nil
	end

	local function recordLegacy(player: any, purchaseId: string): boolean
		return (
			data.runTx(player, function(tx: any)
				local fw = data.section(tx, "_framework")
				fw.legacyPurchases = fw.legacyPurchases or {}
				fw.legacyPurchases[purchaseId] = now()
			end, { meta = { purchase = true, legacyDuplicate = true } })
		)
	end

	local function processWith(receipt: any, override: Entry?): Receipt.Result
		local entry = override
			or (
				if type(receipt) == "table" and type(receipt.ProductId) == "number"
					then handlersById[receipt.ProductId]
					else nil
			)
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
				if type(purchases) == "table" and purchases[purchaseId] ~= nil then
					return true
				end
				-- v1.6.0 (adopting.md §4.1): ids the old game granted, carried over by the import
				local old = data.frameworkField(player, "legacyPurchases")
				return type(old) == "table" and old[purchaseId] ~= nil
			end,
			legacyCheck = if legacyStore ~= nil then legacyCheck else nil,
			recordLegacy = recordLegacy,
			hasHandler = entry ~= nil,
			commit = function(player: any, r: any)
				return commitWith(entry :: any, player, r)
			end,
			save = function(player: any): boolean
				return data.saveAsync(player) == true
			end,
		})
		if type(receipt) == "table" and type(receipt.PurchaseId) == "string" then
			if pending[receipt.PurchaseId] ~= nil then
				parkedProduct[receipt.PurchaseId] = receipt.ProductId
			else
				parkedProduct[receipt.PurchaseId] = nil
			end
		end
		if res.effects then
			flush(res.effects) -- the grant is saved: exactly once per real grant
			local player = players.byUserId(receipt.PlayerId)
			if player then
				grantFeedback(player, receipt)
			end
		end
		local quiet = res.reason == "not_in_server"
			or res.reason == "in_flight"
			or res.reason == "retry_later"
		if res.decision == "NotProcessedYet" and not quiet then
			log(
				`[StudWork.Shop] receipt {tostring(receipt and receipt.PurchaseId)} (product {tostring(
					receipt and receipt.ProductId
				)}) not processed: {res.reason}`
					.. (if res.detail then ` ({res.detail})` else "")
			)
		end
		return res
	end

	-- What MarketplaceService.ProcessReceipt returns: "PurchaseGranted" | "NotProcessedYet".
	function s.processReceipt(receipt: any): string
		return processWith(receipt, nil).decision
	end

	-- §7.1: claimed at the very end of boot, then guarded at runtime (s.tick).
	local assigned: ((any) -> any)? = nil
	local checkAcc = 0
	local checkStatus = "not claimed"
	local hijacks = 0

	function s.claim()
		-- §4.3 boot error: an old handler that writes the old save while an import reads it
		if opts.hasLegacyImport ~= nil then
			local writer: any = nil
			for _, lp in legacyProducts do
				if lp.writes then
					writer = lp
					break
				end
			end
			if writer ~= nil and opts.hasLegacyImport() then
				local ids = if opts.data and opts.data.legacyImports then opts.data.legacyImports() else {}
				local who = if #ids > 0 then table.concat(ids, ", ") else "a module"
				error(
					`legacy product {writer.product} writes the old save, but {who} imports it (importLegacy); migrate {writer.product} to ctx.shop.onProduct first`,
					0
				)
			end
		end
		claimed = true
		local fn = function(receipt: any): any
			return marketplace.decision(s.processReceipt(receipt))
		end
		assigned = fn
		marketplace.setProcessReceipt(fn)
		checkStatus = if marketplace.getProcessReceipt
			then "active"
			else "unavailable (platform can't read it)"
	end

	function s.isClaimed(): boolean
		return claimed
	end

	-- Where a replacement ProcessReceipt was defined (debug.info), or "unknown source".
	function Shop.sourceOf(fn: any): string
		if type(fn) ~= "function" then
			return "unknown source (" .. type(fn) .. ")"
		end
		local info: any = debug.info
		local ok, src, line = pcall(info, fn, "sl")
		if ok and type(src) == "string" and src ~= "" and src ~= "[C]" then
			return if type(line) == "number" and line > 0 then `{src}:{line}` else src
		end
		return "unknown source"
	end

	-- The runtime replacement check (§7.1): MarketplaceService.ProcessReceipt must still be the
	-- function Shop assigned. A mismatch warns naming the source, fires analytics
	-- ProcessReceiptHijacked (customFields.source) and reassigns Shop's function. Returns true
	-- when a replacement was found. Platforms whose ProcessReceipt can't be read (the live engine:
	-- the callback is write-only) report checkStatus "unavailable"; the lint guardrail is the
	-- enforcement there (see Shop/README.md).
	function s.checkReceiptOwner(): boolean
		if not claimed or assigned == nil or marketplace.getProcessReceipt == nil then
			return false
		end
		local readable, current = marketplace.getProcessReceipt()
		if not readable then
			checkStatus = "unavailable (ProcessReceipt is write-only on this platform)"
			return false
		end
		checkStatus = "active"
		if current == assigned then
			return false
		end
		hijacks += 1
		local source = Shop.sourceOf(current)
		log(
			`[StudWork.Shop] MarketplaceService.ProcessReceipt was replaced (by {source}); reclaiming it. Only the framework Shop may assign ProcessReceipt (module-api.md §7.1): use ctx.shop.onProduct.`
		)
		local witness = players.list()[1]
		if witness ~= nil then
			pcall(opts.analytics.custom, witness, "ProcessReceiptHijacked", 1, { source = source })
		end
		marketplace.setProcessReceipt(assigned)
		return true
	end

	function s.receiptCheck(): { status: string, hijacks: number }
		return { status = checkStatus, hijacks = hijacks }
	end

	-- Driven by the runtime ticker (Heartbeat via the platform).
	function s.tick(dt: number)
		checkAcc += dt
		if checkAcc >= Shop.RECEIPT_CHECK_SECONDS then
			checkAcc = 0
			s.checkReceiptOwner()
		end
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
		-- (v1.6.0 dogfood) not cached yet: answering would yield (UserOwnsGamePassAsync). Inside a
		-- transaction (a capBonus / rateFactor / roll runs in one) or any non-yieldable context
		-- that would discard the change with a confusing "fn must not yield", or (in the sim)
		-- park the caller forever. Every pass in products.passes is fetched when the player
		-- joins, so this only happens before that answer arrived, or for a raw pass id.
		local inTx = data ~= nil and data.openTxPlayer ~= nil and data.openTxPlayer() ~= nil
		if (inTx or not coroutine.isyieldable()) and passFailed[player] and passFailed[player][id] then
			warnOnce(
				`passfail:{id}`,
				`ownsPass: the lookup of pass {id} failed at join; read as not owned inside a transaction until a retry outside one succeeds`
			)
			return false
		end
		if inTx or not coroutine.isyieldable() then
			error(
				`ctx.shop.ownsPass yields: call it outside a transaction (pass '{tostring(pass)}' isn't known yet for {tostring(
					player
				)}; StudWork fetches every products.passes entry at join, so read it after the player loaded, or track ownership with ctx.shop.onPassOwned)`,
				2
			)
		end
		local delay = Shop.PASS_RETRY_DELAY
		for attempt = 1, Shop.PASS_CHECK_ATTEMPTS do
			local ok, owns = pcall(marketplace.ownsPass, player.UserId, id)
			if ok then
				if passFailed[player] then
					passFailed[player][id] = nil
				end
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
		if passCache[player] ~= nil then
			passFailed[player] = passFailed[player] or {}
			passFailed[player][id] = true
		end
		log(
			"[StudWork.Shop] UserOwnsGamePassAsync failed for pass "
				.. id
				.. "; treating as not owned for now"
		)
		return false
	end

	local function checkPass(player: any, id: number)
		spawn(function()
			if s.ownsPass(player, id) then
				firePassOwned(player, id)
			end
		end)
	end

	-- (v1.6.0 dogfood) every pass in products.passes is fetched once per player at join, in
	-- parallel, and playerAdded waits for the answers (at most Shop.PASS_PREFETCH_SECONDS) before
	-- the runtime loads the save: so by the time the player is loaded, ownsPass is a cache read that
	-- never yields, even inside a tx. A pass whose lookup failed is remembered in passFailed: inside
	-- a tx it reads as not owned (logged) instead of erroring, and is retried outside.
	local function prefetchPasses(player: any)
		local open = 0
		for _, id in products.passes do
			if type(id) == "number" and id > 0 then
				open += 1
				spawn(function()
					local cache = passCache[player]
					if cache ~= nil and cache[id] == nil then
						pcall(s.ownsPass, player, id)
					end
					open -= 1
				end)
			end
		end
		if open > 0 and opts.wait ~= nil and coroutine.isyieldable() then
			local waited = 0
			while open > 0 and waited < Shop.PASS_PREFETCH_SECONDS and passCache[player] ~= nil do
				waited += opts.wait(0.05) or 0.05
			end
		end
	end

	function s.playerAdded(player: any)
		local first = passCache[player] == nil
		passCache[player] = passCache[player] or {}
		passFired[player] = passFired[player] or {}
		if first then
			prefetchPasses(player)
		end
	end

	function s.playerLoaded(player: any)
		s.playerAdded(player)
		for id in passHandlers do
			checkPass(player, id)
		end
	end

	-- N9 (v1.3.0): a player leaving while a grant's save is still unconfirmed. Called by the
	-- runtime BEFORE Data releases the player (the record is still there; may yield). One more
	-- confirmed save is attempted; if it lands, the parked tx.after effects run now (they must not
	-- assume the player is still in the server: analytics, cross-player Mail/messages, signals),
	-- plus ProductGranted + ProductPurchased. If it can't be confirmed, the effects are dropped
	-- (the grant still persists through the session-end save if that lands, and the next server
	-- then sees a duplicate) and only ProductPurchased is logged. The PurchaseIds stay in flight
	-- meanwhile, so a concurrent retry gets NotProcessedYet instead of an unconfirmed grant.
	function s.settleOnLeave(player: any)
		local mine: { { id: string, parked: Receipt.Pending } } = {}
		for id, parked in pending do
			if parked.userId == player.UserId then
				table.insert(mine, { id = id, parked = parked })
			end
		end
		if #mine == 0 then
			return
		end
		for _, m in mine do
			pending[m.id] = nil
			inFlight[m.id] = true
		end
		local ok, saved = pcall(data.saveAsync, player)
		for _, m in mine do
			inFlight[m.id] = nil
		end
		for _, m in mine do
			local spent = m.parked.currencySpent or 0
			if m.parked.kind == "legacy_duplicate" then
				-- nothing was granted here (the old game did): no effects, signal or analytics
				parkedProduct[m.id] = nil
				continue
			end
			if ok and saved == true then
				flush(m.parked.effects)
				opts.signals.ProductGranted:Fire(player, parkedProduct[m.id], m.id)
			else
				log(
					`[StudWork.Shop] receipt {m.id}: the player left before the grant's save was confirmed; its tx.after effects are dropped (N9, best effort)`
				)
			end
			pcall(opts.analytics.custom, player, "ProductPurchased", spent)
			parkedProduct[m.id] = nil
		end
	end

	function s.playerRemoving(player: any)
		passCache[player] = nil
		passFailed[player] = nil
		passFired[player] = nil
		-- anything settleOnLeave didn't see (it runs first): v1.2 behaviour, effects dropped
		for id, p in pending do
			if p.userId == player.UserId then
				parkedProduct[id] = nil
			end
		end
		for _, dropped in Receipt.forgetPlayer(pending, player.UserId) do
			if dropped.kind == "legacy_duplicate" then
				continue
			end
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
		local player = if tonumber(userIdArg)
			then players.byUserId(tonumber(userIdArg) :: number)
			else players.list()[1]
		if player == nil then
			return "no player in server"
		end
		local id = products.devProducts[name] or tonumber(name) or 0
		local entry = handlersById[id] or handlersByName[name]
		if entry == nil then
			return "no handler registered for product " .. name
		end
		local purchaseId = if type(purchaseIdArg) == "string" and purchaseIdArg ~= ""
			then purchaseIdArg
			else "studio-" .. opts.guid()
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

	-- One handler per product across onProduct and onLegacyProduct. -> error message or nil.
	local function register(api: string, product: number | string, entry: Entry): string?
		if type(product) == "number" then
			if handlersById[product] ~= nil then
				return `{api}: product {product} already has a handler (owned by {handlersById[product].owner})`
			end
			handlersById[product] = entry
			return nil
		end
		if type(product) ~= "string" then
			return `{api}: product must be an id or a devProducts name`
		end
		local id = products.devProducts[product]
		if id == nil then
			return `{api}: unknown product '{product}' (not in products.devProducts)`
		end
		if handlersByName[product] ~= nil then
			return `{api}: product '{product}' already has a handler (owned by {handlersByName[product].owner})`
		end
		if id ~= 0 and handlersById[id] ~= nil then
			return `{api}: product id {id} already has a handler`
		end
		handlersByName[product] = entry
		if id == 0 then
			warnOnce("product0:" .. product, "product '" .. product .. "' has id 0 (not created yet)")
			return nil
		end
		handlersById[id] = entry
		return nil
	end

	function s.legacyReceiptStore(): any
		return legacyStore
	end

	function s.forModule(owner: string): any
		return table.freeze({
			onProduct = function(product: number | string, handler: (tx: any) -> ())
				if type(handler) ~= "function" then
					error("ctx.shop.onProduct: handler must be a function(tx)", 2)
				end
				local err = register("ctx.shop.onProduct", product, { owner = owner, fn = handler })
				if err then
					error(err, 2)
				end
			end,
			-- v1.6.0 (adopting.md §4.3): an old product handler, a development bridge (never live)
			onLegacyProduct = function(
				product: number | string,
				handler: (receiptInfo: any, player: any) -> any,
				o: any
			)
				if type(handler) ~= "function" then
					error("ctx.shop.onLegacyProduct: handler must be a function(receiptInfo, player)", 2)
				end
				if type(o) ~= "table" or type(o.writesLegacyData) ~= "boolean" then
					error(
						"ctx.shop.onLegacyProduct: opts.writesLegacyData (boolean) is required: does the old handler write the old save?",
						2
					)
				end
				if claimed or (opts.phase ~= nil and opts.phase() ~= "init") then
					error("ctx.shop.onLegacyProduct: register it in init", 2)
				end
				local err = register(
					"ctx.shop.onLegacyProduct",
					product,
					{ owner = owner, fn = handler, legacy = true, writesLegacyData = o.writesLegacyData }
				)
				if err then
					error(err, 2)
				end
				local label = tostring(product)
				table.insert(legacyProducts, { product = label, owner = owner, writes = o.writesLegacyData })
				log(
					`[StudWork.Shop] legacy product {label} ({owner}) runs its old handler through ctx.shop.onLegacyProduct: a development bridge, never ship it live (tools/publish --live refuses); port it to ctx.shop.onProduct`
				)
			end,
			-- v1.6.0 (adopting.md §4.2): the old game's purchase history store, once per game, in init
			legacyReceipts = function(spec: any)
				if claimed or (opts.phase ~= nil and opts.phase() ~= "init") then
					error("ctx.shop.legacyReceipts: register it in init", 2)
				end
				if legacyStore ~= nil then
					error("ctx.shop.legacyReceipts: already registered (once per game)", 2)
				end
				local err = Shop.validateLegacyReceipts(spec)
				if err then
					error("ctx.shop.legacyReceipts: " .. err, 2)
				end
				if opts.legacy == nil then
					error("ctx.shop.legacyReceipts: no legacy reader in this runtime", 2)
				end
				legacyStore = table.freeze({
					name = spec.name,
					scope = spec.scope,
					key = spec.key,
					["until"] = spec["until"],
					checkDays = spec.checkDays or Legacy.RECEIPT_KEEP_DAYS,
				})
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

-- adopting.md §4.2: validates a ctx.shop.legacyReceipts spec. -> error message or nil.
function Shop.validateLegacyReceipts(spec: any): string?
	if type(spec) ~= "table" then
		return "expects { name, scope?, key, until?, checkDays? }"
	end
	for k in spec do
		if k ~= "name" and k ~= "scope" and k ~= "key" and k ~= "until" and k ~= "checkDays" then
			return `unknown field '{tostring(k)}' (name, scope, key, until, checkDays)`
		end
	end
	if type(spec.name) ~= "string" or spec.name == "" then
		return "name must be the old DataStore's name (a non-empty string)"
	end
	if spec.scope ~= nil and type(spec.scope) ~= "string" then
		return "scope must be a string"
	end
	if type(spec.key) ~= "string" or not string.find(spec.key, "{purchaseId}", 1, true) then
		return "key must be a pattern that uses {purchaseId} (and usually {userId})"
	end
	local ok, err = pcall(Legacy.expand, spec.key, { userId = 1, purchaseId = "x" })
	if not ok then
		return tostring(err)
	end
	local u = spec["until"]
	if u ~= nil and (type(u) ~= "number" or u ~= u or u <= 0) then
		return "until must be a unix time in seconds"
	end
	local d = spec.checkDays
	if d ~= nil and (type(d) ~= "number" or d ~= d or d <= 0 or d == math.huge) then
		return "checkDays must be a positive number of days (how long after until the old store is still checked; default 90)"
	end
	return nil
end

return Shop
