--!strict
--[[
	The live flag override (module-api.md §23.2, docs/framework/kits/environments.md): reads the
	experience's configs on the server in a background thread after boot and feeds them to the
	flag table (Flags state `setOverride`). Never blocks boot, never errors to callers.

	  FlagOverride.new(opts) -> { start() }
	    opts = { config = GameConfig.flagOverride?, flags = Flags state, services = Services (internal),
	             spawn, delay, now, log, analytics = (event, fields) -> ()? }

	STUB (foundation): `new` returns a handle whose `start` does nothing. The config read, the
	`UpdateAvailable` / `Outdated` refresh, backoff, wrong-type warnings and the refused testOnly
	analytics event are the environments/flags builder's (B2). `FlagOverride.settings(config)` (the
	defaults and the enabled switch) is real.
]]

local FlagOverride = {}

FlagOverride.DEFAULTS = table.freeze({ enabled = false, keyPrefix = "flag_", refreshSeconds = 30 })

function FlagOverride.settings(config: any): { enabled: boolean, keyPrefix: string, refreshSeconds: number }
	local c = if type(config) == "table" then config else {}
	return {
		enabled = c.enabled == true,
		keyPrefix = if type(c.keyPrefix) == "string" and c.keyPrefix ~= ""
			then c.keyPrefix
			else FlagOverride.DEFAULTS.keyPrefix,
		refreshSeconds = if type(c.refreshSeconds) == "number"
			then c.refreshSeconds
			else FlagOverride.DEFAULTS.refreshSeconds,
	}
end

function FlagOverride.new(opts: any): any
	local settings = FlagOverride.settings(opts.config)
	return {
		settings = settings,
		start = function() end, -- STUB (B2)
	}
end

return FlagOverride
