--!strict
--[[
	Per-module save sections + cross-module transactions (module-api.md §5.1, §5.2, §6).
	Framework internal: no module ever sees this table. Modules get only the scoped pieces that
	Context builds from it (ScopedData, ctx.tx, ctx.section, ctx.framework).

	Data.new(opts) -> data
	  opts.store      the save store (Store.memory() or the ProfileStore adapter, Store.luau):
	                    load(userId, player) -> root?      (may yield; error = load failure)
	                    save(userId, root)                  snapshot write (memory store)
	                    attach?(userId, root, hooks)        live root after a successful load;
	                                                        hooks.beforeSave(), hooks.sessionLost(),
	                                                        hooks.frameworkReplaced() (R22)
	                    reject?(userId)                     failed load: end without writing
	                    release?(userId, root)              final save + end session
	                    saveNow?(userId, root) -> boolean   yields until the save is confirmed
	                    send?(userId, message) -> boolean   cross-server message to a user's save
	                    onMessage?(userId, fn(message, processed))
	                    nudge?(userId)                      ask for an early save (faster delivery)
	  opts.modules    boot order: { ModuleRef } (only modules with `data` get a section)
	  opts.gameId     for the v1.2 split (game[gameId] -> its own section)
	  opts.now        () -> unix seconds
	  opts.log        (msg) -> ()        warnings
	  opts.require    require used for migrations folders (injected in tests)
	  opts.onSessionLost(player)          the save was taken by another server (kick)

	Load (all-or-nothing): framework migration on the whole root -> per enabled module: owner check
	(H5) -> section default or Migrate.run(section, _versions[key], data.version) -> reconcile
	missing top-level keys from data.default -> data.sanitize once -> record _owners/_versions.
	Then _framework.stats.sessions += 1 (sessions == 1 = first join ever). While onLoaded handlers
	run, _framework.lastSeen is still the PREVIOUS session's last save (Offline reads it); every
	save stamps lastSeen = now and prunes _framework.purchases to PURCHASES_CAP.
	Any failure: the player isn't loaded, nothing is ever saved for them (Decision 1, v1.1) and
	the caller kicks them. Sections of modules that aren't enabled are carried through untouched.
	A session taken by another server (ProfileStore "External", or a save that finds the lock
	gone) drops the record at once: nothing is written from this server again (autosave, leave,
	BindToClose, saveAsync / Shop settle and late tx.after all see no record), and the runtime
	kicks the player (opts.onSessionLost).

	Transactions (sealed handle, H1): runTx(player, fn, opts?) gives fn an opaque, frozen `tx` whose
	only readable keys are player / after / retryLater (+ opts.extras, used by Shop for the
	PurchaseTx fields). The working copies live in `txState`, a private table keyed by the handle;
	section(tx, key) is the only way in, and Context binds `key` to the calling module's data.key.
	txMeta(tx) is framework-internal bookkeeping (Shop: purchase/product; Compliance: rolls).
	Rules (kept from v1.1 Data.update):
	  - commit only when fn returns without error; an error discards everything and re-raises
	  - fn must not yield (YIELD_ERROR, discarded)
	  - one tx open on the call stack at a time: same player -> NESTED_ERROR; a DIFFERENT
	    player -> CROSS_PLAYER_ERROR: use tx.after to act on them once this one commits
	  - tx.after effects run, in order, only after commit (opts.deferAfter: returned instead, for
	    Shop, which runs them once the save is confirmed); tx.retryLater() discards the tx and
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
Data.PURCHASES_CAP = 200

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

-- Oldest receipts beyond `cap` are dropped (v1.2 Sanitize.prunePurchases). Returns how many.
local function prunePurchases(purchases: any, cap: number): number
	if type(purchases) ~= "table" then
		return 0
	end
	local list = {}
	for id, at in purchases do
		table.insert(list, { id = id, at = if type(at) == "number" then at else 0 })
	end
	if #list <= cap then
		return 0
	end
	table.sort(list, function(a, b)
		return a.at > b.at
	end)
	local removed = 0
	for i = cap + 1, #list do
		purchases[list[i].id] = nil
		removed += 1
	end
	return removed
end
Data.prunePurchases = prunePurchases

type Record = {
	player: any,
	root: { [string]: any },
	versions: { [string]: number },
	-- source = the committed section table the view was built from (Freeze.freezeShared)
	views: { [string]: { version: number, view: any, source: any } },
}

type TxState = {
	player: any,
	record: Record,
	working: { [string]: any },
	after: { () -> () },
	retry: boolean,
	meta: { [string]: any },
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
	local changeListeners: { (any) -> () } = {}
	local messageHandlers: { [string]: (any, any, () -> ()) -> () } = {}

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
			-- once a module has migrations, every version from its first
			-- migration up to data.version needs one (a forgotten file would silently skip a step)
			local missing = Migrate.gaps(migrations, ref.data.version)
			if #missing > 0 then
				table.insert(
					bootErrors,
					`{ref.name}: data.migrations has no migration {table.concat(missing, ", ")} (between its first migration and data.version {tostring(
						ref.data.version
					)}); add migrations/{string.format("%03d", missing[1])}_<name>.luau`
				)
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

	local function changed(player: any)
		for _, fn in changeListeners do
			local ok, err = pcall(fn :: any, player)
			if not ok then
				log("[StudWork] data change listener failed: " .. tostring(err))
			end
		end
	end

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
						`save section '{key}' belongs to module '{owner}', but module '{spec.name}' now claims it (data.key collision). Rename {spec.name}'s data.key, or declare data.adopts = "{owner}" if it really takes over that data`
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
			-- committed section tables are frozen: see runTx's commit
			root[key] = Freeze.deepFreeze(section)
			versions[key] = spec.data.version
			owners[key] = spec.name
		end
		if type(fw.stats) ~= "table" then
			fw.stats = {}
		end
		local sessions = fw.stats.sessions
		fw.stats.sessions = (if type(sessions) == "number" and sessions == sessions then sessions else 0) + 1
		prunePurchases(fw.purchases, Data.PURCHASES_CAP)
		return { player = player, root = root, versions = {}, views = {} }, nil
	end

	-- Stamped right before every write of this record (memory save, ProfileStore OnSave).
	local function beforeSave(record: Record)
		-- copy-on-write: committed tables are never mutated in place (the incremental read views
		-- rely on it, Freeze.freezeShared)
		local fw = table.clone(record.root._framework)
		fw.lastSeen = now()
		if type(fw.purchases) == "table" then
			local purchases = table.clone(fw.purchases)
			if prunePurchases(purchases, Data.PURCHASES_CAP) > 0 then
				fw.purchases = purchases
			end
		end
		record.root._framework = fw
		record.versions._framework = nextVersion()
	end

	-- Returns (true) or (false, reason). On failure the player must be kicked; nothing is saved.
	function d.load(player: any): (boolean, string?)
		if records[player] then
			return true, nil
		end
		local userId = userIdOf(player)
		local okLoad, raw = pcall(store.load, userId, player)
		if not okLoad then
			failed[player] = "load failed: " .. tostring(raw)
			if store.reject then
				pcall(store.reject, userId)
			end
			return false, failed[player]
		end
		local record, err = loadInto(player, raw)
		if record == nil then
			failed[player] = tostring(err)
			log(`[StudWork] data for {playerLabel(player)} not loaded: {tostring(err)}`)
			if store.reject then
				pcall(store.reject, userId)
			end
			return false, failed[player]
		end
		local loadedRecord: Record = record
		failed[player] = nil
		records[player] = loadedRecord
		if store.attach then
			store.attach(userId, loadedRecord.root, {
				beforeSave = function()
					if records[player] == loadedRecord then
						beforeSave(loadedRecord)
					end
				end,
				-- R22 (core-v1.3.1): the store replaced root._framework (saveNow's _saveSeq stamp)
				frameworkReplaced = function()
					if records[player] == loadedRecord then
						loadedRecord.versions._framework = nextVersion()
					end
				end,
				sessionEnded = function()
					if records[player] == loadedRecord then
						records[player] = nil -- the session is over: never write from this server again
						log(`[StudWork] save session of {playerLabel(player)} ended`)
					end
				end,
				sessionLost = function()
					if records[player] == loadedRecord then
						records[player] = nil -- never write from this server again
						log(`[StudWork] save session of {playerLabel(player)} was taken by another server`)
						if opts.onSessionLost then
							opts.onSessionLost(player)
						end
					end
				end,
			})
		end
		if store.onMessage then
			store.onMessage(userId, function(message: any, processed: () -> ())
				if records[player] ~= loadedRecord then
					return -- left / session ended: ProfileStore re-delivers next session
				end
				local owner = if type(message) == "table" then message.m else nil
				local handler = if type(owner) == "string" then messageHandlers[owner] else nil
				if handler == nil then
					if type(owner) ~= "string" then
						processed() -- not a framework message: drop it rather than re-deliver forever
					end
					return -- the owning module isn't enabled here: leave it queued
				end
				handler(player, message.p, processed)
			end)
		end
		for _, spec in specs do
			local listeners: { (any) -> () } = loadedListeners[spec.data.key] or {}
			for _, fn in listeners do
				local ok, e = pcall(fn :: any, player)
				if not ok then
					log(`[StudWork] {spec.name} onLoaded failed: {tostring(e)}`)
				end
			end
		end
		changed(player)
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
		beforeSave(record)
		store.save(userIdOf(player), Freeze.deepCopy(record.root))
		return true
	end

	-- Yields until the current data is saved (true) or the save failed / the player isn't loaded.
	function d.saveAsync(player: any): boolean
		local record = records[player]
		if record == nil then
			return false
		end
		if store.saveNow then
			local fw = record.root._framework
			local ok, saved = pcall(store.saveNow, userIdOf(player), record.root)
			-- R22 (core-v1.3.1): a store that replaced _framework without the frameworkReplaced
			-- hook still leaves no stale _framework view / replication behind
			if records[player] == record and record.root._framework ~= fw then
				record.versions._framework = nextVersion()
			end
			return ok and saved == true and records[player] == record
		end
		return d.save(player)
	end

	function d.release(player: any)
		local record = records[player]
		records[player] = nil
		failed[player] = nil
		if record == nil then
			return
		end
		beforeSave(record)
		if store.release then
			store.release(userIdOf(player), record.root)
		else
			store.save(userIdOf(player), Freeze.deepCopy(record.root))
		end
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

	function d.onChange(fn: (any) -> ())
		table.insert(changeListeners, fn)
	end

	function d.sectionVersion(player: any, key: string): number
		local record = records[player]
		return if record then record.versions[key] or 0 else 0
	end

	-- H2: frozen read view of one section, in EVERY environment (v1.2 did this only in Studio).
	-- Cost: a deep copy + freeze of the section, but only when its section version moved since
	-- the last view (cached per player per section), so repeated reads between commits are free.
	-- Re-check against the §17 Q6 budget (0.64 ms/tick at 50x100, +20% max) in v1.3.0.
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
			-- rebuilt sharing every still-equal subtree with the previous view (benchmark fix)
			local view = if hit
				then Freeze.freezeShared(value, hit.source, hit.view)
				else Freeze.freezeCopy(value)
			hit = { version = version, view = view, source = value }
			record.views[key] = hit
		end
		return hit.view
	end

	function d.frameworkField(player: any, field: string): any
		local record = records[player]
		if record == nil then
			error(`data for {playerLabel(player)} is not loaded`, 3)
		end
		local v = record.root._framework[field]
		return if type(v) == "table" then Freeze.freezeCopy(v) else v
	end

	-- Cross-server messages (ctx.data.messages): delivered to the recipient's save by the store,
	-- routed to the sending module's handler on the recipient's server.
	function d.sendMessage(owner: string, userId: number, payload: any): boolean
		if store.send == nil then
			return false
		end
		local ok, sent = pcall(store.send, userId, { m = owner, p = payload })
		if not ok then
			log(`[StudWork] message to {userId} failed: {tostring(sent)}`)
			return false
		end
		return sent == true
	end

	function d.onMessage(owner: string, fn: (player: any, payload: any, processed: () -> ()) -> ())
		if messageHandlers[owner] ~= nil then
			error(`{owner}: ctx.data.messages.onReceive is already set`, 3)
		end
		messageHandlers[owner] = fn
	end

	function d.nudge(userId: number)
		if store.nudge then
			pcall(store.nudge, userId)
		end
	end

	local function makeHandle(state: TxState, extras: { [string]: any }?): any
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
				if extras ~= nil and extras[key] ~= nil then
					return extras[key]
				end
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

	-- Framework-internal bookkeeping of an OPEN tx (never handed to modules).
	function d.txMeta(tx: any): { [string]: any }
		local state = txState[tx]
		if state == nil then
			error(Data.SEALED_POST_COMMIT, 3)
		end
		return state.meta
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

	-- opts: { extras?, meta?, deferAfter? }. Returns (committed, result, effects?) where effects is
	-- the tx.after list when opts.deferAfter (the caller runs it), else nil (already run).
	function d.runTx(player: any, fn: (tx: any) -> ...any, runOpts: any?): (boolean, any, any)
		if openTx ~= nil then
			local open = txState[openTx]
			if open.player == player then
				error(Data.NESTED_ERROR, 3)
			end
			error(Data.crossPlayerError(playerLabel(open.player)), 3)
		end
		local record = records[player]
		if record == nil then
			return false, nil, nil
		end
		local o = runOpts or {}
		local state: TxState = {
			player = player,
			record = record,
			working = {},
			after = {},
			retry = false,
			meta = if o.meta then table.clone(o.meta) else {},
		}
		local handle = makeHandle(state, o.extras)
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
		if coroutine.status(co) ~= "dead" then
			coroutine.close(co)
			error(Data.YIELD_ERROR, 3)
		end
		if state.retry then
			return false, nil, nil
		end
		if failure then
			if type(failure.value) == "string" then
				error(failure.trace, 0)
			end
			error(failure.value, 0)
		end
		local anyChange = false
		for key, w in state.working do
			if w == NO_SECTION then
				continue
			end
			-- structural sharing: unchanged subtrees keep the committed tables (benchmark fix)
			local merged, differs = Freeze.share(w, record.root[key])
			if differs then
				-- freeze what the commit adds (shared subtrees already are), so a
				-- reference kept from ctx.section(tx) can't change committed data after the tx
				-- ends; a late write raises "attempt to modify a readonly table"
				record.root[key] = Freeze.deepFreeze(merged)
				record.versions[key] = nextVersion()
				anyChange = true
			end
		end
		if anyChange then
			changed(player)
		end
		if o.deferAfter then
			return true, result, state.after
		end
		for _, effect in state.after do
			local ok, err = pcall(effect :: any)
			if not ok then
				log("[StudWork] post-commit effect failed: " .. tostring(err))
			end
		end
		return true, result, nil
	end

	function d.hasSection(key: string): boolean
		return byKey[key] ~= nil
	end

	return d
end

return Data
