--!strict
--[[
	Core.Economy. OWNED BY AGENT B (core/b-economy). Public API: Types.EconomyAPI.

	PHASE 0 STUB: naive per-player loop every income.tickSeconds; multiplicative stacking;
	session-only multipliers (persist flag ignored); income sources from displayed/owned items
	are recomputed on every tick (Agent B replaces this with a cached, batched rate).

	Contract details (keep when replacing):
	- Economy owns item income: it derives sources from PlayerData.displayed (income.source =
	  "displayed") or PlayerData.inventory ("owned") using Items.incomeOf. Other services do NOT
	  call addIncomeSource for items; addIncomeSource is for game-defined extra sources.
	- getMultiplier includes rebirth (Rebirth.multiplier), incomeMultiplier upgrades, boosts and
	  the co-play multiplier.
	- Economy replicates "ratePerSec" and "multiplier" via ctx.setReplicated when they change.
	- grant/spend reject non-finite or non-positive amounts and unknown players.
]]

local Players = game:GetService("Players")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local Validate = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Validate"))

local Economy = {}

local ctx: any = nil
local sources: { [Player]: { [string]: number } } = {}
local multipliers: { [Player]: { [string]: Types.MultiplierEntry } } = {}

local function currencyId(currency: string?): string
	return currency or ctx.config.balance.primaryCurrency
end

local function itemIncome(player: Player): number
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if data == nil then
		return 0
	end
	local total = 0
	if ctx.config.balance.income.source == "displayed" then
		for _, uid in data.displayed do
			local instance = data.inventory[uid]
			if instance then
				total += ctx.services.Items.incomeOf(instance)
			end
		end
	else
		for _, instance in data.inventory do
			total += ctx.services.Items.incomeOf(instance)
		end
	end
	return total
end

function Economy.init(context: any)
	ctx = context
end

function Economy.start()
	Players.PlayerRemoving:Connect(function(player)
		sources[player] = nil
		multipliers[player] = nil
	end)
	task.spawn(function()
		while true do
			local dt = ctx.config.balance.income.tickSeconds
			task.wait(dt)
			for _, player in Players:GetPlayers() do
				if ctx.services.Data.isLoaded(player) then
					local rate = Economy.getRate(player)
					ctx.setReplicated(player, "ratePerSec", rate)
					ctx.setReplicated(player, "multiplier", Economy.getMultiplier(player))
					if rate > 0 then
						Economy.grant(player, rate * dt, "income")
					end
				end
			end
		end
	end)
end

function Economy.balance(player: Player, currency: string?): number
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	return if data then (data.currency[currencyId(currency)] or 0) else 0
end

function Economy.grant(player: Player, amount: number, reason: string, currency: string?): boolean
	if not Validate.isPositiveNumber(amount) then
		return false
	end
	local id = currencyId(currency)
	local newBalance = 0
	local ok = ctx.services.Data.update(player, function(data: Types.PlayerData)
		newBalance = (data.currency[id] or 0) + amount
		data.currency[id] = newBalance
	end)
	if ok then
		ctx.signals.CurrencyChanged:Fire(player, id, newBalance, amount, reason)
	end
	return ok
end

function Economy.spend(player: Player, amount: number, reason: string, currency: string?): boolean
	if not Validate.isPositiveNumber(amount) then
		return false
	end
	local id = currencyId(currency)
	if Economy.balance(player, id) < amount then
		return false
	end
	local newBalance = 0
	local ok = ctx.services.Data.update(player, function(data: Types.PlayerData)
		newBalance = (data.currency[id] or 0) - amount
		data.currency[id] = newBalance
	end)
	if ok then
		ctx.signals.CurrencyChanged:Fire(player, id, newBalance, -amount, reason)
	end
	return ok
end

function Economy.addIncomeSource(player: Player, sourceId: string, perSec: number)
	if not Validate.isNonNegativeNumber(perSec) then
		return
	end
	sources[player] = sources[player] or {}
	sources[player][sourceId] = perSec
end

function Economy.removeIncomeSource(player: Player, sourceId: string)
	if sources[player] then
		sources[player][sourceId] = nil
	end
end

function Economy.addMultiplier(
	player: Player,
	id: string,
	mult: number,
	expiresAt: number?,
	_persist: boolean?
)
	if not Validate.isPositiveNumber(mult) then
		return
	end
	multipliers[player] = multipliers[player] or {}
	multipliers[player][id] = { mult = mult, expiresAt = expiresAt }
end

function Economy.removeMultiplier(player: Player, id: string)
	if multipliers[player] then
		multipliers[player][id] = nil
	end
end

function Economy.getMultiplier(player: Player): number
	local total = ctx.services.Rebirth.multiplier(player)
	local now = os.time()
	local list = multipliers[player]
	if list then
		for _, entry in list do
			if entry.expiresAt == nil or entry.expiresAt > now then
				total *= entry.mult
			end
		end
	end
	return total
end

function Economy.getRate(player: Player): number
	local base = itemIncome(player)
	local list = sources[player]
	if list then
		for _, perSec in list do
			base += perSec
		end
	end
	return base * Economy.getMultiplier(player)
end

return Economy
