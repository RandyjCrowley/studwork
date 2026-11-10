--!strict
--[[
	Core.Rebirth. OWNED BY AGENT B (core/b-economy). Public API: Types.RebirthAPI.

	PHASE 0 STUB: cost = baseCost * costGrowth ^ rebirths; resets primary currency (and
	inventory/displayed unless kept) and upgrades. Agent B: pure curve + tests, resetCurrencies,
	maxRebirths, keepDisplayed, upgrade resetsOnRebirth, analytics, feedback.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Rebirth = {}

local ctx: any = nil

function Rebirth.init(context: any)
	ctx = context
end

function Rebirth.start()
	ctx.net.handle("RequestRebirth", function(player: Player)
		Rebirth.rebirth(player)
	end)
end

local function count(player: Player): number
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	return if data then data.rebirths else 0
end

function Rebirth.cost(player: Player): number
	local r = ctx.config.balance.rebirth
	return math.floor(r.baseCost * r.costGrowth ^ count(player))
end

function Rebirth.multiplier(player: Player): number
	return 1 + count(player) * ctx.config.balance.rebirth.multiplierPerRebirth
end

function Rebirth.canRebirth(player: Player): boolean
	local r = ctx.config.balance.rebirth
	if not ctx.services.Data.isLoaded(player) then
		return false
	end
	if r.maxRebirths and count(player) >= r.maxRebirths then
		return false
	end
	return ctx.services.Economy.balance(player, r.currency) >= Rebirth.cost(player)
end

function Rebirth.rebirth(player: Player): boolean
	if not Rebirth.canRebirth(player) then
		return false
	end
	local r = ctx.config.balance.rebirth
	local newCount = 0
	ctx.services.Data.update(player, function(data: Types.PlayerData)
		data.rebirths += 1
		newCount = data.rebirths
		data.currency[r.currency or ctx.config.balance.primaryCurrency] = 0
		data.upgrades = {}
		if not r.keepInventory then
			data.inventory = {}
			data.displayed = {}
		end
	end)
	ctx.signals.Rebirthed:Fire(player, newCount)
	return true
end

return Rebirth
