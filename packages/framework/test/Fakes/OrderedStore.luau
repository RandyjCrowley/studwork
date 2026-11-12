--!strict
--[[
	In-memory ordered store (StudWork.test, module-api.md §23.3 / §23.10): the backend behind
	`ctx.data.ordered(name)` in the harness and the sim. It is the OrderedDataStore stand-in, not the
	framework layer: server/OrderedStore.luau validates, budgets and wraps failures around it.

	  OrderedFake.new(opts?) -> fake
	    opts = { name = string?, clock = () -> number? }
	  backend (raises on a failure; the framework layer turns that into (false, "failed")):
	    get(key) -> number?                       set(key, value)
	    increment(key, delta) -> number           update(key, fn(old) -> number?) -> number?  (nil cancels)
	    remove(key)                               top(count, order, min?, max?) -> { { key, value } }
	  test surface:
	    entries() -> { [key]: number }            a copy
	    seed({ [key] = number })                  put values in without a call
	    calls                                     { { op, key?, value? } } every backend call
	    failNext(n, code?)                        the next n backend calls raise `code` (default "InjectedFailure")

	FOUNDATION: a working standalone store. The stores builder (B1) points it at the sim World's and
	the legacy adapter's existing ordered backend (no second copy) and adds the experience-level limits.
]]

local OrderedFake = {}

local function isInteger(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v % 1 == 0
end

function OrderedFake.new(opts: any?): any
	local o = opts or {}
	local values: { [string]: number } = {}
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
		return values[key]
	end

	function fake.set(key: string, value: number)
		enter("set", key, value)
		assert(isInteger(value), "ordered store: value must be a finite integer")
		values[key] = value
	end

	function fake.increment(key: string, delta: number): number
		enter("increment", key, delta)
		assert(isInteger(delta), "ordered store: delta must be a finite integer")
		values[key] = (values[key] or 0) + delta
		return values[key]
	end

	function fake.update(key: string, fn: (number?) -> number?): number?
		enter("update", key)
		local old = values[key]
		local new = fn(old)
		if new == nil then
			return old -- cancelled
		end
		assert(isInteger(new), "ordered store: value must be a finite integer")
		values[key] = new
		return new
	end

	function fake.remove(key: string)
		enter("remove", key)
		values[key] = nil
	end

	function fake.top(count: number, order: string, minValue: number?, maxValue: number?): { any }
		enter("top")
		local rows = {}
		for key, value in values do
			if (minValue == nil or value >= minValue) and (maxValue == nil or value <= maxValue) then
				table.insert(rows, { key = key, value = value })
			end
		end
		table.sort(rows, function(a: any, b: any): boolean
			if a.value ~= b.value then
				if order == "asc" then
					return a.value < b.value
				end
				return a.value > b.value
			end
			return a.key < b.key
		end)
		local out = {}
		for i = 1, math.min(count, #rows) do
			out[i] = rows[i]
		end
		return out
	end

	function fake.entries(): { [string]: number }
		return table.clone(values)
	end

	function fake.seed(entries: { [string]: number })
		for key, value in entries do
			values[key] = value
		end
	end

	return fake
end

return OrderedFake
