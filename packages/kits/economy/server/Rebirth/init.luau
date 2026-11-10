--!strict
--[[
	Core.Rebirth. OWNED BY AGENT B (core/b-economy). Public API: Types.RebirthAPI.

	Config: balance.rebirth (baseCost, costGrowth, currency (default primary), multiplierPerRebirth,
	keepInventory, keepDisplayed, resetCurrencies (default { primary }), maxRebirths).
	- cost = floor(baseCost * costGrowth ^ rebirths); multiplier = 1 + rebirths * multiplierPerRebirth.
	- rebirth(): ONE Data.update re-checks max + balance, pays the cost (if the cost currency is not
	  in resetCurrencies), resets resetCurrencies to balance.startingCurrency[id] or 0, resets
	  keepInventory = false wipes inventory copies per RebirthMath.keptInventory (paid copies kept
	  by default, ItemDef.keepOnRebirth overrides, unknown ids kept + warned), runs registered
	  reset steps (Upgrades, Plot reset their own sections), increments rebirths. Rebirth itself
	  writes only currency, inventory and rebirths. Then fires CurrencyChanged (reason
	  "rebirth") per changed currency and Rebirthed (listeners re-read everything; no per-item
	  ItemRemoved is fired, per the pinned contract), a "toast" feedback and analytics.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local RebirthMath = require(script.RebirthMath)

local Rebirth = {}

local ctx: any = nil
-- Reset steps other modules register (Context.RebirthInternal.addResetStep), run in
-- registration order inside the rebirth Data.update. M7: Upgrades resets its own levels and
-- Plot its own displayed slots; Rebirth never writes their sections.
local resetSteps: { { id: string, fn: (Types.PlayerData, Player) -> () } } = {}

function Rebirth.addResetStep(id: string, fn: (data: Types.PlayerData, player: Player) -> ())
	for _, step in resetSteps do
		assert(step.id ~= id, "[Core.Rebirth] reset step already registered: " .. id)
	end
	table.insert(resetSteps, { id = id, fn = fn })
end

local function count(player: Player): number
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	return if data then data.rebirths else 0
end

local function costCurrency(): string
	local r = ctx.config.balance.rebirth
	return r.currency or ctx.config.balance.primaryCurrency
end

function Rebirth.init(context: any)
	ctx = context
end

function Rebirth.start()
	ctx.net.handle("RequestRebirth", function(player: Player)
		Rebirth.rebirth(player)
	end)
end

function Rebirth.cost(player: Player): number
	local r = ctx.config.balance.rebirth
	return RebirthMath.cost(r.baseCost, r.costGrowth, count(player))
end

function Rebirth.multiplier(player: Player): number
	return RebirthMath.multiplier(count(player), ctx.config.balance.rebirth.multiplierPerRebirth)
end

function Rebirth.canRebirth(player: Player): boolean
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if data == nil then
		return false
	end
	local ok =
		RebirthMath.check(data.rebirths, data.currency[costCurrency()] or 0, ctx.config.balance.rebirth)
	return ok
end

function Rebirth.rebirth(player: Player): boolean
	if not ctx.services.Data.isLoaded(player) then
		return false
	end
	local balance = ctx.config.balance
	local r = balance.rebirth
	local payWith = costCurrency()
	local resets = RebirthMath.resetList(r, balance.primaryCurrency)
	local starting = balance.startingCurrency or {}

	local done = false
	local newCount = 0
	local paid = 0
	local changes: { { id: string, newBalance: number, delta: number } } = {}
	local unknownItems: { string } = {}

	ctx.services.Data.update(player, function(data: Types.PlayerData)
		local ok, _, cost = RebirthMath.check(data.rebirths, data.currency[payWith] or 0, r)
		if not ok then
			return
		end
		done = true
		paid = cost
		local before = table.clone(data.currency)
		if not table.find(resets, payWith) then
			data.currency[payWith] = (data.currency[payWith] or 0) - cost
		end
		for _, id in resets do
			data.currency[id] = starting[id] or 0
		end
		for id, value in data.currency do
			local old = before[id] or 0
			if value ~= old then
				table.insert(changes, { id = id, newBalance = value, delta = value - old })
			end
		end
		if not r.keepInventory and ctx.isEnabled("Inventory") then
			-- Decision 2: keep Robux-bought copies (ItemDef.keepOnRebirth). Without the Items
			-- module nothing can be classified, so everything is kept.
			local getDef = if ctx.isEnabled("Items")
				then function(itemId: string): Types.ItemDef?
					return ctx.services.Items.get(itemId)
				end
				else function(_itemId: string): Types.ItemDef?
					return nil
				end
			local kept, unknown = RebirthMath.keptInventory(data.inventory :: any, getDef)
			data.inventory = kept :: any -- same instance tables, filtered
			unknownItems = unknown
		end
		for _, step in resetSteps do
			step.fn(data, player)
		end
		data.rebirths += 1
		newCount = data.rebirths
	end)
	if not done then
		return false
	end
	if #unknownItems > 0 then
		warn(
			"[Core.Rebirth] kept items with unknown ids on rebirth for "
				.. player.Name
				.. ": "
				.. table.concat(unknownItems, ", ")
		)
	end

	for _, c in changes do
		ctx.signals.CurrencyChanged:Fire(player, c.id, c.newBalance, c.delta, "rebirth")
	end
	ctx.signals.Rebirthed:Fire(player, newCount)

	local analytics = ctx.services.Analytics
	if analytics then
		if paid > 0 then
			pcall(analytics.economy, player, "Sink", payWith, paid, "rebirth", tostring(newCount))
		end
		pcall(analytics.custom, player, "Rebirth", newCount)
	end
	local mult = RebirthMath.multiplier(newCount, r.multiplierPerRebirth)
	ctx.net.feedback(player, "toast", string.format("Rebirth %d! Income x%s", newCount, tostring(mult)))
	return true
end

return Rebirth
