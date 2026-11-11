--!strict
--[[
	Framework Legacy reader (v1.6.0, docs/framework/adopting.md §3, §4.2). Framework internal.
	READ-ONLY by construction: a backend has read methods only, so no StudWork code path can write
	an old store (adopting.md rule 1).

	Backend interface (pinned for v1.6.0; every backend raises on a failed read):
	  backend.get(name, scope?, key) -> (value: any, updatedAt: number?)
	      one key of a (global) DataStore, never from a cache. updatedAt in unix SECONDS (the live
	      backend converts DataStoreKeyInfo.UpdatedTime from milliseconds); nil value = no key.
	  backend.latestOrdered(name, scope?) -> (key: string?, value: number?)
	      the highest entry of an OrderedDataStore (DataStore2's ordered backups), nil when empty.

	Legacy.readOnly(dataStoreService, opts?) -> backend   live: GetAsync with UseCache = false,
	                                                       GetSortedAsync(false, 1)
	Legacy.memory(seed?) -> backend + test controls       StudWork.test.legacyStore
	    seed = { datastore = { [storeId] = { [key] = value } }, ordered = { [storeId] = { [key] = n } } }
	    storeId = name, or name .. "@" .. scope
	    store.set(name, key, value, at?, scope?)    write as an OLD SERVER would (sets updatedAt)
	    store.setOrdered(name, key, n, scope?)
	    store.failNext(n)                           the next n reads raise
	    store.reads                                 how many reads were made (tests)
	    store.now = fn                              the clock `set` stamps with (default os.time)
	Legacy.new(opts) -> reader      opts = { backend, now, wait?, log? }
	  reader.readKey(name, scope?, key) -> (ok, value?, updatedAt? | err)
	  reader.read(source, userId) -> (status, value?, info)   (agent C: the formats)
	      status "found" | "none" | "busy" | "error"; info = { updatedAt?, error? }
	  reader.expand(pattern, vars) -> string        "{userId}" / "{purchaseId}" substitution
]]

local Legacy = {}

Legacy.QUIET_SECONDS = 120 -- a value written this recently may be an old server's final save
Legacy.SESSION_STALE_SECONDS = 1800 -- a ProfileService lock older than this is a dead server's
Legacy.RECEIPT_KEEP_DAYS = 90 -- _framework.legacyPurchases entries are kept this long
Legacy.READ_ATTEMPTS = 3 -- reads per join before the import fails (backoff between)

local function storeId(name: string, scope: string?): string
	return if scope ~= nil and scope ~= "" then name .. "@" .. scope else name
end
Legacy.storeId = storeId

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

function Legacy.expand(pattern: string, vars: { [string]: any }): string
	return (
		string.gsub(pattern, "{(%w+)}", function(name: string): string
			local v = vars[name]
			if v == nil then
				error(`legacy key pattern '{pattern}' uses {"{"}{name}{"}"}, which is not available`, 0)
			end
			return tostring(v)
		end)
	)
end

-- The live backend: read methods only (no SetAsync/UpdateAsync/RemoveAsync/IncrementAsync path).
function Legacy.readOnly(dataStoreService: any, opts: any?): any
	local o = opts or {}
	local options: any = nil
	local okOpt, made = pcall(function(): any
		local x: any = Instance.new("DataStoreGetOptions")
		x.UseCache = false
		return x
	end)
	if okOpt then
		options = made
	elseif o.log then
		o.log("[StudWork.Legacy] DataStoreGetOptions unavailable; reads may be cached")
	end
	local b: any = {}
	function b.get(name: string, scope: string?, key: string): (any, number?)
		local store = dataStoreService:GetDataStore(name, scope)
		local value, info = store:GetAsync(key, options)
		local at: number? = nil
		if info ~= nil then
			local ms = (info :: any).UpdatedTime
			if type(ms) == "number" then
				at = ms / 1000
			end
		end
		return value, at
	end
	function b.latestOrdered(name: string, scope: string?): (string?, number?)
		local store = dataStoreService:GetOrderedDataStore(name, scope)
		local pages = store:GetSortedAsync(false, 1)
		local top = pages:GetCurrentPage()[1]
		if top == nil then
			return nil, nil
		end
		return top.key, top.value
	end
	return table.freeze(b)
end

function Legacy.memory(seed: any?): any
	local s = seed or {}
	local stores: { [string]: { [string]: { value: any, at: number? } } } = {}
	local ordered: { [string]: { [string]: number } } = {}
	for id, keys in s.datastore or {} do
		stores[id] = {}
		for key, value in keys do
			stores[id][key] = { value = deepCopy(value), at = nil }
		end
	end
	for id, keys in s.ordered or {} do
		ordered[id] = table.clone(keys)
	end
	local fail = 0
	local m: any = { reads = 0, now = os.time }
	local function read()
		m.reads += 1
		if fail > 0 then
			fail -= 1
			error("injected legacy read failure", 0)
		end
	end
	function m.failNext(n: number)
		fail = n
	end
	function m.set(name: string, key: string, value: any, at: number?, scope: string?)
		local id = storeId(name, scope)
		stores[id] = stores[id] or {}
		stores[id][key] = { value = deepCopy(value), at = at or m.now() }
	end
	function m.setOrdered(name: string, key: string, n: number, scope: string?)
		local id = storeId(name, scope)
		ordered[id] = ordered[id] or {}
		ordered[id][key] = n
	end
	function m.get(name: string, scope: string?, key: string): (any, number?)
		read()
		local e = (stores[storeId(name, scope)] or {})[key]
		if e == nil then
			return nil, nil
		end
		return deepCopy(e.value), e.at
	end
	function m.latestOrdered(name: string, scope: string?): (string?, number?)
		read()
		local best: string?, bestN: number? = nil, nil
		local entries: { [string]: number } = ordered[storeId(name, scope)] or {}
		for key, n in entries do
			if bestN == nil or n > bestN then
				best, bestN = key, n
			end
		end
		return best, bestN
	end
	-- tests peek without counting a read
	function m.peek(name: string, key: string, scope: string?): any
		local e = (stores[storeId(name, scope)] or {})[key]
		return if e then deepCopy(e.value) else nil
	end
	return m
end

function Legacy.new(opts: any): any
	local backend = opts.backend
	local r: any = {}

	function r.readKey(name: string, scope: string?, key: string): (boolean, any, any)
		local ok, value, at = pcall(backend.get, name, scope, key)
		if not ok then
			return false, nil, tostring(value)
		end
		return true, value, at
	end

	r.expand = Legacy.expand

	-- v1.6.0 contract stub: the formats (datastore, profileservice/profilestore, datastore2), the
	-- quiet window and the busy rules are agent C's (adopting.md §3, "Sources").
	function r.read(_source: any, _userId: number): (string, any, any)
		return "error", nil, { error = "Legacy.read: not implemented yet" }
	end

	return table.freeze(r)
end

return Legacy
