--!strict
--[[
	Rebirth (economy kit), server part. core-v1.3.0 Phase 1: a real StudWork module. Section
	`rebirth` = { rebirths }; config.Rebirth.rebirth = { baseCost, costGrowth, currency? (default
	Economy's primary), multiplierPerRebirth, keepInventory, keepDisplayed?, resetCurrencies?
	(default { primary }), maxRebirths? } and config.Rebirth.onRebirth (the inventory rules, below).

	api (v1.2): canRebirth(player), rebirth(player) -> boolean, cost(player), multiplier(player)
	  signals.Rebirthed(player, count)
	extensions.resetStep(id, fn(tx, player))   runs inside Rebirth's single transaction, in
	  registration order, BEFORE `rebirths` is incremented (§8; each step writes only its own
	  section through its own ctx.section(tx)). Upgrades resets its levels this way, Plot its
	  displayed slots.
	Client action: rebirth(), limit 0.5/s burst 2 (own Blink event `Rebirth` in Rebirth/net.blink,
	  core-v1.3.1).

	rebirth(): ONE ctx.tx:
	  1. re-checks maxRebirths and the balance (Economy.txApi.balance);
	  2. pays the cost through Economy.txApi.spend when the cost currency is not reset anyway (a
	     paid currency goes through the public ctx.compliance.spendPaid: a rebirth is a non-random good);
	  3. resets every resetCurrencies currency to config.Economy.startingCurrency[id] or 0
	     (Economy.txApi.spend / grant, reason "rebirth");
	  4. unless rebirth.keepInventory, removes the wiped copies with Inventory.txApi.remove
	     (optional Inventory; reason "rebirth"), per onRebirth below;
	  5. runs the reset steps; 6. rebirths += 1.
	Then (after commit) Rebirthed, the Economy rate refresh, a "toast" feedback and analytics.
	CurrencyChanged (reason "rebirth") comes from Economy for each currency that changed.

	Inventory rules on rebirth (config.Rebirth.onRebirth; defaults = the v1.2 rules, Decision 2 /
	review N5). A copy's source tag (`paid:` / `paidcur:`) is derived by Collection and never
	rewritten here, so the trade/policy rules that read it apply whatever is kept.
	  paid = "keep"           Robux-bought copies (source "paid:..."): ALWAYS kept. "keep" is the
	                          only value the schema accepts; no config and no item flag can make
	                          a Robux purchase wipeable.
	  paidCurrency = "wipe"   copies rolled with a compliance.paidCurrencies currency
	                          ("paidcur:..."): "wipe" (default; otherwise spending earned Coins right
	                          before a rebirth would make items rebirth-proof) or "keep" (the copy
	                          keeps its paidcur: tag, so it stays a paid random item: odds shown,
	                          untradeable for restricted players).
	  earned = "wipe"         every other copy: "wipe" (default) or "keep".
	  itemOverrides = true    ItemDef.keepOnRebirth = true keeps a copy, false wipes it; neither
	                          ever overrides paid = "keep". false = ignore the item flags.
	Unknown item ids (no ItemDef) are kept and warned about: never destroy what can't be
	classified.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RebirthMath = require(script.RebirthMath)

local Modules = ReplicatedStorage:WaitForChild("Modules")
local EconomyRef = require(Modules:WaitForChild("Economy"):WaitForChild("module")) :: any
local InventoryRef = require(Modules:WaitForChild("Inventory"):WaitForChild("module")) :: any

local Rebirth = {}

export type Rules = {
	paid: "keep",
	paidCurrency: "wipe" | "keep",
	earned: "wipe" | "keep",
	itemOverrides: boolean,
}

local defaultRules: Rules = {
	paid = "keep",
	paidCurrency = "wipe",
	earned = "wipe",
	itemOverrides = true,
}
Rebirth.DEFAULT_RULES = table.freeze(defaultRules)

local function prefix(source: any, p: string): boolean
	return type(source) == "string" and string.sub(source, 1, #p) == p
end

-- Is this copy kept by a rebirth under `rules`? `def` nil = unknown item (kept). Pure.
function Rebirth.keeps(def: any, instance: any, rules: Rules): boolean
	if def == nil then
		return true -- never destroy data we can't classify
	end
	local source = instance.source
	if prefix(source, "paid:") then
		return true -- Robux copies: always kept (compliance guardrail; not configurable)
	end
	if rules.itemOverrides then
		if def.keepOnRebirth == true then
			return true
		elseif def.keepOnRebirth == false then
			return false
		end
	end
	if prefix(source, "paidcur:") then
		return rules.paidCurrency == "keep"
	end
	return rules.earned == "keep"
end

function Rebirth.new(): any
	local ctx: any = nil
	local created: { [string]: any } = {}
	local resetSteps: { { id: string, fn: (any, any) -> () } } = {}
	local invalidateRate: ((any) -> ())? = nil

	local signals = setmetatable({}, {
		__index = function(_, key: any): any
			return created[key]
		end,
	})

	local function cfg(): any
		return ctx.config.rebirth
	end

	local function rules(): Rules
		local r = ctx.config.onRebirth
		return if type(r) == "table" then r else Rebirth.DEFAULT_RULES
	end

	local function count(player: any): number
		if not ctx.data.isLoaded(player) then
			return 0
		end
		return ctx.data.get(player).rebirths or 0
	end

	-- Economy's primary currency and starting balances (config.Economy, through Economy's api;
	-- Rebirth never reads another module's config).
	local function economyPrimary(): string
		return ctx.deps[EconomyRef].primaryCurrency()
	end

	local api: { [string]: any } = { signals = signals }

	local function costCurrency(): string
		return cfg().currency or economyPrimary()
	end

	function api.cost(player: any): number
		local r = cfg()
		return RebirthMath.cost(r.baseCost, r.costGrowth, count(player))
	end

	function api.multiplier(player: any): number
		return RebirthMath.multiplier(count(player), cfg().multiplierPerRebirth)
	end

	function api.canRebirth(player: any): boolean
		if not ctx.data.isLoaded(player) then
			return false
		end
		local balance = ctx.deps[EconomyRef].balance(player, costCurrency())
		local ok = RebirthMath.check(count(player), balance, cfg())
		return ok
	end

	function api.rebirth(player: any): boolean
		if not ctx.data.isLoaded(player) then
			return false
		end
		local r = cfg()
		local payWith = costCurrency()
		local resets = RebirthMath.resetList(r, economyPrimary())
		local economy = ctx.depsTx[EconomyRef]
		local done = false
		local newCount = 0
		local unknownItems: { string } = {}

		-- a paid currency (GameConfig.compliance.paidCurrencies) is spent through the public
		-- ctx.compliance.spendPaid, any other through Economy (Phase 2 final review 5/7)
		local function spend(tx: any, amount: number, currency: string): boolean
			if ctx.compliance.isPaidCurrency(currency) then
				return (ctx.compliance.spendPaid(tx, currency, amount, "rebirth"))
			end
			return economy.spend(tx, amount, "rebirth", currency)
		end

		local committed = ctx.tx(player, function(tx: any)
			local s = ctx.section(tx)
			local rebirths = s.rebirths or 0
			local ok, _, cost = RebirthMath.check(rebirths, economy.balance(tx, payWith), r)
			if not ok then
				return
			end
			if cost > 0 and not table.find(resets, payWith) then
				assert(spend(tx, cost, payWith), "[Rebirth] cost spend refused after the balance check")
			end
			for _, id in resets do
				local current = economy.balance(tx, id)
				local target = ctx.deps[EconomyRef].startingBalance(id)
				if current > target then
					spend(tx, current - target, id)
				elseif current < target then
					economy.grant(tx, target - current, "rebirth", id)
				end
			end
			if not r.keepInventory and ctx.isEnabled(InventoryRef) then
				local inventory = ctx.depsTx[InventoryRef]
				local ruleSet = rules()
				for _, instance in inventory.list(tx) do
					local def = ctx.gameConfig.items.byId(instance.itemId)
					if def == nil and not table.find(unknownItems, instance.itemId) then
						table.insert(unknownItems, instance.itemId)
					end
					if not Rebirth.keeps(def, instance, ruleSet) then
						inventory.remove(tx, instance.uid, "rebirth")
					end
				end
			end
			for _, step in resetSteps do
				step.fn(tx, player)
			end
			s.rebirths = rebirths + 1
			newCount = s.rebirths
			done = true
		end)
		if not (committed and done) then
			return false
		end
		if #unknownItems > 0 then
			table.sort(unknownItems)
			ctx.log.warn(
				"kept items with unknown ids on rebirth for "
					.. tostring(player.Name)
					.. ": "
					.. table.concat(unknownItems, ", ")
			)
		end
		if invalidateRate then
			(invalidateRate :: any)(player)
		end
		created.Rebirthed:Fire(player, newCount)
		pcall(ctx.analytics.custom, player, "Rebirth", newCount)
		local mult = RebirthMath.multiplier(newCount, r.multiplierPerRebirth)
		ctx.net.feedback(player, "toast", string.format("Rebirth %d! Income x%s", newCount, tostring(mult)))
		return true
	end

	local extensions = {}

	function extensions.resetStep(id: string, fn: (tx: any, player: any) -> ())
		assert(type(id) == "string" and id ~= "", "Rebirth.resetStep(id, fn): id must be a string")
		assert(type(fn) == "function", "Rebirth.resetStep(id, fn): fn must be a function(tx, player)")
		for _, step in resetSteps do
			assert(step.id ~= id, "[Rebirth] reset step already registered: " .. id)
		end
		table.insert(resetSteps, { id = id, fn = fn })
	end

	-- Client action (core-v1.3.1 R19): wire event `Rebirth` in ./net.blink (generated server/Net.luau,
	-- bound by the loader). Limit moved unchanged from the framework's Net.LIMITS.RequestRebirth.
	local actions = {
		rebirth = {
			limit = { rate = 0.5, burst = 2 },
			handler = function(player: any)
				api.rebirth(player)
			end,
		},
	}

	local part: { [string]: any } = { api = api, extensions = extensions, actions = actions }

	function part.init(context: any)
		ctx = context
		created.Rebirthed = ctx.signals.new("Rebirthed")
		invalidateRate = ctx.depsExt[EconomyRef].rateFactor("Rebirth", function(player: any): number
			return api.multiplier(player)
		end)
	end

	return part
end

return Rebirth
