--!strict
--[[
	`ctx.data.ordered(name)` (module-api.md §23.3): one OrderedDataStore per (module, name), store
	name `SW/<Module>/<name>` (`_Studio` suffix in Studio), behind the framework's request budget.

	  OrderedStore.new(opts) -> { forModule(moduleName, assertUsable?) -> (name) -> OrderedStore }
	    opts = { backend = (storeName) -> backend, budget = StoreBudget?, isStudio, now,
	             wait = (s) -> ()?, log }
	  OrderedStore.isExperienceThrottle(err) -> boolean

	backend (platform.stores.ordered(storeName); may raise a code string on failure):
	  get(key) -> number?                      set(key, value)
	  increment(key, delta) -> number          update(key, fn(old) -> number?) -> number?
	  remove(key)                              top(count, order, min?, max?) -> { { key, value } }
	  requestBudget(kind) -> number?           (optional) this server's remaining budget for the
	                                           call's request type (live: GetRequestBudgetForRequestType)

	Caller errors (raised): a name or key that is too long, a value that isn't a finite integer
	(also one returned by an `update` fn), a bad `count` or `order`, an error inside an `update` fn.
	Platform failures never raise: (false, "budget" | "failed").

	Per call:
	  - the module's experience back-off: while it runs, every ordered store of the module returns
	    (false, "budget") without calling Roblox;
	  - this server's budget for the request type (StoreBudget.allowOrdered: orderedReserve, and
	    the platform's remaining budget when the backend reports one) -> (false, "budget");
	  - a throttled or failed call is retried twice, after RETRY_WAITS = 1, 2 s (each try checks
	    the budget again), then (false, "failed") and one warning per store per minute;
	  - `increment` is never retried: it may have committed;
	  - an experience-level throttle (EXPERIENCE_THROTTLE) starts the module's back-off: 30 s,
	    doubling to 5 min while throttles keep coming, reset by the next success. The call that hit
	    it returns (false, "budget").
]]

local OrderedStore = {}

OrderedStore.MAX_NAME = 50
OrderedStore.MAX_KEY = 50
OrderedStore.MAX_COUNT = 100
OrderedStore.RETRY_WAITS = table.freeze({ 1, 2 })
OrderedStore.BACKOFF_START = 30
OrderedStore.BACKOFF_MAX = 300
OrderedStore.WARN_SECONDS = 60
-- error text of an experience-level (universe) throttle, not this server's own budget: Roblox
-- answers HTTP 429 from the service once the experience-wide ordered limits are used up
OrderedStore.EXPERIENCE_THROTTLE = table.freeze({ "HTTP 429", "Too Many Requests", "TooManyRequests" })

local function isInteger(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v % 1 == 0
end

function OrderedStore.isExperienceThrottle(err: any): boolean
	local text = tostring(err)
	for _, pattern in OrderedStore.EXPERIENCE_THROTTLE do
		if string.find(text, pattern, 1, true) then
			return true
		end
	end
	return false
end

function OrderedStore.storeName(moduleName: string, name: string, isStudio: boolean?): string
	return `SW/{moduleName}/{name}` .. (if isStudio then "_Studio" else "")
end

function OrderedStore.new(opts: any): any
	local backendFor: (string) -> any = opts.backend
	local budget = opts.budget
	local log: (string) -> () = opts.log or function(_m: string) end
	local wait: (number) -> () = opts.wait or function(_s: number) end
	local now: () -> number = opts.now or os.time
	local self: any = {}
	-- per module: the experience back-off { untilAt, level }
	local backoff: { [string]: { untilAt: number, level: number } } = {}
	local lastWarn: { [string]: number } = {}

	local function backoffOf(moduleName: string): { untilAt: number, level: number }
		local b = backoff[moduleName]
		if b == nil then
			b = { untilAt = -math.huge, level = 0 }
			backoff[moduleName] = b
		end
		return b
	end

	-- test and console surface: seconds left on a module's back-off (0 when none)
	function self.backoffSeconds(moduleName: string): number
		local b = backoff[moduleName]
		if b == nil then
			return 0
		end
		return math.max(0, b.untilAt - now())
	end

	function self.forModule(moduleName: string, assertUsable: (() -> ())?): (string) -> any
		return function(name: string): any
			if assertUsable then
				assertUsable()
			end
			if type(name) ~= "string" or name == "" then
				error(`{moduleName}: ctx.data.ordered(name): name must be a non-empty string`, 2)
			end
			local base = OrderedStore.storeName(moduleName, name, false)
			if #base > OrderedStore.MAX_NAME then
				error(
					`{moduleName}: ctx.data.ordered('{name}'): the store name '{base}' is longer than {OrderedStore.MAX_NAME} characters`,
					2
				)
			end
			local storeName = OrderedStore.storeName(moduleName, name, opts.isStudio)
			local backend: any = nil
			local function store(): any
				if backend == nil then
					backend = backendFor(storeName)
				end
				return backend
			end
			local function checkKey(what: string, key: any)
				if type(key) ~= "string" or key == "" or #key > OrderedStore.MAX_KEY then
					error(
						`{moduleName}: ordered.{what}: key must be a string of 1..{OrderedStore.MAX_KEY} characters`,
						3
					)
				end
			end
			local function remainingFor(kind: string): number?
				local ok, remaining = pcall(function(): number?
					local b = store()
					return if b.requestBudget then b.requestBudget(kind) else nil
				end)
				return if ok and type(remaining) == "number" then remaining else nil
			end
			local function warnOnce(kind: string, err: any)
				local t = now()
				local last = lastWarn[storeName]
				if last == nil or t - last >= OrderedStore.WARN_SECONDS then
					lastWarn[storeName] = t
					log(`[StudWork] {storeName}: {kind} failed: {tostring(err)}`)
				end
			end

			-- one call: back-off, budget, then the backend in pcall (retried unless `once`)
			local function run(kind: string, once: boolean, fn: () -> any): (boolean, any)
				local b = backoffOf(moduleName)
				local tries = if once then 1 else #OrderedStore.RETRY_WAITS + 1
				local lastErr: any = nil
				for attempt = 1, tries do
					if now() < b.untilAt then
						return false, "budget"
					end
					if budget ~= nil and not budget.allowOrdered(moduleName, kind, remainingFor(kind)) then
						return false, "budget"
					end
					local ok, result = pcall(fn)
					if ok then
						b.level = 0
						return true, result
					end
					lastErr = result
					if OrderedStore.isExperienceThrottle(result) then
						b.level += 1
						local seconds =
							math.min(OrderedStore.BACKOFF_START * 2 ^ (b.level - 1), OrderedStore.BACKOFF_MAX)
						b.untilAt = now() + seconds
						log(
							`[StudWork] {moduleName}: ordered stores back off for {seconds} s (experience-level throttle on {storeName}: {tostring(
								result
							)})`
						)
						return false, "budget"
					end
					local pause = OrderedStore.RETRY_WAITS[attempt]
					if attempt < tries and pause ~= nil then
						wait(pause)
					end
				end
				warnOnce(kind, lastErr)
				return false, "failed"
			end

			local api = {}
			function api.get(key: string): (boolean, number?)
				checkKey("get", key)
				return run("get", false, function()
					return store().get(key)
				end)
			end
			function api.set(key: string, value: number): (boolean, string?)
				checkKey("set", key)
				if not isInteger(value) then
					error(
						`{moduleName}: ordered.set: value must be a finite integer (got {tostring(value)})`,
						2
					)
				end
				local ok, result = run("set", false, function()
					store().set(key, value)
					return nil
				end)
				return ok, if ok then nil else result
			end
			function api.increment(key: string, delta: number): (boolean, any)
				checkKey("increment", key)
				if not isInteger(delta) then
					error(
						`{moduleName}: ordered.increment: delta must be a finite integer (got {tostring(delta)})`,
						2
					)
				end
				return run("increment", true, function()
					return store().increment(key, delta) -- never retried: it may have committed
				end)
			end
			function api.update(key: string, fn: (number?) -> number?): (boolean, any)
				checkKey("update", key)
				assert(type(fn) == "function", `{moduleName}: ordered.update: fn must be a function`)
				local callerError: string? = nil
				local function wrapped(old: number?): number?
					local okFn, new = pcall(fn, old)
					if not okFn then
						callerError = `fn raised: {tostring(new)}`
						return nil
					end
					if new ~= nil and not isInteger(new) then
						callerError = `fn must return a finite integer or nil (got {tostring(new)})`
						return nil
					end
					return new
				end
				local ok, result = run("update", false, function()
					return store().update(key, wrapped)
				end)
				if callerError ~= nil then
					error(`{moduleName}: ordered.update: {callerError}`, 2)
				end
				return ok, result
			end
			function api.remove(key: string): (boolean, string?)
				checkKey("remove", key)
				local ok, result = run("remove", false, function()
					store().remove(key)
					return nil
				end)
				return ok, if ok then nil else result
			end
			function api.top(
				count: number,
				order: string,
				minValue: number?,
				maxValue: number?
			): (boolean, any)
				if not isInteger(count) or count < 1 or count > OrderedStore.MAX_COUNT then
					error(
						`{moduleName}: ordered.top: count must be an integer in 1..{OrderedStore.MAX_COUNT}`,
						2
					)
				end
				if order ~= "desc" and order ~= "asc" then
					error(`{moduleName}: ordered.top: order must be "desc" or "asc"`, 2)
				end
				return run("top", false, function()
					return store().top(count, order, minValue, maxValue)
				end)
			end
			return table.freeze(api)
		end
	end

	return self
end

return OrderedStore
