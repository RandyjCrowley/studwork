--!strict
--[[
	Pure Data.update transaction (L6). OWNED BY AGENT A. No Roblox globals; tested in Lune.

	Transaction.newState() -> State          per-player: running flag + per-section versions.
	Transaction.run(state, root, fn, label?)  runs fn(proxy) and commits into `root` only when fn
	                                          returned without error and without yielding.

	The proxy (copy-on-first-read, per top-level section):
	  - proxy.section where root.section is a table -> deep copy of just that section (cached for
	    the rest of fn). Untouched sections are never copied (Economy's income tick copies only
	    currency + stats).
	  - proxy.section = value -> recorded (scalars like lastSeen / rebirths, or a whole new table
	    such as Rebirth's `data.inventory = {}`); nil deletes on commit.
	  - `for k, v in proxy` works (__iter): root keys plus keys written in fn.
	  - rawget/next/table.clone on the proxy do NOT work (it is an empty table with a metatable).
	On success every written/copied section is written back into `root` (root's identity never
	changes: ProfileStore's profile.Data points at it). A section whose working value is deep-equal to the original keeps its original table and version. Every changed
	section's version moves to a new global, strictly increasing number.
	On error: nothing is written, the error is re-raised (string errors get a traceback of fn's
	thread; table errors are re-raised as-is so sentinels survive).
	On yield: the thread is closed, nothing is written, error YIELD_ERROR.
	A second run on the same state while one is running errors with NESTED_ERROR.
]]

local Transaction = {}

Transaction.YIELD_ERROR = "Data.update: fn must not yield (change discarded)"
Transaction.NESTED_ERROR =
	"nested Data.update for the same player: open one transaction and use *Into functions instead"

export type State = {
	running: boolean,
	versions: { [string]: number },
}

local clock = 0 -- global, so versions never repeat across sessions/players

local function nextVersion(): number
	clock += 1
	return clock
end

function Transaction.newState(): State
	return { running = false, versions = {} }
end

function Transaction.version(state: State, section: string): number
	return state.versions[section] or 0
end

-- Data's own direct writes (lastSeen in OnSave, the save stamp in stats, console reset).
function Transaction.bump(state: State, section: string)
	state.versions[section] = nextVersion()
end

function Transaction.bumpAll(state: State, root: { [string]: any })
	for key in root do
		if type(key) == "string" then
			Transaction.bump(state, key)
		end
	end
end

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

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
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

local NONE = table.freeze({}) -- marks "assigned nil" in the write set

function Transaction.run(state: State, root: { [string]: any }, fn: (data: any) -> ()): { string }
	if state.running then
		error(Transaction.NESTED_ERROR, 3)
	end
	local writes: { [any]: any } = {} -- key -> working value (or NONE)

	local proxy = setmetatable({}, {
		__index = function(_, key)
			local w = writes[key]
			if w ~= nil then
				return if w == NONE then nil else w
			end
			local v = root[key]
			if type(v) == "table" then
				local copy = deepCopy(v)
				writes[key] = copy
				return copy
			end
			return v
		end,
		__newindex = function(_, key, value)
			writes[key] = if value == nil then NONE else value
		end,
		__iter = function(self: any)
			local keys = {}
			for k in root do
				table.insert(keys, k)
			end
			for k in writes do
				if root[k] == nil then
					table.insert(keys, k)
				end
			end
			local i = 0
			return function(): (any, any)
				while true do
					i += 1
					local k = keys[i]
					if k == nil then
						return nil, nil
					end
					local v = self[k]
					if v ~= nil then
						return k, v
					end
				end
			end
		end,
	})

	state.running = true
	-- xpcall inside the thread keeps the raw error value (table sentinels) and fn's traceback.
	local failure: { value: any, trace: string }? = nil
	local co = coroutine.create(function()
		xpcall(fn, function(e: any)
			failure =
				{ value = e, trace = tostring(e) .. "\n[Data.update] traceback:\n" .. debug.traceback() }
		end, proxy)
	end)
	local resumed, resumeErr = coroutine.resume(co)
	state.running = false
	if not resumed then
		error(resumeErr, 0)
	end
	if failure then
		if type(failure.value) == "string" then
			error(failure.trace, 0)
		end
		error(failure.value, 0)
	end
	if coroutine.status(co) ~= "dead" then
		coroutine.close(co)
		error(Transaction.YIELD_ERROR, 3)
	end

	-- Commit.
	local changed: { string } = {}
	for key, w in writes do
		local value = if w == NONE then nil else w
		local original = root[key]
		if not deepEqual(value, original) then
			root[key] = value
			if type(key) == "string" then
				state.versions[key] = nextVersion()
				table.insert(changed, key)
			end
		end
	end
	return changed
end

return Transaction
