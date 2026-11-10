--!strict
--[[
	Schema migration 0 -> 1. Pure.
	Version 0 = a profile saved before versioning existed (no schemaVersion key). Version 1 is the
	first real schema; every missing key is filled afterwards by Sanitize.reconcile, so this only
	normalises shapes that reconcile cannot guess.

	Adding a migration: create NNN_<what>.luau returning { version = N, migrate = fn(old) -> new },
	add it to Schema.MIGRATIONS and bump Schema.CURRENT_VERSION. Never edit a shipped migration.
]]

return {
	version = 1,
	migrate = function(old: { [string]: any }): { [string]: any }
		-- Very early prototypes stored a single number as `coins`; fold it into currency.
		if type(old.coins) == "number" and old.currency == nil then
			old.currency = { coins = old.coins }
		end
		old.coins = nil
		return old
	end,
}
