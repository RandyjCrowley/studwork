--!strict
--[[
	`ctx.data.ordered(name)` (module-api.md §23.3): one OrderedDataStore per (module, name), store
	name `SW/<Module>/<name>`, behind the framework's request budget.

	  OrderedStore.new(opts) -> { forModule(moduleName, assertUsable?) -> (name) -> OrderedStore }
	    opts = { backend = (storeName) -> backend, budget = StoreBudget, isStudio, now, log }

	backend (platform.stores.ordered(storeName); may raise a code string on failure):
	  get(key) -> number?                      set(key, value)
	  increment(key, delta) -> number          update(key, fn(old) -> number?) -> number?
	  remove(key)                              top(count, order, min?, max?) -> { { key, value } }

	Caller errors (raised): a name or key that is too long, a value that isn't a finite integer, a
	bad `count` or `order`. Platform failures never raise: (false, "budget" | "failed").

	STUB (foundation): argument checks, the budget hook and the pcall wrapper are real; the retries
	with backoff (1, 2 s), the experience-level back-off of every store of a module (30 s doubling
	to 5 min) and the once-a-minute warning are the stores builder's (B1).
]]

local OrderedStore = {}

OrderedStore.MAX_NAME = 50
OrderedStore.MAX_KEY = 50
OrderedStore.MAX_COUNT = 100

local function isInteger(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v % 1 == 0
end

function OrderedStore.storeName(moduleName: string, name: string, isStudio: boolean?): string
	return `SW/{moduleName}/{name}` .. (if isStudio then "_Studio" else "")
end

function OrderedStore.new(opts: any): any
	local backendFor: (string) -> any = opts.backend
	local budget = opts.budget
	local log: (string) -> () = opts.log or function(_m: string) end
	local self: any = {}

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
			-- one call: budget check, then the backend in pcall
			local function run(kind: string, fn: () -> any): (boolean, any)
				if budget ~= nil and not budget.allowOrdered(moduleName, kind) then
					return false, "budget"
				end
				local ok, result = pcall(fn)
				if not ok then
					log(`[StudWork] {storeName}: {kind} failed: {tostring(result)}`)
					return false, "failed"
				end
				return true, result
			end

			local api = {}
			function api.get(key: string): (boolean, number?)
				checkKey("get", key)
				return run("get", function()
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
				local ok, result = run("set", function()
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
				return run("increment", function()
					return store().increment(key, delta) -- never retried: it may have committed
				end)
			end
			function api.update(key: string, fn: (number?) -> number?): (boolean, any)
				checkKey("update", key)
				assert(type(fn) == "function", `{moduleName}: ordered.update: fn must be a function`)
				return run("update", function()
					return store().update(key, fn)
				end)
			end
			function api.remove(key: string): (boolean, string?)
				checkKey("remove", key)
				local ok, result = run("remove", function()
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
				return run("top", function()
					return store().top(count, order, minValue, maxValue)
				end)
			end
			return table.freeze(api)
		end
	end

	return self
end

return OrderedStore
