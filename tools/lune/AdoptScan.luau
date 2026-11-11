--!nocheck
--[[
	tools/lune/AdoptScan.luau (StudWork v1.6.0, docs/framework/adopting.md §1): pure static scanners
	over ONE script's source text, used by tools/adopt --audit / --verify (AdoptAudit.luau).

	Zero requires (specs load it through the test harness). Detection is heuristic, never a parser:

	  Scan.mask(source)       comments blanked, every string literal replaced by a token `__S<n>__`
	                          (newlines kept, so line numbers stay right); the literals in .strings
	  Scan.scan(source)       every finding of one script:
	                            { datastores, libraries, purchases, remotes, leaderstats, globals,
	                              waits, trusts, onLegacyProduct, lines, empty }
	  Scan.keyPattern(...)    a key expression -> "Player_{userId}" / literal / "<dynamic>"

	Anything it can't resolve is "<dynamic>", never guessed. Every finding carries its 1-based line.
]]

local Scan = {}

Scan.DYNAMIC = "<dynamic>"

Scan.STORE_OPS = {
	"GetAsync",
	"SetAsync",
	"UpdateAsync",
	"IncrementAsync",
	"RemoveAsync",
	"GetSortedAsync",
	"ListKeysAsync",
}
Scan.WRITE_OPS = { SetAsync = true, UpdateAsync = true, IncrementAsync = true, RemoveAsync = true }
local NO_KEY_OPS = { GetSortedAsync = true, ListKeysAsync = true }

Scan.REMOTE_CLASSES = {
	RemoteEvent = true,
	RemoteFunction = true,
	UnreliableRemoteEvent = true,
	BindableEvent = true,
}

-- field names that are instance properties, not save fields (purchases.products[].sold)
local NOT_SOLD = {
	Value = true,
	Parent = true,
	Name = true,
	Text = true,
	Visible = true,
	Enabled = true,
	Position = true,
	Size = true,
	CFrame = true,
	ProcessReceipt = true,
	PurchaseId = true,
	ProductId = true,
	PlayerId = true,
	Character = true,
}

-- client-supplied argument names a server handler must never trust as-is (high risk when written)
local TRUST_WORDS = {
	"amount",
	"price",
	"cost",
	"count",
	"qty",
	"quantity",
	"item",
	"position",
	"pos",
	"cframe",
	"value",
	"coins",
	"gems",
	"cash",
	"money",
	"reward",
	"damage",
}

local USERID_NAMES =
	{ userId = true, UserId = true, userid = true, user_id = true, uid = true, plrId = true, playerId = true }

--------------------------------------------------------------------------------
-- masking
--------------------------------------------------------------------------------

local function decodeEscapes(s: string): string
	local map = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["`"] = "`" }
	return (string.gsub(s, "\\(.)", function(c)
		return map[c] or c
	end))
end

-- Returns { code, strings = { [n] = { value, kind = "str" | "interp" } }, lineStarts }
function Scan.mask(source: string)
	local out = {}
	local strings = {}
	local n = #source
	local i = 1
	local function emitNewlines(text: string)
		local _, count = string.gsub(text, "\n", "")
		if count > 0 then
			table.insert(out, string.rep("\n", count))
		end
	end
	local function token(value: string, kind: string, raw: string)
		table.insert(strings, { value = value, kind = kind })
		table.insert(out, " __S" .. #strings .. "__ ")
		emitNewlines(raw)
	end
	while i <= n do
		local c = string.sub(source, i, i)
		if c == "-" and string.sub(source, i + 1, i + 1) == "-" then
			local eq = string.match(source, "^%[(=*)%[", i + 2)
			if eq then
				local close = string.find(source, "]" .. eq .. "]", i + 4 + #eq, true)
				local stop = if close then close + #eq + 1 else n
				emitNewlines(string.sub(source, i, stop))
				table.insert(out, " ")
				i = stop + 1
			else
				local nl = string.find(source, "\n", i, true)
				i = if nl then nl else n + 1
			end
		elseif c == '"' or c == "'" then
			local j = i + 1
			local buf = {}
			while j <= n do
				local d = string.sub(source, j, j)
				if d == "\\" then
					table.insert(buf, string.sub(source, j, j + 1))
					j += 2
				elseif d == c or d == "\n" then
					break
				else
					table.insert(buf, d)
					j += 1
				end
			end
			token(decodeEscapes(table.concat(buf)), "str", string.sub(source, i, j))
			i = j + 1
		elseif c == "`" then
			local j = i + 1
			local depth = 0
			while j <= n do
				local d = string.sub(source, j, j)
				if d == "\\" then
					j += 2
					continue
				elseif d == "{" then
					depth += 1
				elseif d == "}" then
					depth -= 1
				elseif d == "`" and depth <= 0 then
					break
				end
				j += 1
			end
			token(string.sub(source, i + 1, j - 1), "interp", string.sub(source, i, j))
			i = j + 1
		elseif c == "[" and string.match(source, "^%[=*%[", i) then
			local eq = string.match(source, "^%[(=*)%[", i)
			local close = string.find(source, "]" .. eq .. "]", i + 2 + #eq, true)
			local stop = if close then close + #eq + 1 else n
			local body = string.sub(source, i + 2 + #eq, (close or n + 1) - 1)
			token(body, "str", string.sub(source, i, stop))
			i = stop + 1
		else
			table.insert(out, c)
			i += 1
		end
	end
	local code = table.concat(out)
	local lineStarts = { 1 }
	for p in string.gmatch(code, "()\n") do
		table.insert(lineStarts, p + 1)
	end
	return { code = code, strings = strings, lineStarts = lineStarts }
end

local function lineOf(m, pos: number): number
	local lo, hi = 1, #m.lineStarts
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if m.lineStarts[mid] <= pos then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return lo
end
Scan.lineOf = lineOf

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$"))
end

-- the literal value of an expression that is exactly one plain string token, else nil
local function literal(m, expr: string?): string?
	if expr == nil then
		return nil
	end
	local n = string.match(trim(expr), "^__S(%d+)__$")
	local s = n and m.strings[tonumber(n)]
	if s and s.kind == "str" then
		return s.value
	end
	return nil
end
Scan.literal = literal

-- like string.gmatch, but resumes right after the capture at index `resume` (a `()` position),
-- so a call's balanced (...) never hides the calls nested inside it
local function findAll(code: string, pattern: string, resume: number)
	local out = {}
	local init = 1
	while true do
		local caps = { string.find(code, pattern, init) }
		if caps[1] == nil then
			break
		end
		local c = table.move(caps, 3, #caps, 1, {})
		table.insert(out, c)
		init = math.max(c[resume], caps[1] + 1)
	end
	return out
end
Scan.findAll = findAll

-- splits the inside of a balanced (...) at top-level commas
local function splitArgs(inner: string): { string }
	local args = {}
	local depth = 0
	local start = 1
	for i = 1, #inner do
		local c = string.sub(inner, i, i)
		if c == "(" or c == "{" or c == "[" then
			depth += 1
		elseif c == ")" or c == "}" or c == "]" then
			depth -= 1
		elseif c == "," and depth == 0 then
			table.insert(args, trim(string.sub(inner, start, i - 1)))
			start = i + 1
		end
	end
	local last = trim(string.sub(inner, start))
	if last ~= "" or #args > 0 then
		table.insert(args, last)
	end
	return args
end
Scan.splitArgs = splitArgs

local function argsOf(paren: string): { string }
	return splitArgs(string.sub(paren, 2, -2))
end

-- the expression ending right before `pos` (identifiers, `.`/`:` chains, balanced () and [])
local function trailingExpr(code: string, pos: number): (string, number)
	local i = pos - 1
	while i > 0 and string.match(string.sub(code, i, i), "%s") do
		i -= 1
	end
	local stop = i
	while i > 0 do
		local c = string.sub(code, i, i)
		if c == ")" or c == "]" then
			local open = if c == ")" then "(" else "["
			local depth = 0
			while i > 0 do
				local d = string.sub(code, i, i)
				if d == c then
					depth += 1
				elseif d == open then
					depth -= 1
					if depth == 0 then
						break
					end
				end
				i -= 1
			end
			i -= 1
		elseif string.match(c, "[%w_%.:]") then
			i -= 1
		elseif string.match(c, "%s") then
			-- allow `a\n\t:Method` chains
			local j = i
			while j > 0 and string.match(string.sub(code, j, j), "%s") do
				j -= 1
			end
			if
				j > 0
				and string.match(string.sub(code, j + 1, i + 1), "^%s*[%.:]")
				and string.match(string.sub(code, i + 1, i + 1), "[%.:]")
			then
				i = j
			else
				break
			end
		else
			break
		end
	end
	return trim(string.sub(code, i + 1, stop)), i + 1
end
Scan.trailingExpr = trailingExpr

-- the assignment target of the expression starting at `start` (`local x = <expr>` -> "x")
local function assignedTo(code: string, start: number): string?
	local before = string.sub(code, math.max(1, start - 160), start - 1)
	local name = string.match(before, "([%w_%.]+)%s*=%s*$")
		or string.match(before, "([%w_%.]+)%s*:%s*[%w_%.<>%?]+%s*=%s*$")
	if name and string.match(name, "^__S%d+__$") == nil then
		return name
	end
	return nil
end

-- the end position of the block opened by the keyword at `pos` (function/if/do/repeat ... end)
local OPENERS = { ["function"] = true, ["if"] = true, ["do"] = true, ["repeat"] = true }
local CLOSERS = { ["end"] = true, ["until"] = true }
local function blockEnd(code: string, pos: number): number
	local depth = 0
	local i = pos
	while true do
		local s, e, word = string.find(code, "%f[%w_]([%a_][%w_]*)", i)
		if s == nil then
			return #code
		end
		if OPENERS[word] then
			depth += 1
		elseif CLOSERS[word] then
			depth -= 1
			if depth == 0 then
				return e
			end
		end
		i = e + 1
	end
end
Scan.blockEnd = blockEnd

-- the region of a function named or written at `expr` (an inline `function` or a name defined
-- in this file); nil when it can't be found
local function functionRegion(code: string, at: number, rest: string): (number?, number?)
	if string.match(rest, "^function%f[^%w_]") then
		return at, blockEnd(code, at)
	end
	local name = string.match(rest, "^([%w_%.]+)")
	if name == nil then
		return nil, nil
	end
	local esc = string.gsub(name, "%.", "%%.")
	local s = string.find(code, "function%s+" .. esc .. "%s*%(")
	if s then
		return s, blockEnd(code, s)
	end
	local s2, e2 = string.find(code, "%f[%w_]" .. esc .. "%s*=%s*function%f[^%w_]")
	if s2 then
		local fs = e2 - 7
		return fs, blockEnd(code, fs)
	end
	return nil, nil
end

--------------------------------------------------------------------------------
-- variables, key patterns
--------------------------------------------------------------------------------

-- every `local x = <rest of line>` (and `x = ...`) with its position, for resolving keys and ids
local function localAssignments(code: string)
	local vars = {}
	for pos, name, expr in string.gmatch(code, "()local%s+([%a_][%w_]*)%s*=%s*([^\n]+)") do
		vars[name] = vars[name] or {}
		table.insert(vars[name], { pos = pos, expr = trim(expr) })
	end
	for pos, name, expr in string.gmatch(code, "\n%s*()([%a_][%w_]*)%s*=%s*([^=\n][^\n]*)") do
		vars[name] = vars[name] or {}
		table.insert(vars[name], { pos = pos, expr = trim(expr) })
	end
	for _, list in vars do
		table.sort(list, function(a, b)
			return a.pos < b.pos
		end)
	end
	return vars
end

local function lookupVar(ctx, name: string, pos: number?): string?
	local list = ctx.vars[name]
	if list == nil then
		return nil
	end
	local best = nil
	for _, a in list do
		if pos == nil or a.pos < pos then
			best = a.expr
		end
	end
	return best or list[1].expr
end

local function userIdVars(code: string): { [string]: boolean }
	local set = table.clone(USERID_NAMES)
	for name, expr in string.gmatch(code, "local%s+([%a_][%w_]*)%s*=%s*([^\n]+)") do
		expr = trim(expr)
		local inner = string.match(expr, "^tostring%s*%((.*)%)$")
			or string.match(expr, "^tonumber%s*%((.*)%)$")
			or expr
		if string.match(trim(inner), "^[%w_%.:]*UserId$") then
			set[name] = true
		end
	end
	return set
end

local function newCtx(m)
	return { m = m, vars = localAssignments(m.code), uid = userIdVars(m.code) }
end

-- splits at top-level `..`
local function splitConcat(expr: string): { string }
	local parts = {}
	local depth = 0
	local start = 1
	local i = 1
	while i <= #expr do
		local c = string.sub(expr, i, i)
		if c == "(" or c == "{" or c == "[" then
			depth += 1
		elseif c == ")" or c == "}" or c == "]" then
			depth -= 1
		elseif
			c == "."
			and depth == 0
			and string.sub(expr, i, i + 1) == ".."
			and string.sub(expr, i + 2, i + 2) ~= "."
		then
			table.insert(parts, trim(string.sub(expr, start, i - 1)))
			start = i + 2
			i += 1
		end
		i += 1
	end
	table.insert(parts, trim(string.sub(expr, start)))
	return parts
end

local keyOf

local function interpPattern(ctx, raw: string, depth: number): string?
	local out = {}
	local i = 1
	while i <= #raw do
		local c = string.sub(raw, i, i)
		if c == "{" then
			local close = string.find(raw, "}", i, true)
			if close == nil then
				return nil
			end
			local inner = Scan.mask(string.sub(raw, i + 1, close - 1))
			local sub = newCtx(inner)
			sub.vars = ctx.vars
			sub.uid = ctx.uid
			sub.pos = ctx.pos
			local v = keyOf(sub, inner.code, depth + 1)
			if v == nil then
				return nil
			end
			table.insert(out, v)
			i = close + 1
		elseif c == "\\" then
			table.insert(out, string.sub(raw, i + 1, i + 1))
			i += 2
		else
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

keyOf = function(ctx, expr: string, depth: number): string?
	if depth > 5 then
		return nil
	end
	expr = trim(expr)
	while string.match(expr, "^%b()$") do
		expr = trim(string.sub(expr, 2, -2))
	end
	local parts = splitConcat(expr)
	if #parts > 1 then
		local out = {}
		for _, p in parts do
			local v = keyOf(ctx, p, depth + 1)
			if v == nil then
				return nil
			end
			table.insert(out, v)
		end
		return table.concat(out)
	end
	local n = string.match(expr, "^__S(%d+)__$")
	if n then
		local s = ctx.m.strings[tonumber(n)]
		if s.kind == "interp" then
			return interpPattern(ctx, s.value, depth)
		end
		return s.value
	end
	local inner = string.match(expr, "^tostring%s*(%b())$") or string.match(expr, "^tonumber%s*(%b())$")
	if inner then
		return keyOf(ctx, string.sub(inner, 2, -2), depth + 1)
	end
	local fmt = string.match(expr, "^string%.format%s*(%b())$")
	if fmt then
		local args = argsOf(fmt)
		local f = literal(ctx.m, args[1])
		if f == nil then
			return nil
		end
		local k = 1
		local bad = false
		local res = string.gsub(f, "%%[%-%d%.]*([sdiq%%])", function(spec)
			if spec == "%" then
				return "%"
			end
			k += 1
			local v = args[k] and keyOf(ctx, args[k], depth + 1)
			if v == nil then
				bad = true
				return ""
			end
			return v
		end)
		return if bad then nil else res
	end
	if string.match(expr, "^%d+$") then
		return expr
	end
	if
		string.match(expr, "^[%w_%.:]*UserId$")
		or string.match(expr, "^[%w_%.]+%.userId$")
		or string.match(expr, "^[%w_%.]+%.PlayerId$")
	then
		return "{userId}"
	end
	if string.match(expr, "^[%a_][%w_]*$") then
		if ctx.uid[expr] then
			return "{userId}"
		end
		local def = lookupVar(ctx, expr, ctx.pos)
		if def and def ~= expr then
			return keyOf(ctx, def, depth + 1)
		end
	end
	return nil
end

-- A key expression -> its pattern ("Player_{userId}"), the literal, or "<dynamic>".
function Scan.keyPattern(ctx, expr: string?, pos: number?): string
	if expr == nil or trim(expr) == "" then
		return Scan.DYNAMIC
	end
	ctx.pos = pos
	local v = keyOf(ctx, expr, 0)
	ctx.pos = nil
	return v or Scan.DYNAMIC
end

-- the numeric value of an id expression (literal, or a constant defined in this file)
local function numericId(ctx, expr: string?): number?
	if expr == nil then
		return nil
	end
	expr = trim(expr)
	if string.match(expr, "^%d+$") then
		return tonumber(expr)
	end
	local last = string.match(expr, "([%a_][%w_]*)$")
	if last then
		local def = lookupVar(ctx, last, nil)
		if def and string.match(def, "^%d+") then
			return tonumber(string.match(def, "^(%d+)"))
		end
		local v = string.match(ctx.m.code, "%f[%w_]" .. last .. "%s*=%s*(%d%d%d%d+)")
		if v then
			return tonumber(v)
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- the scanners
--------------------------------------------------------------------------------

local function serviceAliases(m, service: string): { [string]: boolean }
	local set = {}
	for name, n in string.gmatch(m.code, "([%a_][%w_]*)%s*=%s*game%s*:%s*GetService%s*%(%s*__S(%d+)__%s*%)") do
		if m.strings[tonumber(n)].value == service then
			set[name] = true
		end
	end
	for name in string.gmatch(m.code, "([%a_][%w_]*)%s*=%s*game%s*%.%s*" .. service .. "%f[^%w_]") do
		set[name] = true
	end
	return set
end

local function isService(m, aliases, expr: string, service: string): boolean
	if aliases[expr] then
		return true
	end
	if string.match(expr, "^game%s*%.%s*" .. service .. "$") then
		return true
	end
	local n = string.match(expr, "^game%s*:%s*GetService%s*%(%s*__S(%d+)__%s*%)$")
	return n ~= nil and m.strings[tonumber(n)].value == service
end

local function scanDataStores(ctx, res)
	local m = ctx.m
	local code = m.code
	local dss = serviceAliases(m, "DataStoreService")
	local stores = {} -- var -> store
	local list = {}
	for _, c in findAll(code, "()[:%.]%s*(Get%a*DataStore)()%s*(%b())()", 3) do
		local colon, method, paren, after = c[1], c[2], c[4], c[5]
		if
			method ~= "GetDataStore"
			and method ~= "GetOrderedDataStore"
			and method ~= "GetGlobalDataStore"
		then
			continue
		end
		local recv, start = trailingExpr(code, colon)
		if not isService(m, dss, recv, "DataStoreService") then
			continue
		end
		local args = argsOf(paren)
		local name
		if method == "GetGlobalDataStore" then
			name = "<global>"
		else
			name = literal(m, args[1]) or Scan.DYNAMIC
		end
		local scope = literal(m, args[2])
		if scope == nil and args[2] ~= nil and args[2] ~= "" and args[2] ~= "nil" then
			scope = Scan.DYNAMIC
		end
		local store = {
			name = name,
			scope = scope,
			kind = if method == "GetOrderedDataStore" then "ordered" else "global",
			line = lineOf(m, colon),
			calls = {},
		}
		table.insert(list, store)
		local var = assignedTo(code, start)
		if var then
			stores[var] = store
		end
		-- a chained call: DSS:GetDataStore("X"):GetAsync(key)
		local op, opParen = string.match(code, "^%s*:%s*(%a+)%s*(%b())", after)
		if op and table.find(Scan.STORE_OPS, op) then
			local a = argsOf(opParen)
			table.insert(store.calls, {
				op = op,
				line = lineOf(m, colon),
				key = if NO_KEY_OPS[op] then nil else Scan.keyPattern(ctx, a[1], colon),
				keyExpr = a[1],
			})
		end
	end
	-- method calls on the store variables: store:GetAsync(key), pcall(store.GetAsync, store, key)
	for _, c in findAll(code, "()%f[%a_]([%a_][%w_%.]*)%s*:%s*(%a+Async)()%s*(%b())", 4) do
		local pos, recv, op, paren = c[1], c[2], c[3], c[5]
		local store = stores[recv]
		if store and table.find(Scan.STORE_OPS, op) then
			local a = argsOf(paren)
			table.insert(store.calls, {
				op = op,
				line = lineOf(m, pos),
				key = if NO_KEY_OPS[op] then nil else Scan.keyPattern(ctx, a[1], pos),
				keyExpr = a[1],
			})
		end
	end
	for _, c in findAll(code, "()%f[%w_]pcall()%s*(%b())", 2) do
		local pos, paren = c[1], c[3]
		local a = argsOf(paren)
		local recv, op = string.match(a[1] or "", "^([%a_][%w_%.]*)[%.:](%a+Async)$")
		local store = recv and stores[recv]
		if store and table.find(Scan.STORE_OPS, op) then
			table.insert(store.calls, {
				op = op,
				line = lineOf(m, pos),
				key = if NO_KEY_OPS[op] then nil else Scan.keyPattern(ctx, a[3], pos),
				keyExpr = a[3],
			})
		end
	end
	for _, s in list do
		table.sort(s.calls, function(a, b)
			return a.line < b.line
		end)
	end
	res.datastores = list
end

local function scanLibraries(ctx, res)
	local m = ctx.m
	local code = m.code
	local libs = {}
	local byVar = {}
	-- ProfileService: ProfileService.GetProfileStore("Name", template) / :GetProfileStore({ Name, Scope })
	for pos, paren in string.gmatch(code, "()GetProfileStore%s*(%b())") do
		local a = argsOf(paren)
		local name, scope = literal(m, a[1]), nil
		if name == nil and string.match(a[1] or "", "^%b{}$") then
			name = literal(m, string.match(a[1], "Name%s*=%s*(__S%d+__)"))
			scope = literal(m, string.match(a[1], "Scope%s*=%s*(__S%d+__)"))
		end
		local recv, start = trailingExpr(code, pos)
		local lib = {
			name = "ProfileService",
			store = name or Scan.DYNAMIC,
			scope = scope,
			keyPattern = nil,
			combined = {},
			line = lineOf(m, pos),
			_recv = recv,
		}
		table.insert(libs, lib)
		local var = assignedTo(code, start)
		if var then
			byVar[var] = lib
		end
	end
	-- ProfileStore: ProfileStore.New("Name", template)
	for pos, paren in string.gmatch(code, "()ProfileStore%s*%.%s*New%s*(%b())") do
		local a = argsOf(paren)
		local lib = {
			name = "ProfileStore",
			store = literal(m, a[1]) or Scan.DYNAMIC,
			scope = nil,
			keyPattern = nil,
			combined = {},
			line = lineOf(m, pos),
		}
		table.insert(libs, lib)
		local var = assignedTo(code, pos)
		if var then
			byVar[var] = lib
		end
	end
	for _, c in findAll(code, "()%f[%a_]([%a_][%w_%.]*)%s*:%s*(%a+)()%s*(%b())", 4) do
		local pos, recv, method, paren = c[1], c[2], c[3], c[5]
		if method == "LoadProfileAsync" or method == "StartSessionAsync" then
			local lib = byVar[recv]
			if lib == nil then
				for _, l in libs do
					if (method == "LoadProfileAsync") == (l.name == "ProfileService") then
						lib = lib or l
					end
				end
			end
			if lib and lib.keyPattern == nil then
				lib.keyPattern = Scan.keyPattern(ctx, argsOf(paren)[1], pos)
				lib.keyExpr = argsOf(paren)[1]
			end
		end
	end
	-- DataStore2: DataStore2.Combine("Master", "coins", "inventory"), DataStore2("coins", player)
	for pos, paren in string.gmatch(code, "()DataStore2%s*%.%s*Combine%s*(%b())") do
		local a = argsOf(paren)
		local combined = {}
		for k = 2, #a do
			table.insert(combined, literal(m, a[k]) or Scan.DYNAMIC)
		end
		table.insert(libs, {
			name = "DataStore2",
			store = literal(m, a[1]) or Scan.DYNAMIC,
			scope = nil,
			keyPattern = "{userId}",
			combined = combined,
			line = lineOf(m, pos),
		})
	end
	local ds2Vars = {}
	for _, c in findAll(code, "()%f[%w_]DataStore2()%s*(%b())", 2) do
		local pos, paren = c[1], c[3]
		local before = string.sub(code, math.max(1, pos - 9), pos - 1)
		if string.match(before, "require%s*$") or string.match(before, "function%s*$") then
			continue
		end
		local a = argsOf(paren)
		local name = literal(m, a[1]) or Scan.DYNAMIC
		local var = assignedTo(code, pos)
		if var then
			ds2Vars[var] = name
		end
		table.insert(libs, {
			name = "DataStore2",
			store = name,
			scope = nil,
			keyPattern = "{userId}",
			combined = {},
			line = lineOf(m, pos),
		})
	end
	for _, l in libs do
		l._recv = nil
		if l.keyPattern == nil then
			l.keyPattern = Scan.DYNAMIC
		end
	end
	res.libraries = libs
	res.ds2Vars = ds2Vars
end

local function soldFields(ctx, region: string, ds2Vars): { string }
	local set = {}
	for field in string.gmatch(region, "[%w_%]%)]%.([%a_][%w_]*)%s*[%+%-%*]?=%s*[^=]") do
		set[field] = true
	end
	for field in string.gmatch(region, "%.([%a_][%w_]*)%s*%b[]%s*=%s*[^=]") do
		set[field] = true
	end
	for field in string.gmatch(region, "%.([%a_][%w_]*)%.Value%s*[%+%-%*]?=%s*[^=]") do
		set[field] = true
	end
	for n in string.gmatch(region, "%[%s*__S(%d+)__%s*%]%s*[%+%-%*]?=%s*[^=]") do
		set[ctx.m.strings[tonumber(n)].value] = true
	end
	for field in string.gmatch(region, "table%.insert%s*%(%s*[%a_][%w_%.]-%.([%a_][%w_]*)%s*,") do
		set[field] = true
	end
	for var, method in string.gmatch(region, "([%a_][%w_]*)%s*:%s*(%a+)%s*%(") do
		if ds2Vars[var] and (method == "Increment" or method == "Set" or method == "Update") then
			set[ds2Vars[var]] = true
		end
	end
	for n in string.gmatch(region, "DataStore2%s*%(%s*__S(%d+)__[^%)]*%)%s*:%s*Increment") do
		set[ctx.m.strings[tonumber(n)].value] = true
	end
	local out = {}
	for f in set do
		if not NOT_SOLD[f] and string.match(f, "^__S") == nil then
			table.insert(out, f)
		end
	end
	table.sort(out)
	return out
end

local function usesRandom(region: string): boolean
	return string.find(region, "math%.random") ~= nil
		or string.find(region, "Random%.new") ~= nil
		or string.find(region, ":%s*NextInteger") ~= nil
		or string.find(region, ":%s*NextNumber") ~= nil
end
Scan.usesRandom = usesRandom

local function hasHistoryCheck(region: string): boolean
	if string.find(region, "PurchaseId") == nil then
		return false
	end
	return string.find(region, "GetAsync") ~= nil
		or string.find(region, "UpdateAsync") ~= nil
		or string.find(string.lower(region), "history") ~= nil
		or string.find(region, "%[[^%]\n]*PurchaseId[^%]\n]*%]") ~= nil
end
Scan.hasHistoryCheck = hasHistoryCheck

local function scanPurchases(ctx, res)
	local m = ctx.m
	local code = m.code
	local p = { processReceipt = {}, products = {}, passes = {}, prompts = {}, ownership = {} }
	local regions = {}
	for pos, e in string.gmatch(code, "()ProcessReceipt%s*=()") do
		if string.sub(code, e, e) == "=" then
			continue
		end
		local rest = string.match(code, "^%s*(.-)$", e) or ""
		local rs, re = functionRegion(code, e + (#string.sub(code, e) - #rest), rest)
		local region = if rs then string.sub(code, rs, re) else string.sub(code, e)
		table.insert(regions, { s = rs or e, e = re or #code })
		table.insert(p.processReceipt, { line = lineOf(m, pos), historyCheck = hasHistoryCheck(region) })
	end
	local purchaseFile = #p.processReceipt > 0 or string.find(code, "ProductId") ~= nil
	local seen = {}
	local function addProduct(id: number?, pos: number, region: string)
		if id == nil then
			return
		end
		local entry = seen[id]
		if entry == nil then
			entry = { id = id, line = lineOf(m, pos), sold = {}, random = false }
			seen[id] = entry
			table.insert(p.products, entry)
		end
		for _, f in soldFields(ctx, region, res.ds2Vars or {}) do
			if not table.find(entry.sold, f) then
				table.insert(entry.sold, f)
			end
		end
		table.sort(entry.sold)
		entry.random = entry.random or usesRandom(region)
	end
	if purchaseFile then
		-- handlers table: [123] = function(receipt, player) ... end / [PRODUCTS.Gems] = grantGems
		for pos, key, e in string.gmatch(code, "()%[%s*([%w_%.]+)%s*%]%s*=%s*()") do
			local id = numericId(ctx, key)
			if id then
				local rest = string.sub(code, e, e + 80)
				local rs, re = functionRegion(code, e, rest)
				if rs then
					addProduct(id, pos, string.sub(code, rs, re))
				end
			end
		end
		-- if receiptInfo.ProductId == 123 then ... (until the next ProductId comparison)
		local cmps = {}
		for pos, rhs in string.gmatch(code, "()ProductId%s*==%s*([%w_%.]+)") do
			table.insert(cmps, { pos = pos, id = numericId(ctx, rhs) })
		end
		for pos, lhs in string.gmatch(code, "()([%w_%.]+)%s*==%s*[%w_%.]*ProductId") do
			table.insert(cmps, { pos = pos, id = numericId(ctx, lhs) })
		end
		table.sort(cmps, function(a, b)
			return a.pos < b.pos
		end)
		for k, c in cmps do
			local stop = if cmps[k + 1] then cmps[k + 1].pos - 1 else #code
			for _, r in regions do
				if c.pos >= r.s and c.pos <= r.e then
					stop = math.min(stop, r.e)
				end
			end
			addProduct(c.id, c.pos, string.sub(code, c.pos, stop))
		end
	end
	local passSeen = {}
	local function addPass(id: number?, pos: number)
		if id and not passSeen[id] then
			passSeen[id] = true
			table.insert(p.passes, { id = id, line = lineOf(m, pos) })
		end
	end
	for _, c in findAll(code, "()(Prompt%a*Purchase)()%s*(%b())", 3) do
		local pos, method, paren = c[1], c[2], c[4]
		local a = argsOf(paren)
		local id = numericId(ctx, a[2])
		table.insert(p.prompts, { kind = method, line = lineOf(m, pos), id = id })
		if method == "PromptGamePassPurchase" then
			addPass(id, pos)
		elseif method == "PromptProductPurchase" and id and not seen[id] then
			addProduct(id, pos, "")
		end
	end
	for pos, ev in string.gmatch(code, "()(Prompt%a*PurchaseFinished)") do
		table.insert(p.prompts, { kind = ev, line = lineOf(m, pos) })
	end
	for _, c in findAll(code, "()(UserOwnsGamePassAsync)()%s*(%b())", 3) do
		local pos, method, paren = c[1], c[2], c[4]
		local id = numericId(ctx, argsOf(paren)[2])
		table.insert(p.ownership, { kind = method, line = lineOf(m, pos), id = id })
		addPass(id, pos)
	end
	for pos, method in string.gmatch(code, "()(PlayerOwnsAsset)%s*%(") do
		table.insert(p.ownership, { kind = method, line = lineOf(m, pos) })
	end
	table.sort(p.products, function(a, b)
		return a.line < b.line or (a.line == b.line and a.id < b.id)
	end)
	res.purchases = p
end

-- the remote name an expression refers to (WaitForChild("X"), a.b.X, a local alias)
local function remoteName(ctx, expr: string, depth: number?): string?
	depth = depth or 0
	if depth > 3 then
		return nil
	end
	local n = string.match(expr, "[:%.]%s*WaitForChild%s*%(%s*__S(%d+)__[^%)]*%)$")
		or string.match(expr, "[:%.]%s*FindFirstChild%s*%(%s*__S(%d+)__[^%)]*%)$")
		or string.match(expr, "%[%s*__S(%d+)__%s*%]$")
	if n then
		return ctx.m.strings[tonumber(n)].value
	end
	if string.match(expr, "^[%a_][%w_]*$") then
		local def = lookupVar(ctx, expr, nil)
		if def then
			local n2 = string.match(def, "^Instance%.new%s*%(%s*__S(%d+)__")
			if n2 then
				local nm = string.match(ctx.m.code, "%f[%w_]" .. expr .. "%.Name%s*=%s*__S(%d+)__")
				return if nm then ctx.m.strings[tonumber(nm)].value else expr
			end
			return remoteName(ctx, def, depth + 1) or expr
		end
		return expr
	end
	return string.match(expr, "%.([%a_][%w_]*)$")
end

local function scanRemotes(ctx, res)
	local m = ctx.m
	local code = m.code
	local created, handlers, fires, trusts = {}, {}, {}, {}
	for pos, n in string.gmatch(code, "()Instance%s*%.%s*new%s*%(%s*__S(%d+)__") do
		local class = m.strings[tonumber(n)].value
		if Scan.REMOTE_CLASSES[class] then
			local var = assignedTo(code, pos)
			local name = var
			if var then
				local nm = string.match(
					code,
					"%f[%w_]" .. string.gsub(var, "%.", "%%.") .. "%.Name%s*=%s*__S(%d+)__"
				)
				if nm then
					name = m.strings[tonumber(nm)].value
				end
			end
			table.insert(created, { name = name or Scan.DYNAMIC, class = class, line = lineOf(m, pos) })
		end
	end
	for pos, kind in string.gmatch(code, "()[%.]%s*(On%a+)%f[^%w_]") do
		if
			kind ~= "OnServerEvent"
			and kind ~= "OnServerInvoke"
			and kind ~= "OnClientEvent"
			and kind ~= "OnClientInvoke"
		then
			continue
		end
		local recv = trailingExpr(code, pos)
		local name = remoteName(ctx, recv) or Scan.DYNAMIC
		table.insert(handlers, { name = name, kind = kind, line = lineOf(m, pos) })
		-- the handler's params and body, for the trust check (server side only)
		if kind == "OnServerEvent" or kind == "OnServerInvoke" then
			local tail = string.sub(code, pos)
			local fpos = string.match(tail, "^[%.]%s*%a+%s*:%s*Connect%s*%(%s*()function")
				or string.match(tail, "^[%.]%s*%a+%s*=%s*()function")
			local rs, re
			if fpos then
				rs = pos + fpos - 1
				re = blockEnd(code, rs)
			else
				local ref = string.match(tail, "^[%.]%s*%a+%s*:%s*Connect%s*%(%s*([%a_][%w_%.]*)%s*%)")
					or string.match(tail, "^[%.]%s*%a+%s*=%s*([%a_][%w_%.]*)")
				if ref then
					rs, re = functionRegion(code, pos, ref)
				end
			end
			if rs then
				local body = string.sub(code, rs, re)
				local params = string.match(body, "^function[^%(]*(%b())")
				local list = if params then argsOf(params) else {}
				for k = 2, #list do
					local param = string.match(list[k], "^([%a_][%w_]*)")
					if param == nil then
						continue
					end
					local low = string.lower(param)
					local suspicious = false
					for _, w in TRUST_WORDS do
						if string.find(low, w, 1, true) then
							suspicious = true
						end
					end
					if low == "id" or string.match(low, "id$") then
						suspicious = true
					end
					if not suspicious then
						continue
					end
					local p = "%f[%w_]" .. param .. "%f[^%w_]"
					local written = string.find(body, "[^=~<>]=%s*[^=\n]-" .. p) ~= nil
						or string.find(body, "[%+%-]=%s*[^\n]-" .. p) ~= nil
						or string.find(body, "Async%s*%([^\n]-" .. p) ~= nil
						or string.find(body, "table%.insert%s*%([^\n]-" .. p) ~= nil
					if written then
						table.insert(trusts, { name = name, param = param, line = lineOf(m, pos) })
					end
				end
			end
		end
	end
	for pos, method in string.gmatch(code, "()[:%.]%s*(%a+)%s*%(") do
		if
			method == "FireServer"
			or method == "FireClient"
			or method == "FireAllClients"
			or method == "InvokeServer"
			or method == "InvokeClient"
			or method == "Fire"
		then
			local recv = trailingExpr(code, pos)
			if recv == "" then
				continue
			end
			table.insert(
				fires,
				{ name = remoteName(ctx, recv) or Scan.DYNAMIC, kind = method, line = lineOf(m, pos) }
			)
		end
	end
	res.remotes = { created = created, handlers = handlers, fires = fires }
	res.trusts = trusts
end

local function scanLeaderstats(ctx, res)
	local m = ctx.m
	local code = m.code
	local out = {}
	for pos, target, n in string.gmatch(code, "()([%a_][%w_%.]*)%.Name%s*=%s*__S(%d+)__") do
		if m.strings[tonumber(n)].value ~= "leaderstats" then
			continue
		end
		local entry = { line = lineOf(m, pos), values = {} }
		local esc = string.gsub(target, "%.", "%%.")
		for var, cn in
			string.gmatch(code, "local%s+([%a_][%w_]*)%s*=%s*Instance%s*%.%s*new%s*%(%s*__S(%d+)__")
		do
			local class = m.strings[tonumber(cn)].value
			if string.match(class, "Value$") then
				local parented = string.find(
					code,
					"%f[%w_]" .. var .. "%.Parent%s*=%s*" .. esc .. "%f[^%w_%.]"
				) or string.find(
					code,
					"Instance%s*%.%s*new%s*%(%s*__S" .. cn .. "__%s*,%s*" .. esc .. "%s*%)"
				)
				if parented then
					local nm = string.match(code, "%f[%w_]" .. var .. "%.Name%s*=%s*__S(%d+)__")
					table.insert(
						entry.values,
						{ name = if nm then m.strings[tonumber(nm)].value else var, class = class }
					)
				end
			end
		end
		table.insert(out, entry)
	end
	res.leaderstats = out
end

local function scanGlobals(ctx, res)
	local m = ctx.m
	local code = m.code
	local out = {}
	local function add(kind, pos)
		table.insert(out, { kind = kind, line = lineOf(m, pos) })
	end
	for pos in string.gmatch(code, "()%f[%w_]_G%s*[%.%[]") do
		add("_G", pos)
	end
	for pos in string.gmatch(code, "()%f[%w_]shared%s*[%.%[]") do
		if string.sub(code, pos - 1, pos - 1) ~= "." and string.sub(code, pos - 1, pos - 1) ~= ":" then
			add("shared", pos)
		end
	end
	for pos in string.gmatch(code, "()%f[%w_]require%s*%(%s*%d+%s*%)") do
		add("require(asset)", pos)
	end
	for pos in string.gmatch(code, "()%f[%w_]loadstring%s*%(") do
		add("loadstring", pos)
	end
	table.sort(out, function(a, b)
		return a.line < b.line or (a.line == b.line and a.kind < b.kind)
	end)
	res.globals = out
	local waits = {}
	for pos in string.gmatch(code, "()%f[%w_]wait%s*%(") do
		local prev = string.sub(code, pos - 1, pos - 1)
		if prev ~= "." and prev ~= ":" then
			table.insert(waits, { line = lineOf(m, pos) })
		end
	end
	res.waits = waits
end

-- Every finding of one script's source.
function Scan.scan(source: string)
	local m = Scan.mask(source)
	local ctx = newCtx(m)
	local res = {}
	scanDataStores(ctx, res)
	scanLibraries(ctx, res)
	scanPurchases(ctx, res)
	scanRemotes(ctx, res)
	scanLeaderstats(ctx, res)
	scanGlobals(ctx, res)
	res.onLegacyProduct = {}
	for pos in string.gmatch(m.code, "()%f[%w_]onLegacyProduct%s*%(") do
		table.insert(res.onLegacyProduct, { line = lineOf(m, pos) })
	end
	local _, nl = string.gsub(source, "\n", "")
	res.lines = if source == "" then 0 else nl + (if string.sub(source, -1) == "\n" then 0 else 1)
	res.empty = string.match(m.code, "^%s*$") ~= nil
	res.random = usesRandom(m.code)
	res.mentionsOdds = string.find(string.lower(source), "odds") ~= nil
	return res
end

return Scan
