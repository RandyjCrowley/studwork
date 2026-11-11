--!strict
--[[
	Framework shared store (v1.3.0): `ctx.data.shared`, a small durable key-value
	store every server of the experience shares. One framework-owned DataStore
	("StudWorkShared_<gameId>", "_Studio" suffix in Studio); every key is prefixed with the owning
	module's name, so a module can only read or write its own keys.

	  ctx.data.shared.update(key, fn(old) -> new) -> (ok: boolean, new: any?)

	Atomic read-modify-write across servers (DataStore UpdateAsync). `fn` may run more than once
	(UpdateAsync re-runs it on a conflict), so it must only compute the new value from `old`.
	Returning nil deletes the key. It yields: call it from a thread (never in init/start's body).
	A failing backend call is retried (RETRIES times, backoff BACKOFF * 2^n seconds); the final
	failure returns (false, nil) and logs once per call. An error inside `fn` is not retried.

	Backends (backend.update(fullKey, transform(old) -> (write: boolean, new)) -> new, may error):
	  SharedStore.memory()            one process (tests, Platform.inert, Studio without API access)
	  SharedStore.dataStore(service, name, opts?)
	                                  DataStoreService:GetDataStore(name):UpdateAsync. opts.isStudio
	                                  + opts.log: in Studio an access error (no API access / place
	                                  not published) switches to memory once, warned (like Data).
	The multi-server sim passes its World's mock DataStoreService, so the store is genuinely shared
	between sim servers and takes the World's failure injection (world:failNext / failFor).

	DataStore UpdateAsync can't delete (returning nil cancels the write), so a deleted key is
	stored as the tombstone { ["$deleted"] = true } and read back as nil.
]]

local SharedStore = {}

SharedStore.RETRIES = 3
SharedStore.BACKOFF = 1
SharedStore.MAX_KEY_LENGTH = 50 -- DataStore key limit (module name + "/" + key)
SharedStore.TOMBSTONE = "$deleted"

local function isTombstone(value: any): boolean
	return type(value) == "table" and value[SharedStore.TOMBSTONE] == true
end

function SharedStore.memory(): any
	local values: { [string]: any } = {}
	local b: any = { values = values, calls = 0 }
	function b.update(fullKey: string, transform: (any) -> (boolean, any)): any
		b.calls += 1
		local write, new = transform(values[fullKey])
		if write then
			values[fullKey] = new
		end
		return values[fullKey]
	end
	return b
end

local function looksLikeNoAccess(err: any): boolean
	local msg = string.lower(tostring(err))
	return string.find(msg, "403", 1, true) ~= nil
		or string.find(msg, "studio access", 1, true) ~= nil
		or string.find(msg, "api services", 1, true) ~= nil
		or string.find(msg, "publish", 1, true) ~= nil
end

function SharedStore.dataStore(service: any, name: string, opts: any?): any
	local o = opts or {}
	local store: any = nil
	local fallback: any = nil
	local b: any = {}
	function b.update(fullKey: string, transform: (any) -> (boolean, any)): any
		if fallback then
			return fallback.update(fullKey, transform)
		end
		local ok, result = pcall(function(): any
			if store == nil then
				store = service:GetDataStore(name)
			end
			return store:UpdateAsync(fullKey, function(old: any): any
				local write, new = transform(old)
				if not write then
					return nil -- cancel: nothing changes
				end
				return new
			end)
		end)
		if ok then
			return result
		end
		if o.isStudio and looksLikeNoAccess(result) then
			fallback = SharedStore.memory()
			if o.log then
				o.log(
					`[StudWork.Shared] DataStore API unavailable in Studio ({tostring(result)}); using an in-memory shared store - nothing persists or crosses servers.`
				)
			end
			return fallback.update(fullKey, transform)
		end
		error(result, 0)
	end
	return b
end

-- opts: backend, wait(seconds), log(msg)
function SharedStore.new(opts: any): any
	local backend = opts.backend
	local wait: (number) -> () = opts.wait or function(_s: number) end
	local log: (string) -> () = opts.log or function(_m: string) end
	local self: any = { backend = backend }

	function self.forModule(moduleName: string, assertUsable: (() -> ())?): any
		local prefix = moduleName .. "/"
		local function update(key: string, fn: (old: any) -> any): (boolean, any)
			if assertUsable then
				assertUsable()
			end
			assert(
				type(key) == "string" and key ~= "",
				"ctx.data.shared.update: key must be a non-empty string"
			)
			assert(type(fn) == "function", "ctx.data.shared.update: fn must be a function")
			local fullKey = prefix .. key
			assert(
				#fullKey <= SharedStore.MAX_KEY_LENGTH,
				`ctx.data.shared.update: key '{fullKey}' is longer than {SharedStore.MAX_KEY_LENGTH} characters`
			)
			local fnError: any = nil
			local function transform(raw: any): (boolean, any)
				local old = if isTombstone(raw) then nil else raw
				local ok, new = pcall(fn, old)
				if not ok then
					fnError = new
					return false, nil
				end
				if new == nil then
					if old == nil then
						return false, nil -- nothing to delete
					end
					return true, { [SharedStore.TOMBSTONE] = true }
				end
				return true, new
			end
			local lastErr: any = nil
			for attempt = 0, SharedStore.RETRIES do
				fnError = nil
				local ok, result = pcall(backend.update, fullKey, transform)
				if fnError ~= nil then
					log(`[StudWork.Shared] {moduleName}: update '{key}' failed in fn: {tostring(fnError)}`)
					return false, nil
				end
				if ok then
					return true, if isTombstone(result) then nil else result
				end
				lastErr = result
				if attempt < SharedStore.RETRIES then
					wait(SharedStore.BACKOFF * 2 ^ attempt)
				end
			end
			log(
				`[StudWork.Shared] {moduleName}: update '{key}' failed after {SharedStore.RETRIES + 1} tries: {tostring(
					lastErr
				)}`
			)
			return false, nil
		end
		return table.freeze({ update = update })
	end

	return self
end

return SharedStore
