--!strict
--[[
	Upgrades (economy kit), server part. v1.3.0: a real StudWork module. Section
	`upgrades` = { upgrades = { [upgradeId]: level } }; config.Upgrades.upgrades[id] = { baseCost,
	costGrowth, currency? (default Economy's primary), maxLevel, effect, perLevel,
	resetsOnRebirth? }.

	api (v1.2): level(player, id) -> number, cost(player, id) -> number?,
	  purchase(player, id) -> (ok, reason?)   reasons "unknown_upgrade" | "not_loaded" | "maxed" |
	                                          "cannot_afford"
	  signals.UpgradePurchased(player, upgradeId, level)
	Client action: upgrade(upgradeId), limit 6/s burst 12 (own Blink event `Upgrade` in
	  Upgrades/net.blink, core-v1.3.1; StudWork.use(Upgrades).actions.upgrade(id) on the client).

	- cost(level) = floor(baseCost * costGrowth ^ level); nil when maxed or unknown.
	- purchase is ONE transaction: re-reads the level, pays through Economy.txApi.spend, or
	  through the public ctx.compliance.spendPaid when the currency is a paid one (an upgrade is a
	  non-random good; v1.3.0 any module can do the same) and bumps the
	  level, so the spend and the level commit together (v1.2 spent, then wrote, then refunded on
	  failure).
	- Effects: "incomeMultiplier" -> an Economy rateFactor (1 + level * perLevel per upgrade);
	  "inventoryCap" -> read by Inventory through Upgrades.level; "custom" -> the game reads level.
	- Rebirth (optional): a resetStep resets every level whose resetsOnRebirth ~= false, inside
	  Rebirth's transaction (M7: Upgrades writes only its own section).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UpgradeMath = require(script.UpgradeMath)

local Modules = ReplicatedStorage:WaitForChild("Modules")
local EconomyRef = require(Modules:WaitForChild("Economy"):WaitForChild("module")) :: any
local RebirthRef = require(Modules:WaitForChild("Rebirth"):WaitForChild("module")) :: any
local InventoryRef =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Inventory"):WaitForChild("module")) :: any

local MAX_ID_LENGTH = 64

local Upgrades = {}

local function isId(v: any): boolean
	return type(v) == "string" and #v > 0 and #v <= MAX_ID_LENGTH
end

function Upgrades.new(): any
	local ctx: any = nil
	local created: { [string]: any } = {}
	local invalidateRate: ((any) -> ())? = nil

	local signals = setmetatable({}, {
		__index = function(_, key: any): any
			return created[key]
		end,
	})

	local function configOf(upgradeId: any): any
		if not isId(upgradeId) then
			return nil
		end
		local list = ctx.config.upgrades
		return if type(list) == "table" then list[upgradeId] else nil
	end

	local function levels(player: any): { [string]: number }
		if not ctx.data.isLoaded(player) then
			return {}
		end
		local s = ctx.data.get(player)
		return if type(s.upgrades) == "table" then s.upgrades else {}
	end

	local function refreshRate(player: any)
		if invalidateRate then
			(invalidateRate :: any)(player)
		end
	end

	local api: { [string]: any } = { signals = signals }

	function api.level(player: any, upgradeId: string): number
		return levels(player)[upgradeId] or 0
	end

	function api.cost(player: any, upgradeId: string): number?
		local upgrade = configOf(upgradeId)
		if upgrade == nil then
			return nil
		end
		return UpgradeMath.cost(
			upgrade.baseCost,
			upgrade.costGrowth,
			api.level(player, upgradeId),
			upgrade.maxLevel
		)
	end

	function api.purchase(player: any, upgradeId: string): (boolean, string?)
		local upgrade = configOf(upgradeId)
		if upgrade == nil then
			return false, "unknown_upgrade"
		end
		if not ctx.data.isLoaded(player) then
			return false, "not_loaded"
		end
		local failure: string? = nil
		local newLevel = 0
		local committed = ctx.tx(player, function(tx: any)
			local s = ctx.section(tx)
			if type(s.upgrades) ~= "table" then
				s.upgrades = {}
			end
			local level = s.upgrades[upgradeId] or 0
			local cost = UpgradeMath.cost(upgrade.baseCost, upgrade.costGrowth, level, upgrade.maxLevel)
			if cost == nil then
				failure = "maxed"
				return
			end
			local currency: string = upgrade.currency or ctx.deps[EconomyRef].primaryCurrency()
			local reason = "upgrade:" .. upgradeId
			local paid = cost > 0
				and if ctx.compliance.isPaidCurrency(currency)
					then ctx.compliance.spendPaid(tx, currency, cost, reason)
					else ctx.depsTx[EconomyRef].spend(tx, cost, reason, currency)
			if cost > 0 and not paid then
				failure = "cannot_afford"
				return
			end
			newLevel = level + 1
			s.upgrades[upgradeId] = newLevel
			tx.after(function()
				refreshRate(player)
				created.UpgradePurchased:Fire(player, upgradeId, newLevel)
			end)
		end)
		if failure ~= nil then
			return false, failure
		end
		if not committed then
			return false, "not_loaded"
		end
		return true, nil
	end

	-- Client action (core-v1.3.1 R19): wire event `Upgrade` in ./net.blink (generated server/Net.luau,
	-- bound by the loader). Limit moved unchanged from the framework's Net.LIMITS.RequestUpgrade.
	local actions = {
		upgrade = {
			limit = { rate = 6, burst = 12 },
			handler = function(player: any, upgradeId: any)
				if configOf(upgradeId) == nil then
					return -- unknown / malformed id from the client
				end
				api.purchase(player, upgradeId)
			end,
		},
	}

	local part: { [string]: any } = { api = api, actions = actions }

	function part.init(context: any)
		ctx = context
		created.UpgradePurchased = ctx.signals.new("UpgradePurchased")
		-- "incomeMultiplier" upgrades: one factor per upgrade with a level (v1.2 RateMath order)
		invalidateRate = ctx.depsExt[EconomyRef].rateFactor("Upgrades", function(player: any): { number }
			local out = {}
			local list = ctx.config.upgrades
			if type(list) ~= "table" then
				return out
			end
			local current = levels(player)
			for id, upgrade in list do
				if upgrade.effect == "incomeMultiplier" then
					local level = current[id] or 0
					if level > 0 then
						table.insert(out, UpgradeMath.incomeFactor(level, upgrade.perLevel))
					end
				end
			end
			return out
		end)
		-- "inventoryCap" upgrades: Inventory.cap = base + Σ capBonus (v1.3.0 integration glue;
		-- replaces the Collection compat adapter's shim over the bridged Upgrades)
		if ctx.isEnabled(InventoryRef) then
			ctx.depsExt[InventoryRef].capBonus("Upgrades", function(player: any): number
				return UpgradeMath.capBonus(ctx.config.upgrades, levels(player))
			end)
		end
		if ctx.isEnabled(RebirthRef) then
			ctx.depsExt[RebirthRef].resetStep("Upgrades", function(tx: any, _player: any)
				local s = ctx.section(tx)
				s.upgrades = UpgradeMath.afterRebirth(ctx.config.upgrades, s.upgrades or {})
			end)
		end
	end

	return part
end

return Upgrades
