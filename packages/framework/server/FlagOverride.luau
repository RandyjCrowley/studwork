--!strict
--[[
	The live flag override (module-api.md §23.2, docs/framework/kits/environments.md): reads the
	experience's configs on the server in a background thread after boot and feeds them to the
	flag table (Flags state `setOverride`). Never blocks boot, never errors to callers.

	  FlagOverride.new(opts) -> { settings, start(), stop(), refresh(), reads() }
	    opts = { config = GameConfig.flagOverride?, flags = Flags state, services = Services (internal),
	             spawn, delay, now, log, analytics = (event, fields) -> ()? }
	  FlagOverride.settings(config) -> { enabled, keyPrefix, refreshSeconds }   defaults applied

	start() (run in its own thread by the framework):
	  - off unless flagOverride.enabled;
	  - ConfigService:GetConfigAsync() in pcall; a failure keeps the config values and retries
	    with backoff 5, 10, 20, ... s, capped at refreshSeconds x 4;
	  - for each declared flag with override ~= false, the key <keyPrefix><name>: a boolean is the
	    override, a missing key clears it, any other type is ignored (one warning per key);
	  - snapshot.UpdateAvailable -> snapshot:Refresh(), at most once per refreshSeconds (a later
	    update waits for the rest of the interval), and snapshot.Outdated is polled every
	    refreshSeconds in case an update event was missed;
	  - a failed Refresh keeps the last good values (Roblox's snapshot does the same).
	Only values that changed since the last read are applied, so a Studio console override
	(`flags set`) stays until the experience config for that flag changes. An override that would
	switch a testOnly flag on in live is refused by Flags (warning) and reported here as the
	framework analytics event FlagOverrideRefused { flag } once per refused value.
]]

local FlagOverride = {}

FlagOverride.DEFAULTS = table.freeze({ enabled = false, keyPrefix = "flag_", refreshSeconds = 30 })
FlagOverride.FIRST_RETRY = 5 -- seconds before the first retry of a failed first read (doubles)
FlagOverride.MAX_RETRY_FACTOR = 4 -- retries are capped at refreshSeconds x this

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
	local flags = opts.flags
	local services = opts.services
	local spawn: (any, ...any) -> () = opts.spawn or function(fn: any, ...: any)
		fn(...)
	end
	local delay: (number, () -> ()) -> () = opts.delay or function(_s: number, _fn: () -> ()) end
	local now: () -> number = opts.now or os.time
	local log: (string) -> () = opts.log or function(_m: string) end
	local analytics: ((string, { [string]: any }) -> ())? = opts.analytics

	local snapshot: any = nil
	local applied: { [string]: boolean } = {} -- the last value read per flag (absent = no override)
	local refused: { [string]: boolean } = {} -- the refused value per flag, reported once
	local warnedType: { [string]: boolean } = {}
	local lastRefresh = -math.huge
	local pending = false
	local started = false
	local stopped = false
	local readCount = 0

	local handle: any = { settings = settings }

	local function report(name: string)
		if analytics ~= nil then
			pcall(analytics, "FlagOverrideRefused", { flag = name })
		end
	end

	-- Takes the snapshot's values for every overridable flag; only changes are applied.
	local function apply(snap: any)
		readCount += 1
		for _, name in flags.names() do
			if not flags.overridable(name) then
				continue
			end
			local key = settings.keyPrefix .. name
			local okGet, value = pcall(function()
				return snap:GetValue(key)
			end)
			if not okGet then
				continue -- keep the last value for this key
			end
			local want: boolean? = nil
			if type(value) == "boolean" then
				want = value
				warnedType[key] = nil
			elseif value ~= nil then
				if not warnedType[key] then
					warnedType[key] = true
					log(
						`[StudWork] flag override: experience config '{key}' is a {typeof(value)}, not a boolean; ignored`
					)
				end
			end
			if want == applied[name] then
				continue
			end
			local ok, reason = flags.setOverride(name, want)
			if ok then
				applied[name] = want :: any
				refused[name] = nil
			elseif reason == "test_only" then
				applied[name] = want :: any -- don't retry the same refused value every refresh
				if not refused[name] then
					refused[name] = true
					report(name)
				end
			end
		end
	end

	local function refresh()
		local snap = snapshot
		if snap == nil or stopped then
			return
		end
		lastRefresh = now()
		local ok = pcall(function()
			snap:Refresh()
		end)
		if ok then
			apply(snap)
		else
			log("[StudWork] flag override: refreshing experience configs failed; keeping the last values")
		end
	end

	-- At most one refresh per refreshSeconds; a request inside the interval waits for its end.
	local function requestRefresh()
		if pending or stopped then
			return
		end
		local waitFor = lastRefresh + settings.refreshSeconds - now()
		if waitFor <= 0 then
			refresh()
		else
			pending = true
			delay(waitFor, function()
				pending = false
				refresh()
			end)
		end
	end

	local function poll()
		if stopped then
			return
		end
		local snap = snapshot
		local okRead, outdated = pcall(function()
			return snap.Outdated
		end)
		if okRead and outdated == true then
			requestRefresh()
		end
		delay(settings.refreshSeconds, poll)
	end

	local function firstRead(attempt: number)
		if stopped then
			return
		end
		local ok, snap = pcall(function()
			return services.internal("ConfigService"):GetConfigAsync()
		end)
		if ok and snap ~= nil then
			snapshot = snap
			lastRefresh = now()
			apply(snap)
			pcall(function()
				snap.UpdateAvailable:Connect(function()
					spawn(requestRefresh)
				end)
			end)
			delay(settings.refreshSeconds, poll)
			return
		end
		local waitFor = math.min(
			FlagOverride.FIRST_RETRY * 2 ^ (attempt - 1),
			settings.refreshSeconds * FlagOverride.MAX_RETRY_FACTOR
		)
		log(
			`[StudWork] flag override: reading experience configs failed; flags use config values, retrying in {waitFor}s`
		)
		delay(waitFor, function()
			firstRead(attempt + 1)
		end)
	end

	function handle.start()
		if not settings.enabled or started then
			return
		end
		started = true
		firstRead(1)
	end

	function handle.stop()
		stopped = true
	end

	-- Framework / spec use: refresh now if the interval allows it (same rule as UpdateAvailable).
	function handle.refresh()
		if snapshot ~= nil then
			requestRefresh()
		end
	end

	-- How many times the experience configs were applied (first read + successful refreshes).
	function handle.reads(): number
		return readCount
	end

	return handle
end

return FlagOverride
