--!strict
--[[
	Pure rebirth math (zero Roblox dependencies). Tested by RebirthMath.spec.

	cost(baseCost, costGrowth, rebirths) = floor(baseCost * costGrowth ^ rebirths)
	multiplier(rebirths, perRebirth) = 1 + rebirths * perRebirth
	check(rebirths, balance, cfg) -> (ok, reason?, cost): ordered reasons "maxed", "cannot_afford".
	resetList(cfg, primary) -> currencies to reset (default { primary }).
	Which copies survive a rebirth is decided by Rebirth.keeps (init.luau, the `inventory` rules):
	Robux copies (paid:) are always kept.
]]

local RebirthMath = {}

export type Cfg = {
	baseCost: number,
	costGrowth: number,
	multiplierPerRebirth: number,
	maxRebirths: number?,
	resetCurrencies: { string }?,
}

function RebirthMath.cost(baseCost: number, costGrowth: number, rebirths: number): number
	return math.floor(baseCost * costGrowth ^ rebirths)
end

function RebirthMath.multiplier(rebirths: number, perRebirth: number): number
	return 1 + rebirths * perRebirth
end

function RebirthMath.check(rebirths: number, balance: number, cfg: Cfg): (boolean, string?, number)
	local cost = RebirthMath.cost(cfg.baseCost, cfg.costGrowth, rebirths)
	if cfg.maxRebirths ~= nil and rebirths >= cfg.maxRebirths then
		return false, "maxed", cost
	end
	if cost ~= cost or cost == math.huge or balance < cost then
		return false, "cannot_afford", cost
	end
	return true, nil, cost
end

function RebirthMath.resetList(cfg: Cfg, primary: string): { string }
	return cfg.resetCurrencies or { primary }
end

return RebirthMath
