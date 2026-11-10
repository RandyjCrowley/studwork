--!strict
--[[
	Core.Upgrades. OWNED BY AGENT B (core/b-economy). Public API: Types.UpgradesAPI.

	- Levels live in PlayerData.upgrades (upgradeId -> level). Config: balance.upgrades[id]
	  (baseCost, costGrowth, currency (default primary), maxLevel, effect, perLevel, resetsOnRebirth).
	- cost(level) = floor(baseCost * costGrowth ^ level); nil when maxed or unknown.
	- Effects: "incomeMultiplier" is read by Economy from the saved level (1 + level * perLevel);
	  "inventoryCap" is read by Inventory via Upgrades.level; "custom" = level only (game reads it).
	- purchase validates the id against config, spends through Economy (one atomic check+deduct),
	  then bumps the level in the same server frame (no yield in between), fires UpgradePurchased.
	- Rebirth resets levels whose resetsOnRebirth ~= false (done inside Rebirth's Data.update).
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local Validate = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Validate"))
local UpgradeMath = require(script.UpgradeMath)

local Upgrades = {}

local ctx: any = nil

local function configOf(upgradeId: any): Types.UpgradeConfig?
	if not Validate.isId(upgradeId) then
		return nil
	end
	local list = ctx.config.balance.upgrades
	return if list then list[upgradeId] else nil
end

function Upgrades.init(context: any)
	ctx = context
end

function Upgrades.start()
	ctx.net.handle("RequestUpgrade", function(player: Player, upgradeId: any)
		if configOf(upgradeId) == nil then
			return -- unknown / malformed id from the client
		end
		Upgrades.purchase(player, upgradeId)
	end)
end

function Upgrades.level(player: Player, upgradeId: string): number
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	return if data then (data.upgrades[upgradeId] or 0) else 0
end

function Upgrades.cost(player: Player, upgradeId: string): number?
	local upgrade = configOf(upgradeId)
	if upgrade == nil then
		return nil
	end
	return UpgradeMath.cost(
		upgrade.baseCost,
		upgrade.costGrowth,
		Upgrades.level(player, upgradeId),
		upgrade.maxLevel
	)
end

function Upgrades.purchase(player: Player, upgradeId: string): (boolean, string?)
	local upgrade = configOf(upgradeId)
	if upgrade == nil then
		return false, "unknown_upgrade"
	end
	if not ctx.services.Data.isLoaded(player) then
		return false, "not_loaded"
	end
	local level = Upgrades.level(player, upgradeId)
	local cost = UpgradeMath.cost(upgrade.baseCost, upgrade.costGrowth, level, upgrade.maxLevel)
	if cost == nil then
		return false, "maxed"
	end
	local reason = "upgrade:" .. upgradeId
	if cost > 0 and not ctx.services.Economy.spend(player, cost, reason, upgrade.currency) then
		return false, "cannot_afford"
	end
	local newLevel = level
	local ok = ctx.services.Data.update(player, function(data: Types.PlayerData)
		newLevel = (data.upgrades[upgradeId] or 0) + 1
		data.upgrades[upgradeId] = newLevel
	end)
	if not ok then
		if cost > 0 then
			ctx.services.Economy.grant(player, cost, "refund:" .. upgradeId, upgrade.currency)
		end
		return false, "not_loaded"
	end
	ctx.signals.UpgradePurchased:Fire(player, upgradeId, newLevel)
	return true, nil
end

return Upgrades
