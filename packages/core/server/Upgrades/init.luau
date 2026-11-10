--!strict
--[[
	Core.Upgrades. OWNED BY AGENT B (core/b-economy). Public API: Types.UpgradesAPI.

	PHASE 0 STUB: cost = baseCost * costGrowth ^ level; incomeMultiplier effect applied as a
	session multiplier "upgrade:<id>". Agent B: pure cost math + tests, inventoryCap effect
	(Inventory.cap reads Upgrades.level), resetsOnRebirth, analytics sink events.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Upgrades = {}

local ctx: any = nil

local function applyEffects(player: Player)
	for id, upgrade in ctx.config.balance.upgrades or {} do
		if upgrade.effect == "incomeMultiplier" then
			local level = Upgrades.level(player, id)
			if level > 0 then
				ctx.services.Economy.addMultiplier(player, "upgrade:" .. id, 1 + level * upgrade.perLevel)
			else
				ctx.services.Economy.removeMultiplier(player, "upgrade:" .. id)
			end
		end
	end
end

function Upgrades.init(context: any)
	ctx = context
end

function Upgrades.start()
	ctx.services.Data.onLoaded(function(player: Player)
		applyEffects(player)
	end)
	ctx.signals.Rebirthed:Connect(function(player: Player)
		applyEffects(player)
	end)
	ctx.net.handle("RequestUpgrade", function(player: Player, upgradeId: string)
		Upgrades.purchase(player, upgradeId)
	end)
end

function Upgrades.level(player: Player, upgradeId: string): number
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	return if data then (data.upgrades[upgradeId] or 0) else 0
end

function Upgrades.cost(player: Player, upgradeId: string): number?
	local upgrade = (ctx.config.balance.upgrades or {})[upgradeId]
	if upgrade == nil then
		return nil
	end
	local level = Upgrades.level(player, upgradeId)
	if level >= upgrade.maxLevel then
		return nil
	end
	return math.floor(upgrade.baseCost * upgrade.costGrowth ^ level)
end

function Upgrades.purchase(player: Player, upgradeId: string): (boolean, string?)
	local upgrade = (ctx.config.balance.upgrades or {})[upgradeId]
	if upgrade == nil then
		return false, "unknown_upgrade"
	end
	local cost = Upgrades.cost(player, upgradeId)
	if cost == nil then
		return false, "maxed"
	end
	if not ctx.services.Economy.spend(player, cost, "upgrade:" .. upgradeId, upgrade.currency) then
		return false, "cannot_afford"
	end
	local newLevel = 0
	ctx.services.Data.update(player, function(data: Types.PlayerData)
		newLevel = (data.upgrades[upgradeId] or 0) + 1
		data.upgrades[upgradeId] = newLevel
	end)
	applyEffects(player)
	ctx.signals.UpgradePurchased:Fire(player, upgradeId, newLevel)
	return true, nil
end

return Upgrades
