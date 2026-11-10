--!strict
--[[
	Core.Shop. OWNED BY AGENT A (M4 receipts; gamepasses unchanged). Public API: Types.ShopAPI.

	Developer products (MarketplaceService.ProcessReceipt, flow in Receipt.luau):
	  - onProduct(product, handler): product = developer product id or a name in
	    GameConfig.products.devProducts. Ids of 0 mean "not created on Roblox yet": the handler is
	    kept by name (usable from the `receipt` console command) and a warning is printed once.
	  - The handler (Types.ProductHandler) and purchases[PurchaseId] = now run in ONE
	    non-yielding Data.update (Receipt.commit). Handler error -> nothing committed,
	    NotProcessedYet "handler_error"; yield -> "handler_yielded"; tx.retryLater(reason) ->
	    "retry_later" (not warned). PurchaseGranted only after Data.saveAsync confirmed the save;
	    a failed save keeps the in-memory record, so the retry is a "duplicate" (handler not run
	    again). The same PurchaseId is never processed concurrently (in-flight set).
	  - tx.after effects + ProductGranted signal, "toast" feedback and
	    Analytics.custom("ProductPurchased") run exactly once, when the grant is saved.

	Gamepasses:
	  - ownsPass(player, pass): cached per player per pass; UserOwnsGamePassAsync is called once
	    (pcall + retries; failures are not cached). Cache cleared when the player leaves.
	    Pass id 0 / unknown name -> false (warned once).
	  - PromptGamePassPurchaseFinished(wasPurchased = true) marks the pass owned.
	  - onPassOwned(pass, handler): each handler runs once per player per pass, for passes owned
	    at join (checked after data load) and for passes bought in-session.
]]

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local Receipt = require(script.Receipt)
local Tx = require(script.Parent.Tx)

local PASS_CHECK_ATTEMPTS = 3
local PASS_RETRY_DELAY = 1 -- seconds, doubles per attempt

type ProductHandler = Types.ProductHandler

type PassHandler = (Player) -> ()

local Shop = {}

local ctx: any = nil
local handlersById: { [number]: ProductHandler } = {}
local handlersByName: { [string]: ProductHandler } = {}
local passHandlers: { [number]: { PassHandler } } = {}
local passCache: { [Player]: { [number]: boolean } } = {}
local passFired: { [Player]: { [PassHandler]: boolean } } = {}
local inFlight: { [string]: boolean } = {}
local pending: { [string]: Receipt.Pending } = {}
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if not warned[key] then
		warned[key] = true
		warn("[Core.Shop] " .. message)
	end
end

local function products(): Types.ProductsConfig
	return ctx.config.products or { passes = {}, devProducts = {} }
end

local function productName(id: number): string?
	for name, pid in products().devProducts do
		if pid == id then
			return name
		end
	end
	return nil
end

-- Resolves a pass id. nil = unknown or not created yet (0).
local function passId(pass: number | string): number?
	if type(pass) == "number" then
		return if pass > 0 then pass else nil
	end
	local id = products().passes[pass]
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

-- Runs every onPassOwned handler for this pass that hasn't run for this player yet.
local function firePassOwned(player: Player, id: number)
	local fired = passFired[player]
	if fired == nil then
		return
	end
	local list = passHandlers[id]
	if list == nil then
		return
	end
	for _, fn in list do
		if not fired[fn] then
			fired[fn] = true
			task.spawn(fn, player)
		end
	end
end

local function grantFeedback(player: Player, receipt: Types.ReceiptInfo)
	ctx.signals.ProductGranted:Fire(player, receipt.ProductId, receipt.PurchaseId)
	local name = productName(receipt.ProductId) or "Purchase"
	pcall(ctx.net.feedback, player, "toast", "Thanks! " .. name .. " received")
	pcall(ctx.services.Analytics.custom, player, "ProductPurchased", receipt.CurrencySpent)
end

local function needModule(name: string, what: string)
	if not ctx.isEnabled(name) then
		error(`[Core.Shop] PurchaseTx.{what} needs the {name} module`, 3)
	end
end

local function makePurchaseTx(
	player: Player,
	receipt: Types.ReceiptInfo,
	data: Types.PlayerData,
	queue: { () -> () },
	control: Receipt.Control
): Types.PurchaseTx
	local tx = Tx.new(player, data, queue)
	local name = productName(receipt.ProductId)
	local tag = name or tostring(receipt.ProductId)
	local Policy = ctx.services.Policy
	return {
		player = player,
		receipt = receipt,
		productName = name,
		policyKnown = Policy.isKnown(player),
		paidRandomRestricted = Policy.paidRandomRestricted(player),
		grant = function(amount: number, currency: string?): boolean
			needModule("Economy", "grant")
			return ctx.services.Economy.grantInto(tx, amount, "product:" .. tag, currency)
		end,
		addItem = function(itemId: string, opts: Types.InventoryAddOptions?): Types.ItemInstance?
			needModule("Inventory", "addItem")
			local o: Types.InventoryAddOptions = if opts then table.clone(opts) else {}
			o.source = o.source or ("paid:" .. tag)
			return ctx.services.Inventory.addInto(tx, itemId, o)
		end,
		roll = function(tableId: string, luck: number?): (Types.ItemDef?, Types.RollInfo)
			needModule("Rarity", "roll")
			needModule("Inventory", "roll")
			return ctx.services.Rarity.rollInto(
				tx,
				tableId,
				luck,
				{ paid = true, grant = true, reason = "product:" .. tag }
			)
		end,
		retryLater = function(reason: string?)
			-- the flag (not the raised value) is what Receipt.commit checks: survives a pcall
			control.retry = true
			control.reason = if type(reason) == "string" then reason else nil
			error("[Core.Shop] retryLater", 0)
		end,
		after = tx.after,
	}
end

-- handlerOverride lets the Studio console simulate a product whose id is still 0.
local function processWith(receipt: Types.ReceiptInfo, handlerOverride: ProductHandler?): Receipt.Result
	local Data = ctx.services.Data
	local productHandler = handlerOverride or handlersById[receipt.ProductId]
	local res = Receipt.process(receipt, {
		inFlight = inFlight,
		pending = pending,
		findPlayer = function(userId: number): Player?
			return Players:GetPlayerByUserId(userId)
		end,
		isLoaded = function(player: Player): boolean
			return Data.isLoaded(player) and Data.get(player) ~= nil
		end,
		isRecorded = function(player: Player, purchaseId: string): boolean
			local data: Types.PlayerData? = Data.get(player)
			return data ~= nil and data.purchases ~= nil and data.purchases[purchaseId] ~= nil
		end,
		hasHandler = productHandler ~= nil,
		commit = function(player: Player, r: any)
			return Receipt.commit(
				Data.update,
				productHandler :: ProductHandler,
				makePurchaseTx,
				player,
				r,
				os.time()
			)
		end,
		save = function(player: Player): boolean
			return Data.saveAsync(player) == true
		end,
	})
	if res.effects then
		Tx.flush(res.effects) -- the grant is saved: exactly once per real grant
		local player = Players:GetPlayerByUserId(receipt.PlayerId)
		if player then
			grantFeedback(player, receipt)
		end
	end
	local quiet = res.reason == "not_in_server" or res.reason == "in_flight" or res.reason == "retry_later"
	if res.decision == "NotProcessedYet" and not quiet then
		warn(
			`[Core.Shop] receipt {receipt.PurchaseId} (product {receipt.ProductId}) not processed: {res.reason}`
				.. (if res.detail then ` ({res.detail})` else "")
		)
	end
	return res
end

local function processReceipt(receipt: Types.ReceiptInfo): Enum.ProductPurchaseDecision
	local res = processWith(receipt, nil)
	return if res.decision == "PurchaseGranted"
		then Enum.ProductPurchaseDecision.PurchaseGranted
		else Enum.ProductPurchaseDecision.NotProcessedYet
end

local function checkPass(player: Player, id: number)
	task.spawn(function()
		if Shop.ownsPass(player, id) then
			firePassOwned(player, id)
		end
	end)
end

local function setupPlayer(player: Player)
	passCache[player] = passCache[player] or {}
	passFired[player] = passFired[player] or {}
end

local function targetPlayer(args: { any }): Player?
	local last = tonumber(args[#args])
	if last then
		local p = Players:GetPlayerByUserId(last)
		if p then
			return p
		end
	end
	return Players:GetPlayers()[1]
end

local function consoleReceipt(...: any): string?
	if not ctx.isStudio then
		return "receipt is Studio-only"
	end
	local args = { ... }
	local name = args[1]
	if type(name) ~= "string" then
		return "usage: receipt <productName> [purchaseId] [userId]"
	end
	local player = targetPlayer(args)
	if player == nil then
		return "no player in server"
	end
	local id = products().devProducts[name] or tonumber(name) or 0
	local handler = handlersById[id] or handlersByName[name]
	if handler == nil then
		return "no handler registered for product " .. name
	end
	local purchaseId = if type(args[2]) == "string" and tonumber(args[2]) ~= player.UserId
		then args[2]
		else "studio-" .. HttpService:GenerateGUID(false)
	local receipt: Types.ReceiptInfo = {
		PlayerId = player.UserId,
		PurchaseId = purchaseId,
		ProductId = id,
		CurrencySpent = 0,
		PlaceIdWherePurchased = game.PlaceId,
	}
	local first = processWith(receipt, handler)
	local second = processWith(receipt, handler)
	return `{purchaseId}: 1st {first.decision} ({first.reason}), 2nd {second.decision} ({second.reason})`
end

function Shop.init(context: any)
	ctx = context
end

function Shop.start()
	MarketplaceService.ProcessReceipt = processReceipt :: any

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, gamePassId: number, wasPurchased: boolean)
			if wasPurchased ~= true or type(gamePassId) ~= "number" then
				return
			end
			local cache = passCache[player]
			if cache == nil then
				return
			end
			cache[gamePassId] = true
			pcall(ctx.net.feedback, player, "toast", "Gamepass unlocked!")
			pcall(ctx.services.Analytics.custom, player, "PassPurchased", 1)
			firePassOwned(player, gamePassId)
		end
	)

	Players.PlayerAdded:Connect(setupPlayer)
	for _, p in Players:GetPlayers() do
		setupPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		passCache[player] = nil
		passFired[player] = nil
		Receipt.forgetPlayer(pending, player.UserId)
	end)

	ctx.services.Data.onLoaded(function(player: Player)
		if player.Parent ~= Players then
			return
		end
		setupPlayer(player)
		for id in passHandlers do
			checkPass(player, id)
		end
	end)

	ctx.console.register(
		"receipt",
		"receipt <productName> [purchaseId] [userId]: simulate ProcessReceipt twice",
		consoleReceipt
	)
end

function Shop.onProduct(product: number | string, handler: ProductHandler)
	assert(type(handler) == "function", "[Core.Shop] onProduct handler must be a function")
	if type(product) == "number" then
		assert(handlersById[product] == nil, "[Core.Shop] product handler already set for " .. product)
		handlersById[product] = handler
		return
	end
	assert(type(product) == "string", "[Core.Shop] product must be an id or a devProducts name")
	local id = products().devProducts[product]
	assert(id ~= nil, "[Core.Shop] unknown product '" .. product .. "' (not in products.devProducts)")
	assert(handlersByName[product] == nil, "[Core.Shop] product handler already set for " .. product)
	handlersByName[product] = handler
	if id == 0 then
		warnOnce("product0:" .. product, "product '" .. product .. "' has id 0 (not created yet)")
		return
	end
	assert(handlersById[id] == nil, "[Core.Shop] product handler already set for " .. id)
	handlersById[id] = handler
end

function Shop.ownsPass(player: Player, pass: number | string): boolean
	local id = passId(pass)
	if id == nil then
		return false
	end
	local cache = passCache[player]
	if cache and cache[id] ~= nil then
		return cache[id]
	end
	local delay = PASS_RETRY_DELAY
	for attempt = 1, PASS_CHECK_ATTEMPTS do
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
		end)
		if ok then
			local current = passCache[player] -- nil when the player left while we yielded
			if current then
				-- keep a `true` set by a purchase that finished while we were yielding
				current[id] = current[id] == true or owns == true
				return current[id]
			end
			return owns == true
		end
		if attempt < PASS_CHECK_ATTEMPTS then
			task.wait(delay)
			delay *= 2
		end
	end
	warn("[Core.Shop] UserOwnsGamePassAsync failed for pass " .. id .. "; treating as not owned for now")
	return false
end

function Shop.onPassOwned(pass: number | string, handler: (player: Player) -> ())
	assert(type(handler) == "function", "[Core.Shop] onPassOwned handler must be a function")
	local id = passId(pass)
	if id == nil then
		return -- unknown / not created yet: never owned (warned once)
	end
	passHandlers[id] = passHandlers[id] or {}
	table.insert(passHandlers[id], handler)
	-- players that finished loading before this handler was registered
	if ctx ~= nil then
		for _, player in Players:GetPlayers() do
			if passFired[player] and ctx.services.Data.isLoaded(player) then
				checkPass(player, id)
			end
		end
	end
end

return Shop
