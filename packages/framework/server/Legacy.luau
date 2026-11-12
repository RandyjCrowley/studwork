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
	Legacy.live(log) -> backend                            readOnly(DataStoreService), built lazily
	Legacy.memory(seed?) -> backend + test controls       StudWork.test.legacyStore
	    seed = { datastore = { [storeId] = { [key] = value } }, ordered = { [storeId] = { [key] = n } } }
	    storeId = name, or name .. "@" .. scope
	    store.set(name, key, value, at?, scope?)    write as an OLD SERVER would (sets updatedAt)
	    store.setOrdered(name, key, n, scope?)
	    store.failNext(n)                           the next n reads raise
	    store.reads                                 how many reads were made (tests)
	    store.now = fn                              the clock `set` stamps with (default os.time)
	    store.dataStoreService() -> a DataStoreService-like facade over the same stores, so old
	        handler code runs unchanged in tests (v1.6.1): GetDataStore(name, scope?) with
	        GetAsync / SetAsync / UpdateAsync / IncrementAsync / RemoveAsync, GetOrderedDataStore
	        with SetAsync / UpdateAsync / IncrementAsync / RemoveAsync / GetSortedAsync
	    store.watchWrites(fn(event)) -> stop()      (v1.6.1) every WRITE (set, setOrdered, busy, the
	        facade's writes) calls fn({ store = storeId, name, scope?, key, op }); an observer only
	        (the framework never writes through it). Shop uses it to catch an onLegacyProduct
	        handler that declared writesLegacyData = false and writes anyway (adopting.md §4.3).
	Legacy.new(opts) -> reader      opts = { backend, now, wait?, log?, isStudio? }
	  reader.readKey(name, scope?, key) -> (ok, value?, updatedAt? | err)
	  reader.read(source, userId) -> (status, value?, info)
	      status "found" | "none" | "busy" | "error" | "unavailable";
	      info = { updatedAt?, error?, attempts }
	  reader.readAll(source | { [name]: source }, userId) -> (status, old?, sources, err?)
	      a single source: old = its value; a map: old = { [name] = value? } (found when any is).
	      sources = { [name]: { found, updatedAt? } } ("main" for a single source)
	  reader.expand(pattern, vars) -> string        "{userId}" / "{purchaseId}" substitution
	  reader.canWatch() -> boolean                  (v1.6.1) the backend reports writes (test mocks)
	  reader.watchWrites(fn) -> stop()              (v1.6.1) backend.watchWrites (errors without it)
	  reader.stamp(source, userId) -> (ok, stamp | err)   (v1.6.1, Studio write detection) READS the
	      keys a source reads (no cache) and returns { { store, key, updatedAt?, value } };
	      err = Legacy.NO_ACCESS when Studio has no API access. Legacy.sameStamp(a, b) -> (bool, key?)
	Legacy.validateSource(source) -> err?           registration check (Context/Data, boot errors)
	Legacy.storeNames(source) -> { string }         the store names a source reads (collision check)

	Formats (adopting.md §3, "Sources"):
	  datastore       GetDataStore(name, scope?):GetAsync(expand(key)) -> the value as stored.
	  profileservice  the same store/key the library used. ProfileService and ProfileStore 1.0.3
	  profilestore    store { Data, MetaData = { ProfileCreateTime, SessionLoadCount,
	                  ActiveSession = {placeId, jobId[, sessionId]} | nil, ForceLoadSession?,
	                  MetaTags?, LastUpdate (os.time) }, GlobalUpdates, RobloxMetaData?, UserIds? }
	                  (checked against deps/ServerPackages/.../ProfileStore.luau 1.0.3 and
	                  ProfileService's documented layout). old = Data; a record with no Data (only
	                  GlobalUpdates) is "none". BUSY: ActiveSession set and LastUpdate (else the
	                  key's UpdatedTime) within SESSION_STALE_SECONDS of now; an older lock is a
	                  dead server's and is read anyway.
	  datastore2      DataStore2 (Kampfkarren/Roblox, SavingMethods/OrderedBackups.lua, the
	                  default): store name `<name>/<userId>` for BOTH the OrderedDataStore and the
	                  DataStore; the ordered store's top entry (GetSortedAsync(false, 1)) has
	                  value = the latest version n, and the DataStore holds the save under key n.
	                  savingMethod = "Standard" (SavingMethods/Standard.lua): GetDataStore(name),
	                  key = tostring(userId). combined = { "coins", ... }: `name` is the Combine
	                  master key and the stored value is a table holding those keys; old = a table
	                  of just those keys. (DataStore2's own serializers/BeforeSave are not applied:
	                  old is the raw stored value.)
	  Every kind: a value updated within QUIET_SECONDS of now is BUSY (an old server may still be
	  writing its final save). A wrong type (a non-table where a table is expected) is an error.
	  Errors (the backend raised) are retried READ_ATTEMPTS times with backoff (opts.wait 1 s, 2 s);
	  busy and wrong-type results are not retried (the load fails, the next join tries again).
	  Studio without DataStore API access (opts.isStudio and the error says so): status
	  "unavailable": the import is skipped for this session with a loud warning and NO marker is
	  written, so every Studio playtest still loads and a published server imports for real.
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

-- The live engine's backend (the runtime uses it when no platform/test backend is given):
-- Legacy.readOnly on DataStoreService, created on the FIRST read, so a game with no importLegacy
-- never touches it.
function Legacy.live(log: (string) -> ()): any
	local backend: any = nil
	local function get(): any
		if backend == nil then
			backend = Legacy.readOnly((game :: any):GetService("DataStoreService"), { log = log })
		end
		return backend
	end
	return table.freeze({
		get = function(name: string, scope: string?, key: string): (any, number?)
			return get().get(name, scope, key)
		end,
		latestOrdered = function(name: string, scope: string?): (string?, number?)
			return get().latestOrdered(name, scope)
		end,
	})
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
	local watchers: { [number]: (any) -> () } = {}
	local nextWatcher = 0
	local function wrote(name: string, scope: string?, key: string, op: string)
		local event =
			table.freeze({ store = storeId(name, scope), name = name, scope = scope, key = key, op = op })
		for _, fn in table.clone(watchers) do
			fn(event)
		end
	end
	function m.watchWrites(fn: (any) -> ()): () -> ()
		nextWatcher += 1
		local id = nextWatcher
		watchers[id] = fn
		return function()
			watchers[id] = nil
		end
	end
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
		wrote(name, scope, key, "set")
	end
	m.write = m.set -- adopting.md §3 name
	-- re-stamps a key as just written (an old server still saving): a busy read
	function m.busy(name: string, key: string, scope: string?)
		local e = (stores[storeId(name, scope)] or {})[key]
		if e then
			e.at = m.now()
			wrote(name, scope, key, "busy")
		end
	end
	-- seeded update times (seed values have none = written long ago)
	function m.setUpdatedAt(name: string, key: string, at: number?, scope: string?)
		local e = (stores[storeId(name, scope)] or {})[key]
		if e then
			e.at = at
		end
	end
	function m.setOrdered(name: string, key: string, n: number, scope: string?)
		local id = storeId(name, scope)
		ordered[id] = ordered[id] or {}
		ordered[id][key] = n
		wrote(name, scope, key, "setOrdered")
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
	-- (v1.6.1) old game code in tests: a DataStoreService-like facade; every write notifies the
	-- watchers (Shop's undeclared-write check). Reads through it don't count as framework reads.
	function m.dataStoreService(): any
		local service: any = {}
		function service.GetDataStore(_self: any, name: string, scope: string?, _options: any?): any
			local id = storeId(name, scope)
			local ds: any = {}
			local function cur(key: string): any
				local e = (stores[id] or {})[key]
				return if e then deepCopy(e.value) else nil
			end
			local function put(key: string, value: any, op: string)
				stores[id] = stores[id] or {}
				if value == nil then
					stores[id][key] = nil
				else
					stores[id][key] = { value = deepCopy(value), at = m.now() }
				end
				wrote(name, scope, key, op)
			end
			function ds.GetAsync(_ds: any, key: string): any
				return cur(key)
			end
			function ds.SetAsync(_ds: any, key: string, value: any)
				put(key, value, "SetAsync")
			end
			function ds.UpdateAsync(_ds: any, key: string, transform: (any) -> any): any
				local v = transform(cur(key))
				if v ~= nil then
					put(key, v, "UpdateAsync")
				end
				return v
			end
			function ds.IncrementAsync(_ds: any, key: string, delta: number?): number
				local v = (tonumber(cur(key)) or 0) + (delta or 1)
				put(key, v, "IncrementAsync")
				return v
			end
			function ds.RemoveAsync(_ds: any, key: string): any
				local old = cur(key)
				put(key, nil, "RemoveAsync")
				return old
			end
			return ds
		end
		function service.GetOrderedDataStore(_self: any, name: string, scope: string?): any
			local id = storeId(name, scope)
			local ods: any = {}
			local function put(key: string, n: number?, op: string)
				local t: { [string]: number } = ordered[id] or {}
				ordered[id] = t
				t[key] = n :: any
				wrote(name, scope, key, op)
			end
			function ods.SetAsync(_o: any, key: string, n: number)
				put(key, n, "SetAsync")
			end
			function ods.UpdateAsync(_o: any, key: string, transform: (number?) -> number?): number?
				local v = transform((ordered[id] or {})[key])
				if v ~= nil then
					put(key, v, "UpdateAsync")
				end
				return v
			end
			function ods.IncrementAsync(_o: any, key: string, delta: number?): number
				local v = ((ordered[id] or {})[key] or 0) + (delta or 1)
				put(key, v, "IncrementAsync")
				return v
			end
			function ods.RemoveAsync(_o: any, key: string)
				put(key, nil, "RemoveAsync")
			end
			function ods.GetSortedAsync(_o: any, ascending: boolean, pageSize: number): any
				local list = {}
				local entries: { [string]: number } = ordered[id] or {}
				for key, n in entries do
					table.insert(list, { key = key, value = n })
				end
				table.sort(list, function(a, b)
					return if ascending then a.value < b.value else a.value > b.value
				end)
				local page = {}
				for i = 1, math.min(pageSize, #list) do
					page[i] = list[i]
				end
				return {
					GetCurrentPage = function(): any
						return page
					end,
				}
			end
			return ods
		end
		return service
	end
	return m
end

-- (v1.6.1) deep equality of two stored values (Studio write detection compares before/after)
local function same(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- Two reader.stamp results -> (unchanged, "store key" of the first changed key)
function Legacy.sameStamp(a: { any }, b: { any }): (boolean, string?)
	for i, x in a do
		local y = b[i]
		if y == nil or y.store ~= x.store or y.key ~= x.key then
			return false, `{x.store} {x.key}`
		end
		if y.updatedAt ~= x.updatedAt or not same(x.value, y.value) then
			return false, `{x.store} {x.key}`
		end
	end
	if #b ~= #a then
		local y = b[#a + 1]
		return false, if y then `{y.store} {y.key}` else nil
	end
	return true, nil
end

Legacy.KINDS =
	table.freeze({ datastore = true, profileservice = true, profilestore = true, datastore2 = true })
Legacy.NO_ACCESS = "DataStore API access unavailable in Studio"

-- Studio without "Enable Studio Access to API Services": GetAsync raises this class of error.
function Legacy.isNoAccessError(err: string): boolean
	local e = string.lower(err)
	return string.find(e, "studioaccesstoapisnotallowed", 1, true) ~= nil
		or string.find(e, "access to api services", 1, true) ~= nil
		or string.find(e, "api services", 1, true) ~= nil and string.find(e, "studio", 1, true) ~= nil
		or string.find(e, "api access", 1, true) ~= nil
		-- an unpublished place (Studio, v1.6.0 Studio boot): "You must publish this place to the
		-- web to access DataStore."
		or string.find(e, "publish this place", 1, true) ~= nil
end

function Legacy.isSingleSource(spec: any): boolean
	return type(spec) == "table" and spec.kind ~= nil
end

-- One source table -> error string or nil.
function Legacy.validateSource(source: any): string?
	if type(source) ~= "table" then
		return "source must be a table"
	end
	local kind = source.kind
	if type(kind) ~= "string" or not Legacy.KINDS[kind] then
		return `source.kind must be "datastore", "profileservice", "profilestore" or "datastore2" (got {tostring(
			kind
		)})`
	end
	if type(source.name) ~= "string" or source.name == "" or #source.name > 50 then
		return "source.name must be a store name (1-50 characters)"
	end
	if source.scope ~= nil and (type(source.scope) ~= "string" or #source.scope > 50) then
		return "source.scope must be a string"
	end
	if kind == "datastore2" then
		if source.key ~= nil then
			return "a datastore2 source has no key (DataStore2 keys by userId)"
		end
		if
			source.savingMethod ~= nil
			and source.savingMethod ~= "OrderedBackups"
			and source.savingMethod ~= "Standard"
		then
			return 'source.savingMethod must be "OrderedBackups" (default) or "Standard"'
		end
		if source.combined ~= nil then
			if type(source.combined) ~= "table" or #source.combined == 0 then
				return "source.combined must be a non-empty list of DataStore2 key names"
			end
			for _, k in source.combined do
				if type(k) ~= "string" then
					return "source.combined must list strings"
				end
			end
		end
	else
		if type(source.key) ~= "string" or source.key == "" then
			return 'source.key must be a key pattern, e.g. "Player_{userId}"'
		end
		for var in string.gmatch(source.key, "{(%w+)}") do
			if var ~= "userId" then
				return `source.key '{source.key}' uses \{{var}\}: only \{userId\} is available at join`
			end
		end
		if not string.find(source.key, "{userId}", 1, true) then
			return `source.key '{source.key}' has no \{userId\}: every player would read the same key`
		end
		if source.combined ~= nil or source.savingMethod ~= nil then
			return "combined / savingMethod are datastore2 options"
		end
	end
	for k in source do
		if
			k ~= "kind"
			and k ~= "name"
			and k ~= "scope"
			and k ~= "key"
			and k ~= "combined"
			and k ~= "savingMethod"
		then
			return `unknown source field '{tostring(k)}'`
		end
	end
	return nil
end

-- A source spec (single or map) -> (list of { name, source }, err?)
function Legacy.sourceList(spec: any): ({ { name: string, source: any } }, string?)
	if type(spec) ~= "table" then
		return {}, "source must be a table"
	end
	if Legacy.isSingleSource(spec) then
		local err = Legacy.validateSource(spec)
		return { { name = "main", source = spec } }, err
	end
	local out = {}
	for name, src in spec do
		if type(name) ~= "string" then
			return {}, "a map of sources needs string names"
		end
		local err = Legacy.validateSource(src)
		if err then
			return {}, `source '{name}': {err}`
		end
		table.insert(out, { name = name, source = src })
	end
	if #out == 0 then
		return {}, "source is empty (give { kind = ..., name = ..., key = ... } or a map of them)"
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out, nil
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

	-- (v1.6.1) write observation: test mocks only (the live backend has no such method)
	function r.canWatch(): boolean
		return type(backend.watchWrites) == "function"
	end
	function r.watchWrites(fn: (any) -> ()): () -> ()
		return backend.watchWrites(fn)
	end

	-- (v1.6.1) Studio write detection: READ every key a source reads (no retries: one failed
	-- read fails the check closed). DataStore2 ordered backups: the ordered store's top entry plus
	-- the version key it points at.
	function r.stamp(source: any, userId: number): (boolean, any)
		local out = {}
		local function get(name: string, scope: string?, key: string): string?
			local ok, value, at = pcall(backend.get, name, scope, key)
			if not ok then
				local message = tostring(value)
				return if Legacy.isNoAccessError(message) then Legacy.NO_ACCESS else message
			end
			table.insert(out, { store = storeId(name, scope), key = key, updatedAt = at, value = value })
			return nil
		end
		local kind = source.kind
		if kind == "datastore2" and source.savingMethod ~= "Standard" then
			local storeName = source.name .. "/" .. tostring(userId)
			local ok, key, n = pcall(backend.latestOrdered, storeName, source.scope)
			if not ok then
				local message = tostring(key)
				return false, if Legacy.isNoAccessError(message) then Legacy.NO_ACCESS else message
			end
			table.insert(
				out,
				{ store = "ordered:" .. storeId(storeName, source.scope), key = tostring(key), value = n }
			)
			if n ~= nil then
				local err =
					get(storeName, source.scope, tostring(if type(n) == "number" then math.floor(n) else n))
				if err then
					return false, err
				end
			end
		else
			local key = if kind == "datastore2"
				then tostring(userId)
				else Legacy.expand(source.key, { userId = userId })
			local err = get(source.name, source.scope, key)
			if err then
				return false, err
			end
		end
		return true, out
	end

	local now: () -> number = opts.now or os.time
	local wait: (number) -> () = opts.wait or function(_s: number) end
	local log: (string) -> () = opts.log or function(_m: string) end
	local isStudio = opts.isStudio == true

	-- one backend call with retries: (ok, a, b, err)
	local function attempt(fn: any, ...: any): (boolean, any, any, string?, number)
		local lastErr: string? = nil
		for i = 1, Legacy.READ_ATTEMPTS do
			local ok, a, b = pcall(fn, ...)
			if ok then
				return true, a, b, nil, i
			end
			local message = tostring(a)
			lastErr = message
			if isStudio and Legacy.isNoAccessError(message) then
				return false, nil, nil, Legacy.NO_ACCESS, i
			end
			if i < Legacy.READ_ATTEMPTS then
				wait(i) -- backoff: 1 s, 2 s
			end
		end
		return false, nil, nil, lastErr, Legacy.READ_ATTEMPTS
	end

	local function quiet(at: number?): boolean
		return at == nil or now() - at >= Legacy.QUIET_SECONDS
	end

	function r.read(source: any, userId: number): (string, any, any)
		local verr = Legacy.validateSource(source)
		if verr then
			return "error", nil, { error = verr, attempts = 0 }
		end
		local kind = source.kind
		local vars = { userId = userId }
		local value: any, at: number? = nil, nil
		local attempts = 0
		local function failed(err: string?): (string, any, any)
			if err == Legacy.NO_ACCESS then
				log(
					`[StudWork.Legacy] DataStore API access is off in Studio: legacy source '{source.name}' NOT read; the import is skipped this session (no marker written). Enable API access to test the import in Studio.`
				)
				return "unavailable", nil, { error = err, attempts = attempts }
			end
			return "error", nil, { error = err, attempts = attempts }
		end
		if kind == "datastore2" and source.savingMethod ~= "Standard" then
			local storeName = source.name .. "/" .. tostring(userId)
			local ok, _key, n, err, tries = attempt(backend.latestOrdered, storeName, source.scope)
			attempts += tries
			if not ok then
				return failed(err)
			end
			if n == nil then
				return "none", nil, { attempts = attempts }
			end
			local ok2, v, a, err2, tries2 = attempt(
				backend.get,
				storeName,
				source.scope,
				tostring(if type(n) == "number" then math.floor(n) else n)
			)
			attempts += tries2
			if not ok2 then
				return failed(err2)
			end
			value, at = v, a
		else
			local key = if kind == "datastore2" then tostring(userId) else Legacy.expand(source.key, vars)
			local ok, v, a, err, tries = attempt(backend.get, source.name, source.scope, key)
			attempts += tries
			if not ok then
				return failed(err)
			end
			value, at = v, a
		end
		local info: any = { updatedAt = at, attempts = attempts }
		if value == nil then
			return "none", nil, info
		end
		if not quiet(at) then
			info.error =
				`written {math.floor(now() - (at :: number))} s ago (quiet window {Legacy.QUIET_SECONDS} s)`
			return "busy", nil, info
		end
		if kind == "profileservice" or kind == "profilestore" then
			if type(value) ~= "table" then
				info.error = `expected a {kind} record (table), got {type(value)}`
				return "error", nil, info
			end
			local meta = value.MetaData
			if meta ~= nil and type(meta) ~= "table" then
				info.error = "profile MetaData is not a table"
				return "error", nil, info
			end
			if meta and meta.ActiveSession ~= nil then
				local last = if type(meta.LastUpdate) == "number" then meta.LastUpdate else at
				if last == nil or now() - last < Legacy.SESSION_STALE_SECONDS then
					info.error = "profile session lock held by a live server"
					return "busy", nil, info
				end
			end
			if value.Data == nil then
				return "none", nil, info
			end
			if type(value.Data) ~= "table" then
				info.error = `profile Data is not a table ({type(value.Data)})`
				return "error", nil, info
			end
			return "found", value.Data, info
		end
		if kind == "datastore2" and source.combined ~= nil then
			if type(value) ~= "table" then
				info.error = `expected a DataStore2 combined table, got {type(value)}`
				return "error", nil, info
			end
			local out = {}
			local any = false
			for _, k in source.combined do
				if value[k] ~= nil then
					out[k] = value[k]
					any = true
				end
			end
			if not any then
				return "none", nil, info
			end
			return "found", out, info
		end
		return "found", value, info
	end

	function r.readAll(spec: any, userId: number): (string, any, any, string?)
		local single = Legacy.isSingleSource(spec)
		local names: { string } = {}
		if single then
			names = { "main" }
		else
			for name in spec do
				table.insert(names, name)
			end
			table.sort(names)
		end
		local sources: { [string]: any } = {}
		local values: { [string]: any } = {}
		local anyFound, anyBusy, anyUnavailable = false, false, false
		local firstErr: string? = nil
		for _, name in names do
			local src = if single then spec else spec[name]
			local status, value, info = r.read(src, userId)
			if status == "error" then
				return "error", nil, sources, `{name}: {tostring(info.error)}`
			elseif status == "busy" then
				anyBusy = true
				firstErr = firstErr or `{name}: {tostring(info.error)}`
			elseif status == "unavailable" then
				anyUnavailable = true
			elseif status == "found" then
				anyFound = true
				values[name] = value
			end
			sources[name] = { found = status == "found", updatedAt = info.updatedAt }
		end
		if anyBusy then
			return "busy", nil, sources, firstErr
		end
		if anyUnavailable then
			return "unavailable", nil, sources, nil
		end
		if not anyFound then
			return "none", nil, sources, nil
		end
		return "found", if single then values.main else values, sources, nil
	end

	return table.freeze(r)
end

return Legacy
