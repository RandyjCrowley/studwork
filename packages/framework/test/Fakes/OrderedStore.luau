--!strict
--[[
	In-memory ordered store (StudWork.test, module-api.md §23.3 / §23.10): the backend behind
	`ctx.data.ordered(name)` in the harness and the sim. It is the OrderedDataStore stand-in, not the
	framework layer: server/OrderedStore.luau validates, budgets, retries and wraps failures around it.

	No second ordered store: the data lives in an existing mock OrderedDataStore, reached through
	the same adapter the live platform uses (server/PlatformStores.luau orderedAdapter + orderedShim):
	  - by default the legacy adapter's memory backend (server/Legacy.luau Legacy.memory(), the one
	    StudWork.test.legacyStore() is), one per store;
	  - in the sim, the World's ordered stores (world.stores["ordered:<storeName>"], world:setOrdered,
	    world:failNext / failFor, latency), wired by test/sim/MemoryStores.luau.

	  OrderedFake.new(opts?) -> fake
	    opts = { name = string?, clock = () -> number?,
	             ods = OrderedDataStore-like?   (default: Legacy.memory()'s, through the shim)
	             peek = () -> { [key]: number }?   read every entry without a call (entries())
	             seed = (key, value) -> ()?        write one entry without a call (seed()) }
	  backend (raises on a failure; the framework layer turns that into (false, "failed")):
	    get(key) -> number?                       set(key, value)
	    increment(key, delta) -> number           update(key, fn(old) -> number?) -> number?  (nil cancels)
	    remove(key)                               top(count, order, min?, max?) -> { { key, value } }
	  test surface:
	    entries() -> { [key]: number }            a copy
	    seed({ [key] = number })                  put values in without a call
	    calls                                     { { op, key?, value? } } every backend call
	    failNext(n, code?)                        the next n backend calls raise `code` (default
	                                              "InjectedFailure"; "HTTP 429 (Too Many Requests)" is
	                                              an experience-level throttle)
]]

local Legacy = (require :: any)(script.Parent.Parent.Parent.server.Legacy)
local PlatformStores = (require :: any)(script.Parent.Parent.Parent.server.PlatformStores)

local OrderedFake = {}

local function isInteger(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v % 1 == 0
end

function OrderedFake.new(opts: any?): any
	local o = opts or {}
	local name: string = o.name or "ordered"
	local ods = o.ods
	local peek: () -> { [string]: number } = o.peek
	local seedOne: (string, number) -> () = o.seed
	if ods == nil then
		local legacy = Legacy.memory()
		local raw = legacy.dataStoreService():GetOrderedDataStore(name)
		ods = PlatformStores.orderedShim(raw)
		peek = peek
			or function(): { [string]: number }
				local out = {}
				for _, entry in raw:GetSortedAsync(false, math.huge):GetCurrentPage() do
					out[tostring(entry.key)] = entry.value
				end
				return out
			end
		seedOne = seedOne or function(key: string, value: number)
			legacy.setOrdered(name, key, value)
		end
	end
	local backend = PlatformStores.orderedAdapter(ods)
	local fake: any = { name = o.name, calls = {} }
	local failures, failCode = 0, "InjectedFailure"

	local function enter(op: string, key: string?, value: any?)
		table.insert(fake.calls, { op = op, key = key, value = value })
		if failures > 0 then
			failures -= 1
			error(failCode, 0)
		end
	end

	function fake.failNext(n: number, code: string?)
		failures += n
		failCode = code or "InjectedFailure"
	end

	function fake.get(key: string): number?
		enter("get", key)
		return backend.get(key)
	end

	function fake.set(key: string, value: number)
		enter("set", key, value)
		assert(isInteger(value), "ordered store: value must be a finite integer")
		backend.set(key, value)
	end

	function fake.increment(key: string, delta: number): number
		enter("increment", key, delta)
		assert(isInteger(delta), "ordered store: delta must be a finite integer")
		return backend.increment(key, delta)
	end

	function fake.update(key: string, fn: (number?) -> number?): number?
		enter("update", key)
		return backend.update(key, function(old: number?): number?
			local new = fn(old)
			assert(new == nil or isInteger(new), "ordered store: value must be a finite integer")
			return new
		end)
	end

	function fake.remove(key: string)
		enter("remove", key)
		backend.remove(key)
	end

	function fake.top(count: number, order: string, minValue: number?, maxValue: number?): { any }
		enter("top")
		return backend.top(count, order, minValue, maxValue)
	end

	function fake.entries(): { [string]: number }
		if peek ~= nil then
			return table.clone(peek())
		end
		local out = {}
		for _, row in backend.top(math.huge, "desc") do
			out[row.key] = row.value
		end
		return out
	end

	function fake.seed(entries: { [string]: number })
		for key, value in entries do
			if seedOne ~= nil then
				seedOne(key, value)
			else
				ods:SetAsync(key, value)
			end
		end
	end

	return fake
end

return OrderedFake
