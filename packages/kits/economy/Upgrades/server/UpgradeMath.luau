--!strict
--[[
	Pure upgrade math (zero Roblox dependencies). Tested by UpgradeMath.spec.

	cost(baseCost, costGrowth, level, maxLevel) = floor(baseCost * costGrowth ^ level), or nil when
	level >= maxLevel or the result is not a finite positive-or-zero number.
	incomeFactor(level, perLevel) = 1 + level * perLevel.
	capBonus(upgrades, levels) = Σ level * perLevel over effect == "inventoryCap".
]]

local UpgradeMath = {}

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function UpgradeMath.cost(baseCost: number, costGrowth: number, level: number, maxLevel: number): number?
	if level >= maxLevel then
		return nil
	end
	local c = math.floor(baseCost * costGrowth ^ level)
	if not isFinite(c) or c < 0 then
		return nil
	end
	return c
end

function UpgradeMath.incomeFactor(level: number, perLevel: number): number
	return 1 + level * perLevel
end

function UpgradeMath.capBonus(
	upgrades: { [string]: { effect: string, perLevel: number } }?,
	levels: { [string]: number }
): number
	local total = 0
	if upgrades == nil then
		return 0
	end
	for id, upgrade in upgrades do
		if upgrade.effect == "inventoryCap" then
			total += (levels[id] or 0) * upgrade.perLevel
		end
	end
	return total
end

-- Levels that survive a rebirth: entries whose config says resetsOnRebirth == false, plus ids
-- no longer in the config (left untouched).
function UpgradeMath.afterRebirth(
	upgrades: { [string]: { resetsOnRebirth: boolean? } }?,
	levels: { [string]: number }
): { [string]: number }
	local out = {}
	for id, level in levels do
		local upgrade = if upgrades then upgrades[id] else nil
		if upgrade == nil or upgrade.resetsOnRebirth == false then
			out[id] = level
		end
	end
	return out
end

return UpgradeMath
