--!strict
--[[
	Per-module save sections + cross-module transactions (module-api.md §5.1, §5.2, §6).
	Framework internal: no module ever sees this table. Modules get only the scoped pieces that
	Context builds from it (ScopedData, ctx.tx, ctx.section, ctx.framework).

	Data.new(opts) -> data
	  opts.store      { load(userId) -> root?, save(userId, root) }   (ProfileStore adapter or a mock)
	  opts.modules    boot order: { ModuleRef } (only modules with `data` get a section)
	  opts.gameId     for the v1.2 split (game[gameId] -> its own section)
	  opts.now        () -> unix seconds
	  opts.log        (msg) -> ()        warnings
	  opts.require    require used for migrations folders (injected in tests)

	Load (all-or-nothing): framework migration on the whole root -> per enabled module: owner check
	(H5) -> section default or Migrate.run(section, _versions[key], data.version) -> reconcile
	missing top-level keys from data.default -> data.sanitize once (M3) -> record _owners/_versions.
	Any failure: the player isn't loaded, nothing is ever saved for them (Decision 1, v1.1) and
	the caller kicks them. Sections of modules that aren't enabled are carried through untouched.

	Transactions (sealed handle, H1): runTx(player, fn) gives fn an opaque, frozen `tx` whose only
	readable keys are player / after / retryLater. The working copies live in `txState`, a private
	table keyed by the handle, inside this file; section(tx, key) is the only way in, and Context
	binds `key` to the calling module's own data.key. Rules (kept from v1.1 Data.update):
	  - commit only when fn returns without error; an error discards everything and re-raises
	  - fn must not yield (YIELD_ERROR, discarded)
	  - one tx open on the call stack at a time: same player -> NESTED_ERROR (L6); a DIFFERENT
	    player -> CROSS_PLAYER_ERROR (M1): use tx.after to act on them once this one commits
	  - tx.after effects run, in order, only after commit; tx.retryLater() discards the tx and
	    runTx returns (false, nil)
	  - only sections fn touched AND changed get a new section version
]]

local Shared = require(script.Parent.Shared)
local requireShared = require :: any -- see Shared.luau
local Freeze = requireShared(Shared.Freeze)
local Migrate = requireShared(Shared.Migrate)
local FrameworkSection = require(script.Parent.FrameworkSection)

local Data = {}

Data.YIELD_ERROR = "ctx.tx: fn must not yield (change discarded)"
Data.NESTED_ERROR =
	"nested ctx.tx for the same player: open one transaction and pass `tx` to txApi functions instead"
Data.SEALED_POST_COMMIT =
	"this tx is closed (it already committed or failed); ctx.section(tx) only works inside ctx.tx"

function Data.crossPlayerError(openFor: string): string
	return `tx open for {openFor}; use tx.after to act on another player once this one commits`
end

local function playerLabel(player: any): string
	local ok, name = pcall(function()
		return player.Name
	end)
	return if ok and name ~= nil then tostring(name) else tostring(player)
end

local function userIdOf(player: any): any
	return player.UserId
end

local clock = 0 -- global section-version clock, never repeats (as v1.2 Transaction)
local function nextVersion(): number
	clock += 1
	return clock
end

type Record = {
	player: any,
	root: { [string]: any },
	versions: { [string]: number },
	views: { [string]: { version: number, view: any } },
}

type TxState = {
	player: any,
	record: Record,
	working: { [string]: any },
	after: { () -> () },
	retry: boolean,
}

local NO_SECTION = newproxy(false)

function Data.new(opts: any): any
	local store = opts.store
	local now: () -> number = opts.now
	local log: (string) -> () = opts.log or warn
	local gameId: string? = opts.gameId
	local records: { [any]: Record } = {}
	local failed: { [any]: string } = {}
	local loadedListeners: { [string]: { (any) -> () } } = {}

	-- Per-module data specs in boot order, with migrations resolved once at boot.
	local specs: { { name: string, data: any, migrations: { [number]: any } } } = {}
	local byKey: { [string]: any } = {}
	local bootErrors: { string } = {}
	for _, ref in opts.modules do
		if ref.data then
			local migrations, errs = Migrate.fromFolder(ref.data.migrations, opts.require)
			for _, e in errs do
				table.insert(bootErrors, `{ref.name}: data.{e}`)
			end
			local spec = { name = ref.name, data = ref.data, migrations = migrations }
			table.insert(specs, spec)
			byKey[ref.data.key] = spec
		end
	end
	if #bootErrors > 0 then
		error("invalid module data:\n  - " .. table.concat(bootErrors, "\n  - "), 0)
	end

	-- private: tx handle -> state. Weak keys so a leaked handle doesn't pin a working copy.
	local txState: { [any]: TxState } = setmetatable({}, { __mode = "k" }) :: any
	local openTx: any = nil

	local d = {}

	local function loadInto(player: any, raw: any): (Record?, string?)
		local root, ferr = FrameworkSection.migrate(raw, gameId, now())
		if root == nil then
			return nil, ferr
		end
		local fw = root._framework
		local owners = fw._owners
		local versions = root._versions
		for _, spec in specs do
			local key = spec.data.key
			local owner = owners[key]
			if owner ~= nil and owner ~= spec.name then
				if spec.data.adopts == owner then
					log(
						`[StudWork] {spec.name} adopts save section '{key}' from module '{owner}' (data.adopts)`
					)
				else
					return nil,
						`save section '{key}' belongs to module '{owner}', but module '{spec.name}' now claims it (data.key collision, design review H5). Rename {spec.name}'s data.key, or declare data.adopts = "{owner}" if it really takes over that data`
				end
			end
			local section = root[key]
			if section == nil then
				section = Freeze.deepCopy(spec.data.default)
			else
				local from = Migrate.readVersion(versions[key], 0)
				local out, status, _, merr = Migrate.run(section, from, spec.data.version, spec.migrations)
				if status == "newer" then
					return nil,
						`save section '{key}' is version {from}, newer than {spec.name}'s data.version {spec.data.version}; not loading it`
				elseif status == "error" then
					return nil, `{spec.name} section '{key}': {tostring(merr)}`
				end
				section = out
				if type(section) == "table" then
					for k, v in spec.data.default do
						if section[k] == nil then
							section[k] = Freeze.deepCopy(v)
						end
					end
				end
			end
			if spec.data.sanitize then
				local ok, out = pcall(spec.data.sanitize, section)
				if not ok then
					return nil, `{spec.name} data.sanitize failed: {tostring(out)}`
				end
				if type(out) ~= "table" then
					return nil, `{spec.name} data.sanitize must return the section table, got {type(out)}`
				end
				section = out
			end
			root[key] = section
			versions[key] = spec.data.version
			owners[key] = spec.name
		end
		return { player = player, root = root, versions = {}, views = {} }, nil
	end

	-- Returns (true) or (false, reason). On failure the player must be kicked; nothing is saved.
	function d.load(player: any): (boolean, string?)
		if records[player] then
			return true, nil
		end
		local okLoad, raw = pcall(store.load, userIdOf(player))
		if not okLoad then
			failed[player] = "load failed: " .. tostring(raw)
			return false, failed[player]
		end
		local record, err = loadInto(player, raw)
		if record == nil then
			failed[player] = tostring(err)
			log(`[StudWork] data for {playerLabel(player)} not loaded: {tostring(err)}`)
			return false, failed[player]
		end
		failed[player] = nil
		records[player] = record
		for _, spec in specs do
			local listeners: { (any) -> () } = loadedListeners[spec.data.key] or {}
			for _, fn in listeners do
				local ok, e = pcall(fn :: any, player)
				if not ok then
					log(`[StudWork] {spec.name} onLoaded failed: {tostring(e)}`)
				end
			end
		end
		return true, nil
	end

	function d.isLoaded(player: any): boolean
		return records[player] ~= nil
	end

	function d.loadError(player: any): string?
		return failed[player]
	end

	function d.save(player: any): boolean
		local record = records[player]
		if record == nil then
			return false -- never loaded (or failed to load): never write over the stored save
		end
		record.root._framework.lastSeen = now()
		record.versions._framework = nextVersion()
		store.save(userIdOf(player), Freeze.deepCopy(record.root))
		return true
	end

	function d.release(player: any)
		d.save(player)
		records[player] = nil
		failed[player] = nil
	end

	function d.players(): { any }
		local out = {}
		for p in records do
			table.insert(out, p)
		end
		return out
	end

	function d.onLoaded(key: string, fn: (any) -> ())
		loadedListeners[key] = loadedListeners[key] or {}
		table.insert(loadedListeners[key], fn)
	end

	function d.sectionVersion(player: any, key: string): number
		local record = records[player]
		return if record then record.versions[key] or 0 else 0
	end

	-- H2: frozen read view of one section, in EVERY environment (v1.2 did this only in Studio).
	-- Cost: a deep copy + freeze of the section, but only when its section version moved since
	-- the last view (cached per player per section), so repeated reads between commits are free.
	-- Re-check against the §17 Q6 budget (0.64 ms/tick at 50x100, +20% max) in Phase 2 step 7.
	function d.view(player: any, key: string): any
		local record = records[player]
		if record == nil then
			error(`data for {playerLabel(player)} is not loaded (check ctx.data.isLoaded first)`, 3)
		end
		local value = record.root[key]
		if type(value) ~= "table" then
			return value
		end
		local version = record.versions[key] or 0
		local hit = record.views[key]
		if hit == nil or hit.version ~= version then
			hit = { version = version, view = Freeze.freezeCopy(value) }
			record.views[key] = hit
		end
		return hit.view
	end

	function d.frameworkField(player: any, field: string): any
		local record = records[player]
		if record == nil then
			error(`data for {playerLabel(player)} is not loaded`, 3)
		end
		return record.root._framework[field]
	end

	local function makeHandle(state: TxState): any
		local after = function(fn: () -> ())
			if type(fn) ~= "function" then
				error("tx.after expects a function", 2)
			end
			table.insert(state.after, fn)
		end
		local retryLater = function()
			state.retry = true
		end
		local player = state.player
		local meta = table.freeze({
			__index = function(_, key: any): any
				if key == "player" then
					return player
				elseif key == "after" then
					return after
				elseif key == "retryLater" then
					return retryLater
				end
				error(
					`tx has no field '{tostring(key)}': tx is a sealed handle (player, after, retryLater); use ctx.section(tx) for your own section`,
					2
				)
			end,
			__newindex = function(_, key: any)
				error(`tx is read-only (tried to set '{tostring(key)}')`, 2)
			end,
			__iter = function()
				error("tx cannot be iterated: it is a sealed handle; use ctx.section(tx)", 2)
			end,
			__tostring = function()
				return `Tx({playerLabel(player)})`
			end,
		})
		return table.freeze(setmetatable({}, meta :: any))
	end

	function d.isTxHandle(tx: any): boolean
		return txState[tx] ~= nil
	end

	-- The calling module's working copy of `key` inside an open tx (copy on first access).
	function d.section(tx: any, key: string): any
		local state = txState[tx]
		if state == nil then
			error(Data.SEALED_POST_COMMIT, 3)
		end
		local w = state.working[key]
		if w ~= nil then
			return if w == NO_SECTION then nil else w
		end
		local v = state.record.root[key]
		if v == nil then
			state.working[key] = NO_SECTION
			return nil
		end
		local copy = Freeze.deepCopy(v)
		state.working[key] = copy
		return copy
	end

	function d.openTxPlayer(): any
		local state = if openTx then txState[openTx] else nil
		return if state then state.player else nil
	end

	function d.runTx(player: any, fn: (tx: any) -> ...any): (boolean, any)
		if openTx ~= nil then
			local open = txState[openTx]
			if open.player == player then
				error(Data.NESTED_ERROR, 3)
			end
			error(Data.crossPlayerError(playerLabel(open.player)), 3)
		end
		local record = records[player]
		if record == nil then
			return false, nil
		end
		local state: TxState = { player = player, record = record, working = {}, after = {}, retry = false }
		local handle = makeHandle(state)
		txState[handle] = state
		openTx = handle

		local failure: { value: any, trace: string }? = nil
		local result: any = nil
		local co = coroutine.create(function()
			xpcall(function()
				result = fn(handle)
			end, function(e: any)
				failure = { value = e, trace = tostring(e) .. "\n[ctx.tx] traceback:\n" .. debug.traceback() }
			end)
		end)
		local resumed, resumeErr = coroutine.resume(co)
		openTx = nil
		txState[handle] = nil -- the handle is dead from here on: section(tx) errors
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
			error(Data.YIELD_ERROR, 3)
		end
		if state.retry then
			return false, nil
		end
		for key, w in state.working do
			if w == NO_SECTION then
				continue
			end
			if not Freeze.deepEqual(w, record.root[key]) then
				record.root[key] = w
				record.versions[key] = nextVersion()
			end
		end
		for _, effect in state.after do
			local ok, err = pcall(effect :: any)
			if not ok then
				log("[StudWork] post-commit effect failed: " .. tostring(err))
			end
		end
		return true, result
	end

	function d.hasSection(key: string): boolean
		return byKey[key] ~= nil
	end

	return d
end

return Data
