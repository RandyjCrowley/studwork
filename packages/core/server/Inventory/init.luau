--!strict
--[[
	Core.Inventory. OWNED BY AGENT C (core/c-items). Public API: Types.InventoryAPI.

	Items live in PlayerData.inventory (uid -> ItemInstance), written only through Data.update.
	Every mutation fires ItemAdded / ItemRemoved (transfer = ItemRemoved on sender + ItemAdded on
	receiver, same uid).

	add(player, itemId, opts?)  -> new instance, or nil when: item unknown, data not loaded,
		inventory at cap, opts.mutation not in balance.mutations, meta invalid/too big
		(InventoryRules.validateMeta), source not a short string.
	remove(player, uid, reason?) -> removed instance or nil. Clears the item from the plot first
		(Plot.clearDisplay) when it is displayed.
	get / list / count.
	cap(player) = balance.inventory.cap + Σ Upgrades.level(id) * perLevel over upgrades with
		effect "inventoryCap" (pinned contract).
	canTrade(player) = player is in the server and its data is loaded.
	transfer(from, to, uid, reason) -> (ok, reason?) via InventoryRules.transferCheck:
		"not_loaded" | "same_player" | "not_owned" | "restricted" (either side restricted and the
		item source starts with "paid:") | "inventory_full" | "failed". Plot.clearDisplay(from, uid)
		runs first; then the SAME instance moves with no yield between removing it from the sender
		and adding it to the receiver (rolled back to the sender if the receiver write fails).
	Starter items: on Data.onLoaded with stats.sessions == 1 and an empty inventory.
	RequestGift (client): toUserId positive integer in this server, not self; uid an id the sender
		owns; per-player GIFT_COOLDOWN_SEC on top of Net's rate limit.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Core = game:GetService("ReplicatedStorage"):WaitForChild("Core")
local Types = require(Core:WaitForChild("Types"))
local Validate = require(Core:WaitForChild("Validate"))
local InventoryRules = require(script.InventoryRules)

local Inventory = {}

local GIFT_COOLDOWN_SEC = 2 -- anti-spam rail between successful gifts per sender

local ctx: any = nil
local mutationIds: { [string]: boolean } = {}
local lastGiftAt: { [Player]: number } = {}

local function isDisplayed(data: Types.PlayerData, uid: string): boolean
	for _, displayedUid in (data.displayed or {}) :: { [string]: string } do
		if displayedUid == uid then
			return true
		end
	end
	return false
end

-- Plot owns `displayed`; ask it to clear. Guarded so a Plot error can't block inventory changes.
local function clearFromPlot(player: Player, uid: string)
	local data = ctx.services.Data.get(player)
	if data and isDisplayed(data, uid) then
		local ok, err = pcall(ctx.services.Plot.clearDisplay, player, uid)
		if not ok then
			warn("[Core.Inventory] Plot.clearDisplay failed: " .. tostring(err))
		end
	end
end

-- Defensive: drop dangling displayed references inside the same Data.update that removes the item
-- (only matters if Plot.clearDisplay did not clear it).
local function scrubDisplayed(data: Types.PlayerData, uid: string)
	for slotId, displayedUid in (data.displayed or {}) :: { [string]: string } do
		if displayedUid == uid then
			data.displayed[slotId] = nil
		end
	end
end

local function inServer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

function Inventory.init(context: any)
	ctx = context
	for _, m in ctx.config.balance.mutations or {} do
		if type(m) == "table" and type(m.id) == "string" then
			mutationIds[m.id] = true
		end
	end
end

function Inventory.start()
	ctx.services.Data.onLoaded(function(player: Player, data: Types.PlayerData)
		local sessions = if data.stats then data.stats.sessions else nil
		if sessions == 1 and next(data.inventory) == nil then
			for _, itemId in ctx.config.balance.starterItems or {} do
				if Inventory.add(player, itemId, { source = "starter", reason = "starter" }) == nil then
					warn("[Core.Inventory] could not grant starter item " .. tostring(itemId))
				end
			end
		end
	end)

	ctx.net.handle("RequestGift", function(player: Player, toUserId: any, uid: any)
		if not InventoryRules.validGiftTarget(player.UserId, toUserId) or not Validate.isId(uid) then
			return
		end
		local now = os.clock()
		local last = lastGiftAt[player]
		if last and now - last < GIFT_COOLDOWN_SEC then
			return
		end
		local target = Players:GetPlayerByUserId(toUserId)
		if target == nil or target == player or Inventory.get(player, uid) == nil then
			return
		end
		local ok = Inventory.transfer(player, target, uid, "gift")
		if ok then
			lastGiftAt[player] = now
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastGiftAt[player] = nil
	end)
end

function Inventory.cap(player: Player): number
	local balance = ctx.config.balance
	return InventoryRules.capacity(
		balance.inventory.cap,
		balance.upgrades,
		function(upgradeId: string): number
			local ok, level = pcall(ctx.services.Upgrades.level, player, upgradeId)
			return if ok and type(level) == "number" then level else 0
		end
	)
end

function Inventory.count(player: Player): number
	local data = ctx.services.Data.get(player)
	local n = 0
	if data then
		for _ in data.inventory do
			n += 1
		end
	end
	return n
end

function Inventory.add(player: Player, itemId: string, opts: Types.InventoryAddOptions?): Types.ItemInstance?
	if type(itemId) ~= "string" or ctx.services.Items.get(itemId) == nil then
		return nil
	end
	local o: Types.InventoryAddOptions = if type(opts) == "table" then opts else {}
	if o.mutation ~= nil and (type(o.mutation) ~= "string" or not mutationIds[o.mutation]) then
		warn("[Core.Inventory] unknown mutation " .. tostring(o.mutation))
		return nil
	end
	if o.source ~= nil and not Validate.isShortString(o.source, InventoryRules.MAX_SOURCE_LENGTH) then
		return nil
	end
	local metaOk, metaErr = InventoryRules.validateMeta(o.meta)
	if not metaOk then
		warn("[Core.Inventory] rejected meta: " .. tostring(metaErr))
		return nil
	end
	if not ctx.services.Data.isLoaded(player) or Inventory.count(player) >= Inventory.cap(player) then
		return nil
	end
	local instance: Types.ItemInstance = {
		uid = HttpService:GenerateGUID(false),
		itemId = itemId,
		mutation = o.mutation,
		acquiredAt = os.time(),
		source = o.source,
		meta = if o.meta then table.clone(o.meta) else nil,
	}
	local ok = ctx.services.Data.update(player, function(data: Types.PlayerData)
		data.inventory[instance.uid] = instance
	end)
	if not ok then
		return nil
	end
	ctx.signals.ItemAdded:Fire(player, instance)
	return instance
end

function Inventory.remove(player: Player, uid: string, _reason: string?): Types.ItemInstance?
	if type(uid) ~= "string" or Inventory.get(player, uid) == nil then
		return nil
	end
	clearFromPlot(player, uid)
	local removed: Types.ItemInstance? = nil
	ctx.services.Data.update(player, function(data: Types.PlayerData)
		removed = data.inventory[uid]
		data.inventory[uid] = nil
		scrubDisplayed(data, uid)
	end)
	if removed then
		ctx.signals.ItemRemoved:Fire(player, removed)
	end
	return removed
end

function Inventory.get(player: Player, uid: string): Types.ItemInstance?
	if type(uid) ~= "string" then
		return nil
	end
	local data = ctx.services.Data.get(player)
	return if data then data.inventory[uid] else nil
end

function Inventory.list(player: Player): { Types.ItemInstance }
	local data = ctx.services.Data.get(player)
	local list = {}
	if data then
		for _, instance in data.inventory do
			table.insert(list, instance)
		end
	end
	return list
end

function Inventory.canTrade(player: Player): boolean
	return inServer(player) and ctx.services.Data.isLoaded(player)
end

local function check(from: Player, to: Player, uid: string): (boolean, string?)
	local instance = Inventory.get(from, uid)
	local Policy = ctx.services.Policy
	return InventoryRules.transferCheck({
		fromLoaded = Inventory.canTrade(from),
		toLoaded = Inventory.canTrade(to),
		samePlayer = from == to,
		owned = instance ~= nil,
		source = if instance then instance.source else nil,
		fromRestricted = Policy.paidRandomRestricted(from),
		toRestricted = Policy.paidRandomRestricted(to),
		toCount = Inventory.count(to),
		toCap = Inventory.cap(to),
	})
end

function Inventory.transfer(from: Player, to: Player, uid: string, _reason: string): (boolean, string?)
	if type(uid) ~= "string" then
		return false, "not_owned"
	end
	local ok, why = check(from, to, uid)
	if not ok then
		return false, why
	end
	clearFromPlot(from, uid) -- may fire Plot signals; re-check afterwards in case state changed
	ok, why = check(from, to, uid)
	if not ok then
		return false, why
	end

	-- Atomic section: no yields between removing from the sender and adding to the receiver.
	local Data = ctx.services.Data
	local moved: Types.ItemInstance? = nil
	Data.update(from, function(data: Types.PlayerData)
		moved = data.inventory[uid]
		data.inventory[uid] = nil
		scrubDisplayed(data, uid)
	end)
	local instance = moved
	if instance == nil then
		return false, "not_owned"
	end
	local added = Data.update(to, function(data: Types.PlayerData)
		data.inventory[uid] = instance
	end)
	if not added then
		Data.update(from, function(data: Types.PlayerData)
			data.inventory[uid] = instance
		end)
		return false, "failed"
	end
	ctx.signals.ItemRemoved:Fire(from, instance)
	ctx.signals.ItemAdded:Fire(to, instance)
	return true, nil
end

return Inventory
