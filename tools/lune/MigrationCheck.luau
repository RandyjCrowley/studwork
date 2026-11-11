--!strict
--[[
	tools/lune/MigrationCheck: the pure logic of tools/test-migration (StudWork v1.6.0,
	docs/framework/adopting.md §3 "tools/test-migration"). No I/O: test-migration.luau finds the
	fixtures and MigrationRun.luau runs them through the game's real import in the sim.

	FIXTURE FORMAT: <module>/tests/legacy/*.json (or --fixtures <dir>). Synthetic data only: no
	real player's save, user id or name.

	  {
	    "description": "a mid-game player",           optional, shown in the output
	    "import":  "v1-save",                          optional: the importLegacy id (default: the
	                                                   module's import, or the game's only one)
	    "userId":  1001,                               optional synthetic user id (default 1001)
	    "old":     { ... },                            the OLD save value, exactly as the old game
	                                                   stored it in the import's source (for a
	                                                   ProfileService/ProfileStore source: the
	                                                   profile's Data; for DataStore2 combined: the
	                                                   combined table; for a map of sources:
	                                                   { <sourceName> = value, ... })
	    "expect":  { "<old.path>": "<section.path>" | { "items": "<section.path>" } },
	        every leaf of `old` must be covered by one entry (an entry covers its path and
	        everything under it). A string target: the value at <section.path> in the StudWork
	        save (`<dataKey>.<field>...`, e.g. "economy.currency.Coins") must equal the old value
	        (tables compared deeply). { "items": path }: the old value is a list (or map) of item
	        ids and the inventory map/list at path holds exactly those ids (by `itemId`), count
	        included.
	    "dropped": { "<old.path>": "<reason>" },       old fields deliberately not brought over
	    "changed": { ... },                            optional: the old save as an old server
	                                                   changed it after the import (check 5)
	    "afterMerge": { "<section.path>": <value> },   expected values after the merge
	    "sold":    { "<old.path>": "currency" | "items" },   fields a product sold (check 7)
	    "overCap": { "path": "<old.path>", "count": 60 }     optional (check 6): that list is
	                                                   grown to `count` entries (its items repeated)
	  }
	Paths use dots; list indexes are numbers ("inventory.1"). Keys containing dots aren't
	addressable (rename them in `old`'s description instead).

	The source (where the runner stores `old`) is the registered importLegacy's own source; the
	runner writes it in that source's format (MigrationCheck.seedOps).

	API
	  validate(fixture) -> { string }                 schema errors (empty = valid)
	  leaves(value, prefix?) -> { { path, value } }   every leaf (an empty table is a leaf)
	  get(root, path) -> any
	  coverage(old, fixture) -> { string }            check 1a: leaves neither expected nor dropped
	  compare(old, saved, fixture) -> { string }      check 1: coverage + every expect matches
	  afterMerge(saved, fixture) -> { string }        check 5 expectations
	  checkSold(fixture, paidCurrencies, itemTag) -> { string }   check 7
	  withoutField(old, key) -> table                 check 4 (a deep copy without one field)
	  inflate(old, path, count) -> table              check 6
	  seedOps(source, userId, value, at) -> { op }    how the old value is stored per source kind:
	      { op = "set", name, key, value, at, scope? } | { op = "setOrdered", name, key, n, scope? }
	  stable(saved) -> table                          the parts of a save a rejoin must not change
	  diff(a, b, prefix?) -> { string }               field-level differences
	  itemCount(saved, fixture) -> (number?, string?) the items target count (check 6)
]]

local MigrationCheck = {}

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end
MigrationCheck.deepCopy = deepCopy

local function sortedKeys(t: { [any]: any }): { any }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function join(prefix: string?, key: any): string
	local k = tostring(key)
	return if prefix == nil or prefix == "" then k else prefix .. "." .. k
end

function MigrationCheck.leaves(value: any, prefix: string?): { { path: string, value: any } }
	local out = {}
	local function walk(v: any, path: string)
		if type(v) == "table" and next(v) ~= nil then
			for _, k in sortedKeys(v) do
				walk(v[k], join(path, k))
			end
		else
			table.insert(out, { path = path, value = v })
		end
	end
	if type(value) == "table" then
		for _, k in sortedKeys(value) do
			walk(value[k], join(prefix, k))
		end
	elseif prefix ~= nil then
		table.insert(out, { path = prefix, value = value })
	end
	return out
end

function MigrationCheck.get(root: any, path: string): any
	local node = root
	for part in string.gmatch(path, "[^%.]+") do
		if type(node) ~= "table" then
			return nil
		end
		local v = node[part]
		if v == nil then
			local n = tonumber(part)
			if n ~= nil then
				v = node[n]
			end
		end
		node = v
	end
	return node
end

local function covers(entry: string, path: string): boolean
	return path == entry or string.sub(path, 1, #entry + 1) == entry .. "."
end

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
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
MigrationCheck.deepEqual = deepEqual

local function show(v: any): string
	if type(v) == "string" then
		return string.format("%q", v)
	elseif type(v) ~= "table" then
		return tostring(v)
	end
	local parts = {}
	for _, k in sortedKeys(v) do
		table.insert(parts, tostring(k) .. "=" .. show(v[k]))
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end
MigrationCheck.show = show

function MigrationCheck.validate(f: any): { string }
	local errs = {}
	if type(f) ~= "table" then
		return { "a fixture is a JSON object" }
	end
	if type(f.old) ~= "table" then
		table.insert(errs, "`old` (the old save, a JSON object) is required")
	end
	if type(f.expect) ~= "table" then
		table.insert(errs, "`expect` (old path -> StudWork save path) is required")
	else
		for k, v in f.expect do
			if type(k) ~= "string" then
				table.insert(errs, "`expect` keys are old-save paths")
			elseif type(v) == "table" then
				if type(v.items) ~= "string" then
					table.insert(errs, `expect["{k}"]: a table target must be \{ "items": "<path>" \}`)
				end
			elseif type(v) ~= "string" then
				table.insert(errs, `expect["{k}"] must be a save path string or \{ "items": path \}`)
			end
		end
	end
	if f.dropped ~= nil then
		if type(f.dropped) ~= "table" then
			table.insert(errs, "`dropped` is a map of old path -> reason")
		else
			for k, v in f.dropped do
				if type(v) ~= "string" or v == "" then
					table.insert(errs, `dropped["{tostring(k)}"] needs a reason`)
				end
			end
		end
	end
	if f.changed ~= nil and type(f.changed) ~= "table" then
		table.insert(errs, "`changed` is the old save after an old-server change (a JSON object)")
	end
	if f.afterMerge ~= nil and (type(f.afterMerge) ~= "table" or f.changed == nil) then
		table.insert(errs, "`afterMerge` is a map of save path -> value, and needs `changed`")
	end
	if f.sold ~= nil then
		if type(f.sold) ~= "table" then
			table.insert(errs, '`sold` is a map of old path -> "currency" | "items"')
		else
			for k, v in f.sold do
				if v ~= "currency" and v ~= "items" then
					table.insert(errs, `sold["{tostring(k)}"] must be "currency" or "items"`)
				end
			end
		end
	end
	if f.overCap ~= nil then
		local o = f.overCap
		if type(o) ~= "table" or type(o.path) ~= "string" or type(o.count) ~= "number" or o.count < 1 then
			table.insert(errs, '`overCap` is { "path": "<old list path>", "count": n }')
		end
	end
	if
		f.userId ~= nil and (type(f.userId) ~= "number" or f.userId < 1 or f.userId ~= math.floor(f.userId))
	then
		table.insert(errs, "`userId` must be a whole number (synthetic)")
	end
	if f.import ~= nil and type(f.import) ~= "string" then
		table.insert(errs, "`import` is an importLegacy id")
	end
	return errs
end

function MigrationCheck.coverage(old: any, f: any): { string }
	local errs = {}
	for _, leaf in MigrationCheck.leaves(old) do
		local ok = false
		for k in f.expect or {} do
			if covers(k, leaf.path) then
				ok = true
				break
			end
		end
		if not ok then
			for k in f.dropped or {} do
				if covers(k, leaf.path) then
					ok = true
					break
				end
			end
		end
		if not ok then
			table.insert(
				errs,
				`old field '{leaf.path}' ({show(leaf.value)}) is neither in expect nor in dropped (with a reason): it would be lost`
			)
		end
	end
	return errs
end

local function itemIds(v: any): { [string]: number }?
	if type(v) ~= "table" then
		return nil
	end
	local out: { [string]: number } = {}
	for _, x in v do
		local id = if type(x) == "table" then x.itemId else x
		if type(id) ~= "string" then
			return nil
		end
		out[id] = (out[id] or 0) + 1
	end
	return out
end

function MigrationCheck.compare(old: any, saved: any, f: any): { string }
	local errs = MigrationCheck.coverage(old, f)
	if type(saved) ~= "table" then
		table.insert(errs, "no StudWork save was written")
		return errs
	end
	for _, k in sortedKeys(f.expect or {}) do
		local target = f.expect[k]
		local was = MigrationCheck.get(old, k)
		if was == nil then
			continue -- a partial fixture: nothing to compare
		end
		if type(target) == "table" then
			local want = itemIds(was)
			local got = itemIds(MigrationCheck.get(saved, target.items))
			if want == nil then
				table.insert(errs, `old '{k}' is not a list of item ids ({show(was)})`)
			elseif got == nil then
				table.insert(errs, `'{k}' -> '{target.items}': no item list there in the StudWork save`)
			elseif not deepEqual(want, got) then
				table.insert(
					errs,
					`'{k}' -> '{target.items}': items differ: old {show(want)}, StudWork {show(got)}`
				)
			end
		else
			local now = MigrationCheck.get(saved, target)
			if not deepEqual(was, now) then
				table.insert(errs, `'{k}' -> '{target}': old {show(was)}, StudWork {show(now)}`)
			end
		end
	end
	return errs
end

function MigrationCheck.afterMerge(saved: any, f: any): { string }
	local errs = {}
	for _, path in sortedKeys(f.afterMerge or {}) do
		local want = f.afterMerge[path]
		local got = MigrationCheck.get(saved, path)
		if not deepEqual(want, got) then
			table.insert(errs, `after merge '{path}': expected {show(want)}, got {show(got)}`)
		end
	end
	return errs
end

function MigrationCheck.checkSold(f: any, paidCurrencies: { string }, itemTag: string): { string }
	local errs = {}
	local paid: { [string]: boolean } = {}
	for _, c in paidCurrencies do
		paid[c] = true
	end
	for _, path in sortedKeys(f.sold or {}) do
		local kind = f.sold[path]
		if kind == "currency" then
			local target = (f.expect or {})[path]
			if type(target) ~= "string" then
				table.insert(errs, `sold '{path}': map it in expect to the currency it becomes`)
			else
				local currency = string.match(target, "([^%.]+)$") or target
				if not paid[currency] then
					table.insert(
						errs,
						`sold '{path}' becomes currency '{currency}', which is not in GameConfig.compliance.paidCurrencies (a sold currency must stay paid)`
					)
				end
			end
		elseif kind == "items" and itemTag ~= "paid" then
			table.insert(
				errs,
				`sold '{path}' lists items, but the import's itemTag is "{itemTag}" (sold items must be tagged paid: itemTag = "paid")`
			)
		end
	end
	return errs
end

function MigrationCheck.withoutField(old: any, key: any): any
	local copy = deepCopy(old)
	copy[key] = nil
	return copy
end

function MigrationCheck.inflate(old: any, path: string, count: number): (any, string?)
	local copy = deepCopy(old)
	local list = MigrationCheck.get(copy, path)
	if type(list) ~= "table" or #list == 0 then
		return copy, `overCap.path '{path}' is not a non-empty list in old`
	end
	local base = #list
	for i = base + 1, count do
		list[i] = deepCopy(list[((i - 1) % base) + 1])
	end
	return copy, nil
end

-- The overCap list's mapped items target (an expect entry covering overCap.path with { items }).
function MigrationCheck.itemsTarget(f: any): string?
	local o = f.overCap
	if o == nil then
		return nil
	end
	local t = (f.expect or {})[o.path]
	return if type(t) == "table" then t.items else nil
end

function MigrationCheck.itemCount(saved: any, path: string): number
	local n = 0
	for _ in (MigrationCheck.get(saved, path) or {}) :: any do
		n += 1
	end
	return n
end

local function expandKey(pattern: string, userId: number): string
	return (string.gsub(pattern, "{userId}", tostring(userId)))
end

function MigrationCheck.seedOps(source: any, userId: number, value: any, at: number): { any }
	local ops = {}
	if type(source) ~= "table" then
		return ops
	end
	if source.kind == nil then
		-- a map of sources: value = { [name] = value }
		for _, name in sortedKeys(source) do
			local v = if type(value) == "table" then value[name] else nil
			if v ~= nil then
				for _, op in MigrationCheck.seedOps(source[name], userId, v, at) do
					table.insert(ops, op)
				end
			end
		end
		return ops
	end
	local kind = source.kind
	if kind == "datastore" then
		table.insert(ops, {
			op = "set",
			name = source.name,
			key = expandKey(source.key, userId),
			value = deepCopy(value),
			at = at,
			scope = source.scope,
		})
	elseif kind == "profileservice" or kind == "profilestore" then
		table.insert(ops, {
			op = "set",
			name = source.name,
			key = expandKey(source.key, userId),
			value = {
				Data = deepCopy(value),
				MetaData = { ProfileCreateTime = at, SessionLoadCount = 1, LastUpdate = at },
				GlobalUpdates = { 0, {} },
				RobloxMetaData = {},
				UserIds = { userId },
			},
			at = at,
			scope = source.scope,
		})
	elseif kind == "datastore2" then
		if source.savingMethod == "Standard" then
			table.insert(ops, {
				op = "set",
				name = source.name,
				key = tostring(userId),
				value = deepCopy(value),
				at = at,
				scope = source.scope,
			})
		else
			local storeName = source.name .. "/" .. tostring(userId)
			table.insert(ops, { op = "setOrdered", name = storeName, key = "1", n = 1, scope = source.scope })
			table.insert(ops, {
				op = "set",
				name = storeName,
				key = "1",
				value = deepCopy(value),
				at = at,
				scope = source.scope,
			})
		end
	end
	return ops
end

-- What a rejoin must leave unchanged: every module section, plus the import markers and the old
-- receipts. (lastSeen, stats, funnel are the framework's per-session bookkeeping.)
function MigrationCheck.stable(saved: any): any
	if type(saved) ~= "table" then
		return saved
	end
	local out = {}
	for k, v in saved do
		if k ~= "_framework" and k ~= "_versions" then
			out[k] = deepCopy(v)
		end
	end
	local fw = saved._framework
	if type(fw) == "table" then
		out._framework = { imports = deepCopy(fw.imports), legacyPurchases = deepCopy(fw.legacyPurchases) }
	end
	return out
end

-- Item instances get a fresh uid / acquiredAt per import: compare inventories by content.
function MigrationCheck.diff(a: any, b: any, prefix: string?): { string }
	local out = {}
	if type(a) == "table" and type(b) == "table" then
		local seen: { [any]: boolean } = {}
		for _, k in sortedKeys(a) do
			seen[k] = true
			for _, d in MigrationCheck.diff(a[k], b[k], join(prefix, k)) do
				table.insert(out, d)
			end
		end
		for _, k in sortedKeys(b) do
			if not seen[k] then
				table.insert(out, `{join(prefix, k)}: (none) -> {show(b[k])}`)
			end
		end
		return out
	end
	if a ~= b then
		table.insert(out, `{prefix or "(root)"}: {show(a)} -> {show(b)}`)
	end
	return out
end

return MigrationCheck
