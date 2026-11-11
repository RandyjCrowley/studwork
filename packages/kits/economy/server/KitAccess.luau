--!strict
--[[
	Economy-kit-private access token (core-v1.3.0 Phase 1). NOT public API: only the economy kit's
	own server parts (Upgrades, Rebirth, and Economy's Compliance spender) require this file.

	Economy.txApi.spend(tx, amount, reason, currency?, token?) refuses a currency listed in
	GameConfig.compliance.paidCurrencies ("spend a paid currency only through
	compliance.spendForRoll", module-api.md §14 C3) unless `token` is KitAccess.TOKEN. The kit
	uses it for its NON-RANDOM sinks priced in a paid currency (an upgrade level, a rebirth), which
	v1.2 allowed and every shipped game relies on (Coins is both the primary and a Robux-buyable
	currency). Nothing random can be bought this way: a random outcome only comes from
	compliance.roll / spendForRoll, which this token doesn't touch. Code outside the kit can't
	import this file (kits import only StudWork, ctx and their own kit; Phase 2 lint rule).
]]

local KitAccess = {}

KitAccess.TOKEN = table.freeze({}) :: any

return table.freeze(KitAccess)
