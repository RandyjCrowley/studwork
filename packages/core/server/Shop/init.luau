--!strict
--[[
	Core.Shop. OWNED BY AGENT E (core/e-meta). Public API: Types.ShopAPI.

	PHASE 0 STUB: sets MarketplaceService.ProcessReceipt; looks up the product handler; records
	PurchaseId in PlayerData.purchases and skips already-recorded receipts. NOT yet safe against
	saves failing (Agent E: record the receipt in profile data, wait for the save to commit, only
	then return PurchaseGranted; NotProcessedYet when the player/data isn't loaded), pass
	ownership cache + PromptGamePassPurchaseFinished, onPassOwned, analytics.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Shop = {}

local ctx: any = nil
local productHandlers: { [number]: (Player, Types.ReceiptInfo) -> boolean } = {}
local passHandlers: { [number]: { (Player) -> () } } = {}

local function resolveId(kind: "passes" | "devProducts", value: number | string): number?
	if type(value) == "number" then
		return value
	end
	return ctx.config.products[kind][value]
end

local function processReceipt(receipt: Types.ReceiptInfo): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if player == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if data == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if data.purchases[receipt.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local handler = productHandlers[receipt.ProductId]
	if handler == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local ok, granted = pcall(handler, player, receipt)
	if not ok or granted ~= true then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	ctx.services.Data.update(player, function(d: Types.PlayerData)
		d.purchases[receipt.PurchaseId] = os.time()
	end)
	ctx.signals.ProductGranted:Fire(player, receipt.ProductId, receipt.PurchaseId)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function Shop.init(context: any)
	ctx = context
end

function Shop.start()
	MarketplaceService.ProcessReceipt = processReceipt :: any
	ctx.services.Data.onLoaded(function(player: Player)
		for passId, list in passHandlers do
			if Shop.ownsPass(player, passId) then
				for _, fn in list do
					task.spawn(fn, player)
				end
			end
		end
	end)
end

function Shop.onProduct(
	product: number | string,
	handler: (player: Player, receipt: Types.ReceiptInfo) -> boolean
)
	local id = resolveId("devProducts", product)
	assert(id ~= nil, "[Core.Shop] unknown product " .. tostring(product))
	productHandlers[id :: number] = handler
end

function Shop.ownsPass(player: Player, pass: number | string): boolean
	local id = resolveId("passes", pass)
	if id == nil or id == 0 then
		return false
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id :: number)
	end)
	return ok and owns == true
end

function Shop.onPassOwned(pass: number | string, handler: (player: Player) -> ())
	local id = resolveId("passes", pass)
	assert(id ~= nil, "[Core.Shop] unknown pass " .. tostring(pass))
	passHandlers[id :: number] = passHandlers[id :: number] or {}
	table.insert(passHandlers[id :: number], handler)
end

return Shop
