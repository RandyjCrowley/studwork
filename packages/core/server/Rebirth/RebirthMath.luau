--!strict
--[[
	Pure rebirth math (zero Roblox dependencies). Tested by RebirthMath.spec.

	cost(baseCost, costGrowth, rebirths) = floor(baseCost * costGrowth ^ rebirths)
	multiplier(rebirths, perRebirth) = 1 + rebirths * perRebirth
	check(rebirths, balance, cfg) -> (ok, reason?, cost): ordered reasons "maxed", "cannot_afford".
	resetList(cfg, primary) -> currencies to reset (default { primary }).
	keptInventory(inventory, getDef) -> (kept, unknownItemIds): the inventory after a rebirth with
		keepInventory = false (Decision 2). A copy is kept when def.keepOnRebirth == true, or when
		keepOnRebirth == nil and instance.source starts with "paid:"; wiped when keepOnRebirth ==
		false or the copy isn't paid. Unknown item ids (getDef -> nil) are kept and reported.
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

export type DefLike = { keepOnRebirth: boolean? }
export type InstanceLike = { itemId: string, source: string? }

function RebirthMath.keepsOnRebirth(def: DefLike?, instance: InstanceLike): boolean
	if def == nil then
		return true -- never destroy data we can't classify
	end
	if def.keepOnRebirth == true then
		return true
	elseif def.keepOnRebirth == false then
		return false
	end
	local source = instance.source
	return type(source) == "string" and string.sub(source, 1, 5) == "paid:"
end

function RebirthMath.keptInventory(
	inventory: { [string]: InstanceLike },
	getDef: (itemId: string) -> DefLike?
): ({ [string]: InstanceLike }, { string })
	local kept: { [string]: InstanceLike } = {}
	local unknown: { string } = {}
	for uid, instance in inventory do
		local def = getDef(instance.itemId)
		if def == nil and not table.find(unknown, instance.itemId) then
			table.insert(unknown, instance.itemId)
		end
		if RebirthMath.keepsOnRebirth(def, instance) then
			kept[uid] = instance
		end
	end
	table.sort(unknown)
	return kept, unknown
end

return RebirthMath
