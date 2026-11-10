--!strict
--[[
	Core.Inventory. OWNED BY AGENT C (core/c-items). Public API: Types.InventoryAPI.

	PHASE 0 STUB: add/remove/list through Core.Data with a cap; grants starter items on first
	join; basic transfer. Agent C adds: cap from config + inventoryCap upgrades, trading policy
	checks (restricted players can't trade items from paid random sources), RequestGift handler
	validation, analytics, tests.
]]

local HttpService = game:GetService("HttpService")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Inventory = {}

local ctx: any = nil

function Inventory.init(context: any)
	ctx = context
end

function Inventory.start()
	ctx.services.Data.onLoaded(function(player: Player, data: Types.PlayerData)
		if (data.stats.sessions or 0) == 1 and next(data.inventory) == nil then
			for _, itemId in ctx.config.balance.starterItems or {} do
				Inventory.add(player, itemId, { source = "starter" })
			end
		end
	end)
	ctx.net.handle("RequestGift", function(player: Player, toUserId: number, uid: string)
		local target = game:GetService("Players"):GetPlayerByUserId(toUserId)
		if target == nil or target == player then
			return
		end
		Inventory.transfer(player, target, uid, "gift")
	end)
end

function Inventory.cap(_player: Player): number
	return ctx.config.balance.inventory.cap
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
	if ctx.services.Items.get(itemId) == nil then
		return nil
	end
	if Inventory.count(player) >= Inventory.cap(player) then
		return nil
	end
	local o: Types.InventoryAddOptions = opts or {}
	local instance: Types.ItemInstance = {
		uid = HttpService:GenerateGUID(false),
		itemId = itemId,
		mutation = o.mutation,
		acquiredAt = os.time(),
		source = o.source,
		meta = o.meta,
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
	local removed: Types.ItemInstance? = nil
	ctx.services.Data.update(player, function(data: Types.PlayerData)
		removed = data.inventory[uid]
		data.inventory[uid] = nil
	end)
	if removed then
		ctx.signals.ItemRemoved:Fire(player, removed)
	end
	return removed
end

function Inventory.get(player: Player, uid: string): Types.ItemInstance?
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
	return ctx.services.Data.isLoaded(player)
end

function Inventory.transfer(from: Player, to: Player, uid: string, reason: string): (boolean, string?)
	if not (Inventory.canTrade(from) and Inventory.canTrade(to)) then
		return false, "not_allowed"
	end
	local instance = Inventory.get(from, uid)
	if instance == nil then
		return false, "not_owned"
	end
	if Inventory.count(to) >= Inventory.cap(to) then
		return false, "inventory_full"
	end
	ctx.services.Plot.clearDisplay(from, uid)
	Inventory.remove(from, uid, reason)
	ctx.services.Data.update(to, function(data: Types.PlayerData)
		data.inventory[uid] = instance
	end)
	ctx.signals.ItemAdded:Fire(to, instance)
	return true, nil
end

return Inventory
