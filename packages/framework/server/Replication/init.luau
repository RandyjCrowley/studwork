--!strict
--[[
	Framework Replication (module-api.md §10), ported from v1.2 core/server/Replication.
	Framework internal; modules see only ctx.replicate (Replication.forModule).

	What the owning client receives (never another player's state):
	  {
	    loaded = true,
	    framework = { paidRandomRestricted, activeEvents, odds, ... },     -- framework services
	    modules = {
	      Economy = { data = { currency = {...} }, extra = { ratePerSec = 12.5 } },
	      ...
	    },
	  }
	  data   the fields in the module's data.replicate list (minus serverOnly) from ITS section,
	         copied (Snapshot.copyShared: wire-safe, reusing the last copy of unchanged subtrees)
	         only when that section's version moved (M2: an unchanged section is the SAME table as last send, so
	         charm-sync's diff skips it; v1.3: so is every unchanged subtree of a changed one);
	  extra  ctx.replicate.set(player, key, value) / setAll(key, value), namespaced to the module.
	ctx.replicate.sent(player, key) -> the value of that key in the state last handed to the
	transport for this player (nil = never sent): StateSync is reliable and ordered, so the client
	has, or is about to apply, exactly that value (v1.2 N4: the luck-disclosure check).

	Transport (opts.makeSync(hooks) -> sync): sync.subscribe(player, state) on StateInit (next flush
	sends a full "init"), sync.set(player, state) on every rebuild, sync.remove(player),
	sync.flush() once per step; the sync calls hooks.sent(player) when a payload left for player.
	Live: charm-sync atoms + Blink StateSync (Platform.luau). Tests: a recording fake.

	Replication.new(opts): opts.modules (boot order refs), opts.data (framework Data),
	opts.isPlayer(player), opts.makeSync(hooks), opts.log(msg).
]]

local Snapshot = require(script.Snapshot)

local Replication = {}

Replication.MAX_KEY_LENGTH = 64

type ModuleSpec = { name: string, key: string, fields: { string } }

type Entry = {
	caches: { [string]: any },
	extra: { [string]: { [string]: any } },
	extraVersions: { [string]: number },
	built: { [string]: { m: any, data: any, shared: number, extra: number } },
	framework: { [string]: any },
	state: any,
	subscribed: boolean,
	sent: any,
}

local function checkKey(key: any, what: string)
	if type(key) ~= "string" or key == "" or #key > Replication.MAX_KEY_LENGTH then
		error(`{what}: key must be a non-empty string (<= {Replication.MAX_KEY_LENGTH} chars)`, 3)
	end
end

local function wire(value: any): any
	return if type(value) == "table" then Snapshot.copy(value) else value
end

function Replication.new(opts: any): any
	local data = opts.data
	local isPlayer: (any) -> boolean = opts.isPlayer
	local specs: { ModuleSpec } = {}
	for _, ref in opts.modules do
		local d = ref.data
		if d and type(d.replicate) == "table" and #d.replicate > 0 then
			local serverOnly: { [string]: boolean } = {}
			for _, f in d.serverOnly or {} do
				serverOnly[f] = true
			end
			local fields = {}
			for _, f in d.replicate do
				if not serverOnly[f] then
					table.insert(fields, f)
				end
			end
			table.insert(specs, { name = ref.name, key = d.key, fields = fields })
		end
	end

	local entries: { [any]: Entry } = {}
	local sharedModule: { [string]: { [string]: any } } = {}
	local sharedVersions: { [string]: number } = {}
	local sharedFramework: { [string]: any } = { paidRandomRestricted = true, activeEvents = {} }
	local dirty: { [any]: boolean } = {}
	local needsFlush = false

	local r: any = {}

	local sync = opts.makeSync({
		sent = function(player: any)
			local entry = entries[player]
			if entry ~= nil and entry.subscribed then
				entry.sent = entry.state
			end
		end,
	})

	local function entryFor(player: any): Entry?
		local entry = entries[player]
		if entry == nil then
			if not isPlayer(player) then
				return nil
			end
			entry = {
				caches = {},
				extra = {},
				extraVersions = {},
				built = {},
				framework = {},
				state = nil,
				subscribed = false,
				sent = nil,
			}
			entries[player] = entry
		end
		return entry
	end

	-- One module's part of the state. A module whose data copy, shared extra and per-player extra
	-- are all unchanged keeps the SAME table as last time, so charm-sync's diff skips it (no
	-- per-tick churn per module). `d` is the data copy, or false when there is none.
	local function moduleState(entry: Entry, name: string, d: any): any
		local sharedVersion = sharedVersions[name] or 0
		local extraVersion = entry.extraVersions[name] or 0
		local last = entry.built[name]
		if last ~= nil and last.data == d and last.shared == sharedVersion and last.extra == extraVersion then
			return last.m
		end
		local m: { [string]: any } = {}
		if d then
			m.data = d
		end
		local shared = sharedModule[name]
		local extra = entry.extra[name]
		if shared ~= nil or extra ~= nil then
			local merged = if shared ~= nil then table.clone(shared) else {}
			if extra ~= nil then
				for k, v in extra do
					merged[k] = v
				end
			end
			m.extra = merged
		end
		if last == nil then
			entry.built[name] = { m = m, data = d, shared = sharedVersion, extra = extraVersion }
		else
			last.m = m
			last.data = d
			last.shared = sharedVersion
			last.extra = extraVersion
		end
		return m
	end

	local function build(player: any, entry: Entry): any
		local loaded = data.isLoaded(player)
		local fw: { [string]: any } = table.clone(sharedFramework)
		for k, v in entry.framework do
			fw[k] = v
		end
		local modules: { [string]: any } = {}
		for _, spec in specs do
			local d: any = false -- false: the module has a replicated section but no data yet
			if loaded then
				local version = data.sectionVersion(player, spec.key)
				local cache = entry.caches[spec.name]
				if cache == nil or cache.version ~= version then
					local view = data.view(player, spec.key)
					local picked: { [string]: any } = {}
					if type(view) == "table" then
						for _, f in spec.fields do
							-- reuse the last copy of every unchanged subtree (benchmark fix)
							local copied = if cache and type(cache.view) == "table"
								then Snapshot.copyShared(view[f], cache.view[f], cache.data[f])
								else Snapshot.copy(view[f])
							if copied ~= nil then
								picked[f] = copied
							end
						end
					end
					cache = { version = version, data = picked, view = view }
					entry.caches[spec.name] = cache
				end
				d = cache.data
			end
			modules[spec.name] = moduleState(entry, spec.name, d)
		end
		for name in sharedModule do
			if modules[name] == nil then
				modules[name] = moduleState(entry, name, false)
			end
		end
		for name in entry.extra do
			if modules[name] == nil then
				modules[name] = moduleState(entry, name, false)
			end
		end
		return { loaded = loaded, framework = fw, modules = modules }
	end

	local function rebuild(player: any)
		local entry = entryFor(player)
		if entry == nil then
			return
		end
		entry.state = build(player, entry)
		if entry.subscribed then
			sync.set(player, entry.state)
			needsFlush = true
		end
	end

	function r.markDirty(player: any)
		if isPlayer(player) then
			dirty[player] = true
		end
	end

	local function markAll()
		for player in entries do
			dirty[player] = true
		end
	end

	-- StateInit: (re)subscribe -> the next flush sends a full snapshot.
	function r.subscribe(player: any)
		local entry = entryFor(player)
		if entry == nil then
			return
		end
		entry.state = build(player, entry)
		sync.subscribe(player, entry.state)
		entry.subscribed = true
		dirty[player] = nil
		needsFlush = true
	end

	function r.remove(player: any)
		if entries[player] ~= nil then
			sync.remove(player)
		end
		entries[player] = nil
		dirty[player] = nil
	end

	function r.step()
		if next(dirty) ~= nil then
			local batch = dirty
			dirty = {}
			for player in batch do
				if isPlayer(player) then
					rebuild(player)
				end
			end
		end
		if needsFlush then
			needsFlush = false
			sync.flush()
		end
	end

	function r.peek(player: any): any
		local entry = entries[player]
		return if entry then entry.state else nil
	end

	-- Framework-level fields (framework services only).
	function r.setFramework(player: any, key: string, value: any)
		local entry = entryFor(player)
		if entry == nil then
			return
		end
		entry.framework[key] = wire(value)
		r.markDirty(player)
	end

	function r.setFrameworkAll(key: string, value: any)
		sharedFramework[key] = wire(value)
		markAll()
	end

	function r.peekFramework(player: any, key: string): any
		local entry = entries[player]
		local v = if entry then entry.framework[key] else nil
		if v == nil then
			v = sharedFramework[key]
		end
		return v
	end

	function r.sentFramework(player: any, key: string): any
		local entry = entries[player]
		if entry == nil or not entry.subscribed or entry.sent == nil then
			return nil
		end
		return entry.sent.framework[key]
	end

	-- ctx.replicate for one module.
	function r.forModule(name: string): any
		return table.freeze({
			set = function(player: any, key: string, value: any)
				checkKey(key, "ctx.replicate.set")
				if typeof(player) ~= "Instance" and type(player) ~= "table" then
					return
				end
				local entry = entryFor(player)
				if entry == nil then
					return
				end
				local mine = entry.extra[name]
				if mine == nil then
					mine = {}
					entry.extra[name] = mine
				end
				if mine[key] ~= value or type(value) == "table" then
					mine[key] = wire(value)
					entry.extraVersions[name] = (entry.extraVersions[name] or 0) + 1
					r.markDirty(player)
				end
			end,
			setAll = function(key: string, value: any)
				checkKey(key, "ctx.replicate.setAll")
				local mine = sharedModule[name]
				if mine == nil then
					mine = {}
					sharedModule[name] = mine
				end
				mine[key] = wire(value)
				sharedVersions[name] = (sharedVersions[name] or 0) + 1
				markAll()
			end,
			sent = function(player: any, key: string): any
				local entry = entries[player]
				if entry == nil or not entry.subscribed or entry.sent == nil then
					return nil
				end
				local m = entry.sent.modules[name]
				local extra = m and m.extra
				return if extra then extra[key] else nil
			end,
		})
	end

	return r
end

return Replication
