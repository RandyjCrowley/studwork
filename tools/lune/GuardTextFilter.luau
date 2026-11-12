--!nocheck
--[[
	tools/lune/GuardTextFilter: the `textfilter` check of tools/lune/guardrails.luau (v1.7.0,
	docs/framework/kits/textfilter.md, module-api.md §23.12): a client-supplied string reaching a
	player or a shared store without TextFilter, or a whole TextFilter record reaching one, in game,
	example and kit server code. Best effort, same function. `-- guard: allow textfilter` on the
	sink's line (with a reason on the line above) skips it. A legacy list may name it
	(Guard.LEGACY_CHECKS).

	  GuardTextFilter.scanSource(source, ctx) -> { string }   findings for one file's source;
	                                                          ctx = { path, isServer = boolean }
	  GuardTextFilter.scanGame(fs, dir) -> { string }         a game folder's server code
	  GuardTextFilter.scanAll(fs) -> { string }               kit and example-module server files
	  GuardTextFilter.selfTest() -> { string }                planted-violation failures; called by --self-test

	Each finding: `<path>:<line>: [textfilter] <message>`.

	How it reads a file (on tokens: comments dropped, string contents blanked, an interpolated
	string's `{expr}` parts kept as `..` concatenations):
	  sources   the parameters after the first (the player) of an action handler, `...` included,
	            unless annotated with only `number`/`boolean` types (a wire value is untrusted
	            whatever else it is annotated: `any`, a table, a string). Handlers: `handler = ...`
	            anywhere, `<name> = ...` directly in an `actions = { ... }` table, or
	            `actions.<name> = ...`, where the value is an inline function or the name of a
	            function defined in the same file (`local function onRename(player, name)`, or
	            dotted: `function M.onRename(` / `M.onRename = function(`), or any of those passed
	            to a call (`handler = guard(onRename)`: each argument naming one is a handler).
	            Not resolved: methods (`M:f`), table lookups, handlers from other files.
	  taint     a local assigned (plain, `..`, string.sub/format/lower/upper or the same methods) from
	            a tainted name in the same function is tainted from that line on.
	  clean     only what a TextFilter call (`filter`, `textFor`, `store`, `shown` on a receiver that
	            names TextFilter or a local alias of it) RETURNS. Passing a name to one never clears
	            it: sending the original after filtering it is the mistake this check is for.
	  records   the second name a `filter`/`store` call is assigned to (`local ok, s = ...store(...)`)
	            is a filter record: it may reach a sink only through `TextFilter.shown(s)` or a field.
	  sinks     ctx.replicate.setAll / set, ctx.net.fire / fireAll (the handler's own player too),
	            ctx.data.messages.send, a Mail send, ctx.data.shared.update, set/update/increment on a
	            store from ctx.data.sortedMap / ctx.data.ordered (directly or through a local),
	            Notifications send/schedule, `.Text =`, `.Name =`, `:SetAttribute(`, and a Text/Name
	            prop inside Instance.new(...).
	Arguments inside a TextFilter call are never findings. Text that travels through tables, other
	modules or saves is not followed.
]]

local GuardTextFilter = {}

local DOC = "(docs/framework/kits/textfilter.md)"
local CHECK = "textfilter"

local KEYWORDS = {
	["and"] = true,
	["break"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["until"] = true,
	["while"] = true,
	["continue"] = true,
}

-- statement starts: an expression never continues across one of these
local STATEMENT = {
	["local"] = true,
	["return"] = true,
	["if"] = true,
	["for"] = true,
	["while"] = true,
	["repeat"] = true,
	["end"] = true,
	["else"] = true,
	["elseif"] = true,
	["until"] = true,
	["break"] = true,
	["continue"] = true,
	["do"] = true,
	["then"] = true,
}

-- an expression continues onto the next line after one of these ...
local CONT_AFTER = {
	[".."] = true,
	["+"] = true,
	["-"] = true,
	["*"] = true,
	["/"] = true,
	["//"] = true,
	["%"] = true,
	["^"] = true,
	["and"] = true,
	["or"] = true,
	["not"] = true,
	["="] = true,
	["=="] = true,
	["~="] = true,
	["<"] = true,
	[">"] = true,
	["<="] = true,
	[">="] = true,
	[","] = true,
	["("] = true,
	["{"] = true,
	["["] = true,
	["::"] = true,
}
-- ... or before one of these
local CONT_BEFORE = {
	[".."] = true,
	["and"] = true,
	["or"] = true,
	["."] = true,
	[":"] = true,
	["("] = true,
	["["] = true,
	["+"] = true,
	["*"] = true,
	["/"] = true,
	["=="] = true,
	["~="] = true,
}

local OPS3 = { ["..."] = true, ["//="] = true, ["..="] = true }
local OPS2 = {
	[".."] = true,
	["=="] = true,
	["~="] = true,
	["<="] = true,
	[">="] = true,
	["::"] = true,
	["->"] = true,
	["+="] = true,
	["-="] = true,
	["*="] = true,
	["/="] = true,
	["%="] = true,
	["^="] = true,
	["//"] = true,
}

local TEXT_FNS = { sub = true, format = true, lower = true, upper = true }
local TF_ALL = { filter = true, textFor = true, store = true, shown = true, release = true }
local STORE_WRITES = { set = true, update = true, increment = true }

--------------------------------------------------------------------------------
-- source -> tokens
--------------------------------------------------------------------------------

-- long bracket at s[i] ("[[" or "[==["): -> level or nil
local function longOpen(s: string, i: number): number?
	local eq = string.match(s, "^%[(=*)%[", i)
	return if eq then #eq else nil
end

-- Comments dropped, string contents blanked (kept as one "S" string token), interpolated
-- `{expr}` parts kept as `.. (expr) ..`. Newlines are kept so every token keeps its line.
local function tokenize(source: string): { any }
	local tokens = {}
	local line = 1
	local i = 1
	local n = #source
	local function push(kind: string, v: string)
		table.insert(tokens, { kind = kind, v = v, line = line })
	end
	-- skips a long bracket body starting at i (just past the opening bracket); returns the index after it
	local function skipLong(level: number, from: number): number
		local close = "]" .. string.rep("=", level) .. "]"
		local j = string.find(source, close, from, true)
		local stop = if j then j + #close - 1 else n
		for _ in string.gmatch(string.sub(source, from, stop), "\n") do
			line += 1
		end
		return stop + 1
	end
	local interp: { number } = {} -- brace depth at each open interpolation
	local braceDepth = 0
	local function readBacktick(from: number): number
		-- from: just past "`" (or past "}" ending an interpolation): read until "`" or "{"
		local j = from
		while j <= n do
			local c = string.sub(source, j, j)
			if c == "\\" then
				j += 2
			elseif c == "\n" then
				line += 1
				j += 1
			elseif c == "`" then
				push("str", "S")
				return j + 1
			elseif c == "{" then
				push("str", "S")
				push("op", "..")
				push("op", "(")
				table.insert(interp, braceDepth)
				return j + 1
			else
				j += 1
			end
		end
		push("str", "S")
		return j
	end
	while i <= n do
		local c = string.sub(source, i, i)
		if c == "\n" then
			line += 1
			i += 1
		elseif string.match(c, "%s") then
			i += 1
		elseif c == "-" and string.sub(source, i + 1, i + 1) == "-" then
			local level = longOpen(source, i + 2)
			if level then
				i = skipLong(level, i + 2 + level + 2)
			else
				local j = string.find(source, "\n", i, true)
				i = if j then j else n + 1
			end
		elseif c == '"' or c == "'" then
			local j = i + 1
			while j <= n do
				local d = string.sub(source, j, j)
				if d == "\\" then
					if string.sub(source, j + 1, j + 1) == "\n" then
						line += 1
					end
					j += 2
				elseif d == c or d == "\n" then
					break
				else
					j += 1
				end
			end
			push("str", "S")
			i = j + 1
		elseif c == "`" then
			i = readBacktick(i + 1)
		elseif c == "[" and longOpen(source, i) then
			local level = longOpen(source, i) :: number
			push("str", "S")
			i = skipLong(level, i + level + 2)
		elseif string.match(c, "[%a_]") then
			local word = string.match(source, "^[%w_]+", i)
			push(if KEYWORDS[word] then "kw" else "name", word)
			i += #word
		elseif string.match(c, "%d") then
			local num = string.match(source, "^[%w_%.]+", i)
			push("num", num)
			i += #num
		else
			local three = string.sub(source, i, i + 2)
			local two = string.sub(source, i, i + 1)
			if OPS3[three] then
				push("op", three)
				i += 3
			elseif OPS2[two] then
				push("op", two)
				i += 2
			else
				if c == "{" then
					braceDepth += 1
				elseif c == "}" then
					if #interp > 0 and interp[#interp] == braceDepth then
						table.remove(interp)
						push("op", ")")
						push("op", "..")
						i = readBacktick(i + 1)
						continue
					end
					braceDepth -= 1
				end
				push("op", c)
				i += 1
			end
		end
	end
	return tokens
end

local function is(t: any, v: string): boolean
	return t ~= nil and t.v == v and t.kind ~= "str"
end

-- matching closer for every opener: ( [ { by depth; function/if/do/repeat by block
local function matchAll(tokens: { any }): { [number]: number }
	local close = {}
	local brackets = {}
	local blocks = {}
	local pairsOf = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
	for i, t in tokens do
		if t.kind == "op" and (t.v == "(" or t.v == "[" or t.v == "{") then
			table.insert(brackets, i)
		elseif t.kind == "op" and pairsOf[t.v] then
			local open = table.remove(brackets)
			if open then
				close[open] = i
				close[-i] = open -- closer -> opener (negative keys)
			end
		elseif t.kind == "kw" then
			-- `while ... do` / `for ... do` open their block at `do`, as does a bare `do`
			if t.v == "function" or t.v == "if" or t.v == "repeat" or t.v == "do" then
				table.insert(blocks, i)
			elseif t.v == "end" or t.v == "until" then
				local open = table.remove(blocks)
				if open then
					close[open] = i
				end
			end
		end
	end
	return close
end

--------------------------------------------------------------------------------
-- analysis helpers
--------------------------------------------------------------------------------

-- end (inclusive) of the expression starting at token i
local function exprEnd(tokens: { any }, close: { [number]: number }, i: number, limit: number): number
	local j = i
	local last = i - 1
	while j <= limit do
		local t = tokens[j]
		if j > i then
			local prev = tokens[last]
			if t.kind == "kw" and STATEMENT[t.v] then
				break
			end
			if t.kind == "op" and (t.v == ")" or t.v == "]" or t.v == "}" or t.v == ";") then
				break -- closes an enclosing bracket
			end
			if t.line ~= prev.line and not CONT_AFTER[prev.v] and not CONT_BEFORE[t.v] then
				break
			end
		end
		local opens = (t.kind == "op" and (t.v == "(" or t.v == "[" or t.v == "{"))
			or (t.kind == "kw" and t.v == "function")
		if opens and close[j] then
			last = close[j]
			j = close[j] + 1
		else
			last = j
			j += 1
		end
	end
	return math.max(last, i)
end

-- the receiver chain just before token i (the `.`/`:` of `<recv>.method`): its token range
local function receiverStart(tokens: { any }, close: { [number]: number }, i: number): number
	local j = i - 1
	while j >= 1 do
		local t = tokens[j]
		if t.kind == "name" then
			local before = tokens[j - 1]
			if before and before.kind == "op" and (before.v == "." or before.v == ":") then
				j -= 2
			else
				return j
			end
		elseif t.kind == "op" and (t.v == "]" or t.v == ")") then
			local opener = close[-j]
			if opener == nil then
				return j + 1
			end
			j = opener - 1
			local before = tokens[j]
			if before == nil or before.kind ~= "name" then
				return opener
			end
		else
			return j + 1
		end
	end
	return 1
end

local function rangeHasName(tokens: { any }, a: number, b: number, names: { [string]: boolean }): boolean
	for k = a, b do
		local t = tokens[k]
		if t and t.kind == "name" and names[t.v] then
			return true
		end
	end
	return false
end

local function allowedLine(raw: string?): boolean
	return raw ~= nil and string.find(raw, "%-%-%s*guard:%s*allow[%w%s,]*" .. CHECK) ~= nil
end

--------------------------------------------------------------------------------
-- the scan
--------------------------------------------------------------------------------

-- every `local a, b = <expr>` / `a = <expr>` in [from, to]: { names, rhsFrom, rhsTo, line, at }
local function assignments(tokens: { any }, close: { [number]: number }, from: number, to: number): { any }
	local out = {}
	local depth = 0
	local k = from
	while k <= to do
		local t = tokens[k]
		if t.kind == "op" and (t.v == "(" or t.v == "{" or t.v == "[") then
			depth += 1
		elseif t.kind == "op" and (t.v == ")" or t.v == "}" or t.v == "]") then
			depth -= 1
		end
		if depth == 0 and t.kind == "name" then
			local prev = tokens[k - 1]
			local isLocal = prev ~= nil and prev.kind == "kw" and prev.v == "local"
			local afterDot = prev ~= nil and prev.kind == "op" and (prev.v == "." or prev.v == ":")
			if not afterDot then
				-- collect `a, b, c` (with optional `: type` annotations) up to `=`
				local names = {}
				local j = k
				local ok = true
				while j <= to do
					local nt = tokens[j]
					if nt.kind ~= "name" then
						ok = false
						break
					end
					table.insert(names, nt.v)
					j += 1
					if is(tokens[j], ":") then
						-- skip a type annotation up to `,` or `=`
						j += 1
						while j <= to and not is(tokens[j], ",") and not is(tokens[j], "=") do
							j += 1
						end
					end
					if is(tokens[j], ",") then
						j += 1
					else
						break
					end
				end
				if ok and is(tokens[j], "=") and (isLocal or #names >= 1) then
					local rhsFrom = j + 1
					if rhsFrom <= to then
						local rhsTo = exprEnd(tokens, close, rhsFrom, to)
						-- a multiple assignment `a, b = x, y`: take every comma-separated part
						local e = rhsTo
						while is(tokens[e + 1], ",") and e + 2 <= to do
							e = exprEnd(tokens, close, e + 2, to)
						end
						table.insert(
							out,
							{ names = names, rhsFrom = rhsFrom, rhsTo = e, line = t.line, at = k }
						)
						k = j
					end
				end
			end
		end
		k += 1
	end
	return out
end

-- locals assigned from a module ref (TextFilter, Notifications, Mail) or a store constructor
local function addAliases(a: any, tokens: { any }, asgs: { any })
	for _, asg in asgs do
		if #asg.names == 1 then
			local name = asg.names[1]
			local calls = false
			local storeCtor = false
			for k = asg.rhsFrom, asg.rhsTo do
				local t = tokens[k]
				if t.kind == "name" and TF_ALL[t.v] and is(tokens[k - 1], ".") then
					calls = true
				end
				if
					t.kind == "name"
					and (t.v == "sortedMap" or t.v == "ordered")
					and (is(tokens[k - 1], ".") or is(tokens[k - 1], ":"))
					and is(tokens[k + 1], "(")
				then
					storeCtor = true
				end
			end
			if storeCtor then
				a.store[name] = true
			elseif not calls then
				if rangeHasName(tokens, asg.rhsFrom, asg.rhsTo, a.tf) then
					a.tf[name] = true
				end
				if rangeHasName(tokens, asg.rhsFrom, asg.rhsTo, a.notif) then
					a.notif[name] = true
				end
				if rangeHasName(tokens, asg.rhsFrom, asg.rhsTo, a.mail) then
					a.mail[name] = true
				end
			end
		end
	end
end

local function newAliases(): any
	return { tf = { TextFilter = true }, notif = { Notifications = true }, mail = { Mail = true }, store = {} }
end

local function copyAliases(a: any): any
	return {
		tf = table.clone(a.tf),
		notif = table.clone(a.notif),
		mail = table.clone(a.mail),
		store = table.clone(a.store),
	}
end

-- parameter types that can't carry text: a parameter annotated with only these isn't a source
local SAFE_TYPES = { number = true, boolean = true }

-- a name or a dotted name (`M.onRename`) starting at token i -> (the name, the token after it);
-- nil if token i isn't a name
local function dottedName(tokens: { any }, i: number): (string?, number)
	local t = tokens[i]
	if t == nil or t.kind ~= "name" then
		return nil, i
	end
	local name, j = t.v, i + 1
	while is(tokens[j], ".") and tokens[j + 1] and tokens[j + 1].kind == "name" do
		name ..= "." .. tokens[j + 1].v
		j += 2
	end
	return name, j
end

-- every function definition in the file by name, plain or dotted: `local function f(`,
-- `function f(`, `function M.f(`, `local f = function(`, `f = function(` and `M.f = function(`
-- -> { { fnIndex (the `function` token), open } }. Methods (`function M:f(`) aren't included.
local function definitions(tokens: { any }): { [string]: { any } }
	local defs = {}
	local function put(name: string, fnIndex: number, open: number)
		defs[name] = defs[name] or {}
		table.insert(defs[name], { fnIndex = fnIndex, open = open })
	end
	for i, t in tokens do
		if is(t, "function") and t.kind == "kw" then
			local prev = tokens[i - 1]
			local afterDot = prev ~= nil and prev.kind == "op" and (prev.v == "." or prev.v == ":")
			local name, open = dottedName(tokens, i + 1)
			if name ~= nil and is(tokens[open], "(") and not afterDot then
				put(name, i, open) -- `function f(` / `local function f(` / `function M.f(`
			elseif is(tokens[i + 1], "(") and is(prev, "=") then
				-- walk back over `a.b.c` before the `=`
				local s = i - 2
				if tokens[s] and tokens[s].kind == "name" then
					while is(tokens[s - 1], ".") and tokens[s - 2] and tokens[s - 2].kind == "name" do
						s -= 2
					end
					local before = tokens[s - 1]
					local chained = before ~= nil
						and before.kind == "op"
						and (before.v == "." or before.v == ":" or before.v == "]" or before.v == ")")
					local target, after = dottedName(tokens, s)
					if target ~= nil and after == i - 1 and not chained then
						put(target, i, i + 1) -- `local f = function(` / `f = function(` / `M.f = function(`
					end
				end
			end
		end
	end
	return defs
end

-- the action handlers: { fnIndex, params = { name }, bodyFrom, bodyTo }. A handler is an inline
-- function or a name defined in the same file (`handler = onRename`); every parameter after the
-- first (the player) is a source unless annotated with only number/boolean types.
local function handlers(tokens: { any }, close: { [number]: number }): { any }
	local found = {}
	local seen = {}
	local defs = definitions(tokens)
	local function add(fnIndex: number, open: number?)
		open = open or fnIndex + 1
		if seen[fnIndex] or not is(tokens[open], "(") then
			return
		end
		seen[fnIndex] = true
		local shut = close[open]
		local bodyTo = close[fnIndex]
		if shut == nil or bodyTo == nil then
			return
		end
		-- params: split at depth-0 commas
		local params = {}
		local k = open + 1
		local index = 0
		while k < shut do
			local t = tokens[k]
			if t.kind == "name" or is(t, "...") then
				index += 1
				local name = t.v
				local safe = false
				local j = k + 1
				if is(tokens[j], ":") then
					j += 1
					local depth = 0
					local typeNames, unsafe = 0, false
					while j < shut do
						local u = tokens[j]
						if u.kind == "op" and (u.v == "(" or u.v == "{" or u.v == "<") then
							depth += 1
							unsafe = true -- a table, function or generic type
						elseif u.kind == "op" and (u.v == ")" or u.v == "}" or u.v == ">") then
							depth -= 1
						elseif depth == 0 and is(u, ",") then
							break
						end
						if u.kind == "name" or u.kind == "kw" then
							typeNames += 1
							if not SAFE_TYPES[u.v] then
								unsafe = true
							end
						end
						j += 1
					end
					safe = typeNames > 0 and not unsafe
				end
				if index > 1 and not safe then
					table.insert(params, name)
				end
				k = j
			end
			k += 1
		end
		table.insert(found, { fnIndex = fnIndex, params = params, bodyFrom = shut + 1, bodyTo = bodyTo - 1 })
	end
	-- `<key> = function(`, `<key> = <name>` / `<key> = <a>.<b>` (a function defined in this file),
	-- or any of those wrapped in a call, `<key> = guard(onRename)`: every argument of the call that
	-- is a function, or names one defined in this file, is taken as the handler
	local function addValue(at: number, depth: number?)
		local level = depth or 0
		if is(tokens[at], "function") then
			add(at, nil)
			return
		end
		local name, j = dottedName(tokens, at)
		if name == nil then
			return
		end
		local after = tokens[j]
		if is(after, "(") and close[j] and after.line == tokens[j - 1].line then
			if level >= 3 then
				return
			end
			local shut = close[j]
			local k = j + 1
			while k < shut do
				addValue(k, level + 1)
				-- on to the next argument at this call's depth
				while k < shut and not is(tokens[k], ",") do
					local u = tokens[k]
					local opens = (u.kind == "op" and (u.v == "(" or u.v == "{" or u.v == "["))
						or is(u, "function")
					if opens and close[k] then
						k = close[k]
					end
					k += 1
				end
				k += 1
			end
			return
		end
		if
			defs[name]
			and (
				after == nil
				or after.v == ","
				or after.v == "}"
				or after.v == ")"
				or after.v == ";"
				or after.line ~= tokens[j - 1].line
			)
		then
			for _, d in defs[name] do
				add(d.fnIndex, d.open)
			end
		end
	end
	for i, t in tokens do
		-- handler = function(player, ...) / handler = onRename
		if t.kind == "name" and t.v == "handler" and is(tokens[i + 1], "=") then
			addValue(i + 2)
		end
		-- actions.rename = function(player, ...) / actions.rename = onRename
		if
			t.kind == "name"
			and t.v == "actions"
			and is(tokens[i + 1], ".")
			and tokens[i + 2]
			and tokens[i + 2].kind == "name"
			and is(tokens[i + 3], "=")
		then
			addValue(i + 4)
		end
		-- actions = { name = function(player, ...) } / actions = { name = onRename }
		if
			t.kind == "name"
			and t.v == "actions"
			and is(tokens[i + 1], "=")
			and is(tokens[i + 2], "{")
			and close[i + 2]
		then
			local open, shut = i + 2, close[i + 2]
			local k = open + 1
			while k < shut do
				local u = tokens[k]
				if u.kind == "name" and is(tokens[k + 1], "=") then
					addValue(k + 2)
				end
				-- skip nested brackets and function bodies (entries only at the table's top level)
				local opens = (u.kind == "op" and (u.v == "(" or u.v == "{" or u.v == "["))
					or is(u, "function")
				if opens and close[k] then
					k = close[k]
				end
				k += 1
			end
		end
	end
	table.sort(found, function(a, b)
		return a.fnIndex < b.fnIndex
	end)
	return found
end

-- the token ranges (inclusive) of TextFilter calls in [a, b]: <tf receiver>.<fn>( ... )
local function tfCalls(
	tokens: { any },
	close: { [number]: number },
	a: number,
	b: number,
	aliases: any
): { any }
	local out = {}
	for k = a, b do
		local t = tokens[k]
		if
			t.kind == "name"
			and TF_ALL[t.v]
			and (is(tokens[k - 1], ".") or is(tokens[k - 1], ":"))
			and is(tokens[k + 1], "(")
			and close[k + 1]
		then
			local rs = receiverStart(tokens, close, k - 1)
			if rangeHasName(tokens, rs, k - 2, aliases.tf) then
				table.insert(out, { fn = t.v, from = rs, argsFrom = k + 2, to = close[k + 1], line = t.line })
			end
		end
	end
	return out
end

local function inRanges(k: number, ranges: { any }): boolean
	for _, r in ranges do
		if k >= r.from and k <= r.to then
			return true
		end
	end
	return false
end

-- sinks in [a, b]: { label, from, to (argument tokens), line }
local function sinks(
	tokens: { any },
	close: { [number]: number },
	a: number,
	b: number,
	aliases: any
): { any }
	local out = {}
	local function call(k: number, label: string)
		local open = k + 1
		if is(tokens[open], "(") and close[open] then
			table.insert(out, { label = label, from = open + 1, to = close[open] - 1, line = tokens[k].line })
		end
	end
	for k = a, b do
		local t = tokens[k]
		local prev = tokens[k - 1]
		local dotted = prev ~= nil and prev.kind == "op" and (prev.v == "." or prev.v == ":")
		if t.kind == "name" and dotted then
			local owner = tokens[k - 2]
			local ownerName = if owner and owner.kind == "name" then owner.v else nil
			if t.v == "new" and ownerName == "Instance" then
				local open = k + 1
				if is(tokens[open], "(") and close[open] then
					-- a Text / Name prop in a table among the arguments
					for j = open + 1, close[open] - 1 do
						local u = tokens[j]
						if
							u.kind == "name"
							and (u.v == "Text" or u.v == "Name")
							and is(tokens[j + 1], "=")
						then
							local from = j + 2
							table.insert(out, {
								label = "Instance.new " .. u.v,
								from = from,
								to = exprEnd(tokens, close, from, close[open] - 1),
								line = u.line,
							})
						end
					end
				end
			elseif ownerName == "replicate" and (t.v == "setAll" or t.v == "set") then
				call(k, "ctx.replicate." .. t.v)
			elseif ownerName == "net" and (t.v == "fire" or t.v == "fireAll") then
				call(k, "ctx.net." .. t.v)
			elseif ownerName == "messages" and t.v == "send" then
				call(k, "ctx.data.messages.send")
			elseif ownerName == "shared" and t.v == "update" then
				call(k, "ctx.data.shared.update")
			elseif t.v == "SetAttribute" and prev.v == ":" then
				call(k, ":SetAttribute")
			elseif (t.v == "Text" or t.v == "Name") and prev.v == "." and is(tokens[k + 1], "=") then
				local rhs = k + 2
				if rhs <= b then
					table.insert(out, {
						label = "." .. t.v .. " =",
						from = rhs,
						to = exprEnd(tokens, close, rhs, b),
						line = t.line,
					})
				end
			elseif is(tokens[k + 1], "(") then
				local rs = receiverStart(tokens, close, k - 1)
				if
					(t.v == "send" or t.v == "schedule") and rangeHasName(tokens, rs, k - 2, aliases.notif)
				then
					call(k, "Notifications." .. t.v)
				elseif t.v == "send" and rangeHasName(tokens, rs, k - 2, aliases.mail) then
					call(k, "Mail.send")
				elseif STORE_WRITES[t.v] then
					local isStore = rangeHasName(tokens, rs, k - 2, aliases.store)
						or rangeHasName(tokens, rs, k - 2, { sortedMap = true, ordered = true })
					if isStore then
						call(k, "a store write (" .. t.v .. ")")
					end
				end
			end
		end
	end
	return out
end

-- is the name token at k a value (not a field name, a table key or a call's method)?
local function isValueRef(tokens: { any }, k: number): boolean
	local prev, nextT = tokens[k - 1], tokens[k + 1]
	if prev and prev.kind == "op" and (prev.v == "." or prev.v == ":") then
		return false
	end
	if nextT and nextT.kind == "op" and nextT.v == "=" then
		return false -- a table key (`{ pet = name }`) or an assignment target
	end
	return true
end

local function textPreserving(tokens: { any }, a: number, b: number, skip: { any }): boolean
	if a == b then
		return true -- `local x = name`
	end
	for k = a, b do
		if not inRanges(k, skip) then
			local t = tokens[k]
			if is(t, "..") then
				return true
			end
			if t.kind == "name" and TEXT_FNS[t.v] and (is(tokens[k - 1], ".") or is(tokens[k - 1], ":")) then
				return true
			end
		end
	end
	-- `(name)`
	return is(tokens[a], "(") and b == a + 2 and is(tokens[b], ")")
end

function GuardTextFilter.scanSource(source: string, ctx: any): { string }
	local findings = {}
	if type(source) ~= "string" or ctx == nil or not ctx.isServer then
		return findings
	end
	local path = ctx.path or "?"
	local raw = string.split(source, "\n")
	local tokens = tokenize(source)
	if #tokens == 0 then
		return findings
	end
	local close = matchAll(tokens)
	local fileAliases = newAliases()
	addAliases(fileAliases, tokens, assignments(tokens, close, 1, #tokens))
	local reported = {}
	for _, h in handlers(tokens, close) do
		if #h.params == 0 or h.bodyFrom > h.bodyTo then
			continue
		end
		local tainted: { [string]: boolean } = {}
		for _, p in h.params do
			tainted[p] = true
		end
		local records: { [string]: boolean } = {}
		local asgs = assignments(tokens, close, h.bodyFrom, h.bodyTo)
		local aliases = copyAliases(fileAliases)
		addAliases(aliases, tokens, asgs)
		local calls = tfCalls(tokens, close, h.bodyFrom, h.bodyTo, aliases)
		-- walk assignments and calls in order to grow the taint and the records
		table.sort(asgs, function(x, y)
			return x.at < y.at
		end)
		for _, asg in asgs do
			local hasTaint = false
			for k = asg.rhsFrom, asg.rhsTo do
				local t = tokens[k]
				if
					(t.kind == "name" or is(t, "..."))
					and tainted[t.v]
					and isValueRef(tokens, k)
					and not inRanges(k, calls)
				then
					hasTaint = true
				end
			end
			if hasTaint and textPreserving(tokens, asg.rhsFrom, asg.rhsTo, calls) then
				for _, n in asg.names do
					tainted[n] = true
				end
			end
			for _, c in calls do
				if (c.fn == "store" or c.fn == "filter") and c.from >= asg.rhsFrom and c.to <= asg.rhsTo then
					if asg.names[2] then
						records[asg.names[2]] = true
					end
				end
			end
		end
		-- a TextFilter call never clears its argument: only the values it returns are clean (they
		-- are new names, never tainted); the original stays player text after the call too
		for _, s in sinks(tokens, close, h.bodyFrom, h.bodyTo, aliases) do
			if allowedLine(raw[s.line]) then
				continue
			end
			for k = s.from, s.to do
				local t = tokens[k]
				if
					(t.kind ~= "name" and not is(t, "..."))
					or inRanges(k, calls)
					or not isValueRef(tokens, k)
				then
					continue
				end
				local key = `{s.line}|{s.label}|{t.v}`
				if reported[key] then
					continue
				end
				if tainted[t.v] then
					reported[key] = true
					table.insert(
						findings,
						`{path}:{s.line}: [{CHECK}] player text '{t.v}' reaches {s.label} without TextFilter {DOC}`
					)
				elseif records[t.v] then
					local nextT = tokens[k + 1]
					local field = nextT ~= nil
						and nextT.kind == "op"
						and (nextT.v == "." or nextT.v == ":" or nextT.v == "[")
					if not field then
						reported[key] = true
						table.insert(
							findings,
							`{path}:{s.line}: [{CHECK}] filter record '{t.v}' reaches {s.label} whole: pass TextFilter.shown(...) or .public {DOC}`
						)
					end
				end
			end
		end
	end
	table.sort(findings, function(a, b)
		local la = tonumber(string.match(a, ":(%d+): %[")) or 0
		local lb = tonumber(string.match(b, ":(%d+): %[")) or 0
		if la ~= lb then
			return la < lb
		end
		return a < b
	end)
	return findings
end

--------------------------------------------------------------------------------
-- files
--------------------------------------------------------------------------------

-- folders never scanned: tool-owned, dependencies, the framework submodule of a project
local SKIPPED = {
	[".git"] = true,
	[".cache"] = true,
	[".worktrees"] = true,
	["node_modules"] = true,
	["Packages"] = true,
	["ServerPackages"] = true,
	["DevPackages"] = true,
}

local function hasSegment(rel: string, segment: string): boolean
	local parts = string.split(rel, "/")
	for i = 1, #parts - 1 do
		if parts[i] == segment then
			return true
		end
	end
	return false
end

local function isLuau(path: string): boolean
	return (string.match(path, "%.luau$") ~= nil or string.match(path, "%.lua$") ~= nil)
		and string.match(path, "%.spec%.luau?$") == nil
end

local function walk(fs: any, dir: string, out: { string })
	if not fs.isDir(dir) then
		return
	end
	local entries = fs.readDir(dir)
	table.sort(entries)
	for _, entry in entries do
		local path = if dir == "." then entry else dir .. "/" .. entry
		if fs.isDir(path) then
			if not SKIPPED[entry] then
				walk(fs, path, out)
			end
		elseif isLuau(path) then
			table.insert(out, path)
		end
	end
end

local function scanFiles(fs: any, files: { string }, base: string?): { string }
	local findings = {}
	for _, path in files do
		local rel = if base and base ~= "." then string.sub(path, #base + 2) else path
		if hasSegment(rel, "server") and not hasSegment(rel, "client") then
			local ok, source = pcall(fs.readFile, path)
			if ok then
				for _, f in GuardTextFilter.scanSource(source, { path = path, isServer = true }) do
					table.insert(findings, f)
				end
			end
		end
	end
	return findings
end

function GuardTextFilter.scanGame(fs: any, dir: string): { string }
	local files = {}
	if dir == "." then
		local core = "studwork"
		local ok, Roots = pcall(require, "./Roots")
		if ok and type(Roots) == "table" and type(Roots.CORE) == "string" then
			core = string.match(Roots.CORE, "^[^/]+") or Roots.CORE
		end
		local entries = fs.readDir(".")
		table.sort(entries)
		for _, entry in entries do
			if entry ~= core and not SKIPPED[entry] and fs.isDir(entry) then
				walk(fs, entry, files)
			end
		end
	else
		walk(fs, dir, files)
	end
	return scanFiles(fs, files, dir)
end

function GuardTextFilter.scanAll(fs: any): { string }
	local files = {}
	walk(fs, "packages/kits", files)
	walk(fs, "examples/modules", files)
	return scanFiles(fs, files, nil)
end

--------------------------------------------------------------------------------
-- self-test: the planted cases (docs/framework/kits/textfilter.md "Self-test")
--------------------------------------------------------------------------------

local HEADER = table.concat({
	"local TextFilter = require(Modules.TextFilter.module)",
	"local Notifications = require(Modules.Notifications.module)",
	"local Ev = Net.Shown",
	"local M = {}",
	"function M.part(ctx, part, instance, other, key)",
	"\treturn {",
	"\t\tactions = {",
}, "\n")
local FOOTER = "\n\t\t},\n\t}\nend\nreturn M\n"

-- an action handler `rename(player, name: string)` with `body` lines
local function plant(body: { string }, params: string?): string
	return HEADER
		.. "\n\t\t\trename = { limit = { rate = 1, burst = 2 }, handler = function(player, "
		.. (params or "name: string")
		.. ")\n\t\t\t\t"
		.. table.concat(body, "\n\t\t\t\t")
		.. "\n\t\t\tend },"
		.. FOOTER
end

GuardTextFilter.PLANTED_FAIL = {
	{ "setAll", plant({ 'ctx.replicate.setAll("sign", name)' }), "reaches ctx.replicate.setAll" },
	{ ".Text =", plant({ "part.BillboardGui.Label.Text = name" }), "reaches .Text =" },
	{
		"concat into fireAll",
		plant({ 'local shown = "Pet: " .. name', "ctx.net.fireAll(Ev, shown)" }),
		"player text 'shown' reaches ctx.net.fireAll",
	},
	{ "SetAttribute", plant({ 'instance:SetAttribute("Title", name)' }), "reaches :SetAttribute" },
	{ "back to its own player", plant({ "ctx.net.fire(player, Ev, name)" }), "reaches ctx.net.fire" },
	{
		"replicate.set other",
		plant({ 'ctx.replicate.set(other, "sign", name)' }),
		"reaches ctx.replicate.set",
	},
	{
		"shared.update",
		plant({ "ctx.data.shared.update(key, function()", "\treturn name", "end)" }),
		"reaches ctx.data.shared.update",
	},
	{
		"sorted map set",
		plant({ 'local m = ctx.data.sortedMap("signs")', "m.set(key, name, 3600)" }),
		"reaches a store write (set)",
	},
	{
		"Notifications send params",
		plant({ 'ctx.deps[Notifications].send(player.UserId, "gift", { pet = name })' }),
		"reaches Notifications.send",
	},
	{
		"whole Stored record",
		plant({ 'local ok, s = TextFilter.store(player, name, "public")', 'ctx.replicate.setAll("sign", s)' }),
		"filter record 's' reaches ctx.replicate.setAll whole",
	},
	-- beyond the page's list: the other documented sinks and forms
	{
		"interpolated string",
		plant({ "ctx.net.fireAll(Ev, `Pet: {name}`)" }),
		"player text 'name' reaches ctx.net.fireAll",
	},
	{
		"string.upper copy",
		plant({ "local loud = string.upper(name)", "part.Name = loud" }),
		"player text 'loud' reaches .Name =",
	},
	{
		"Instance.new Text prop",
		plant({ 'local l = Instance.new("TextLabel", { Text = name })' }),
		"reaches Instance.new Text",
	},
	{
		"direct actions entry, unannotated",
		HEADER
			.. '\n\t\t\trename = function(player, name)\n\t\t\t\tctx.replicate.setAll("sign", name)\n\t\t\tend,'
			.. FOOTER,
		"reaches ctx.replicate.setAll",
	},
	{
		"messages.send",
		plant({ "ctx.data.messages.send(other.UserId, { sign = name })" }),
		"reaches ctx.data.messages.send",
	},
	{
		"ordered store through ctx.data",
		plant({ 'ctx.data.ordered("names").update(key, function()', "\treturn name", "end)" }),
		"reaches a store write (update)",
	},
	{
		"a filter call on a LATER line doesn't clear",
		plant({ 'ctx.replicate.setAll("sign", name)', 'TextFilter.filter(player, name, "public")' }),
		"reaches ctx.replicate.setAll",
	},
	-- a TextFilter call never clears the original: only its return values are clean
	{
		"filtered, then the original sent anyway",
		plant({
			'local ok, rec = ctx.deps[TextFilter].filter(player, name, "public")',
			"if not ok then return end",
			'ctx.replicate.setAll("sign", name)',
		}),
		"player text 'name' reaches ctx.replicate.setAll",
	},
	{
		"private filter, then the original to everyone",
		plant({ 'TextFilter.filter(player, name, "private")', "ctx.net.fireAll(Ev, name)" }),
		"player text 'name' reaches ctx.net.fireAll",
	},
	{
		"stored, then the original replicated",
		plant({
			'local ok, s = TextFilter.store(player, name, "public")',
			'ctx.replicate.setAll("sign", name)',
		}),
		"player text 'name' reaches ctx.replicate.setAll",
	},
	-- handlers defined as named functions in the same file
	{
		"named local function handler",
		table.concat({
			"local M = {}",
			"function M.part(ctx, part)",
			"\tlocal function onRename(player, name: string)",
			'\t\tctx.replicate.setAll("sign", name)',
			"\tend",
			"\tpart.actions = {",
			"\t\trename = { limit = { rate = 1, burst = 2 }, handler = onRename },",
			"\t}",
			"end",
			"return M",
		}, "\n"),
		"player text 'name' reaches ctx.replicate.setAll",
	},
	{
		"local = function, as an actions entry",
		table.concat({
			"local M = {}",
			"function M.part(ctx, part)",
			"\tlocal onTitle = function(player, title)",
			"\t\tpart.Name = title",
			"\tend",
			"\tpart.actions = {",
			"\t\ttitle = onTitle,",
			"\t}",
			"end",
			"return M",
		}, "\n"),
		"player text 'title' reaches .Name =",
	},
	{
		"actions.<name> = a named function",
		table.concat({
			"local M = {}",
			"function M.part(ctx, part)",
			"\tlocal function onSign(player, text)",
			"\t\tctx.net.fireAll(Ev, text)",
			"\tend",
			"\tpart.actions = {}",
			"\tpart.actions.sign = onSign",
			"end",
			"return M",
		}, "\n"),
		"player text 'text' reaches ctx.net.fireAll",
	},
	{
		"a dotted named handler (handler = M.onRename)",
		table.concat({
			"local M = {}",
			"function M.onRename(player, name)",
			'\tctx.replicate.setAll("sign", name)',
			"end",
			"function M.part(ctx, part)",
			"\tpart.actions = { rename = { limit = { rate = 1, burst = 2 }, handler = M.onRename } }",
			"end",
			"return M",
		}, "\n"),
		"player text 'name' reaches ctx.replicate.setAll",
	},
	{
		"a dotted function value as an actions entry (Handlers.onSign = function)",
		table.concat({
			"local Handlers = {}",
			"Handlers.onSign = function(player, text)",
			"\tctx.net.fireAll(Ev, text)",
			"end",
			"return function(ctx, part)",
			"\tpart.actions = { sign = Handlers.onSign }",
			"end",
		}, "\n"),
		"player text 'text' reaches ctx.net.fireAll",
	},
	{
		"a handler wrapped in a call (handler = guard(onRename))",
		table.concat({
			"return function(ctx, part)",
			"\tlocal function onRename(player, name)",
			'\t\tctx.replicate.setAll("sign", name)',
			"\tend",
			"\tpart.actions = { rename = { limit = { rate = 1, burst = 2 }, handler = guard(onRename) } }",
			"end",
		}, "\n"),
		"player text 'name' reaches ctx.replicate.setAll",
	},
	{
		"a dotted handler wrapped with more arguments (handler = Util.wrap(M.onTitle, 2))",
		table.concat({
			"local M = {}",
			"function M.onTitle(player, title)",
			"\tpart.Name = title",
			"end",
			"return function(ctx, part)",
			"\tpart.actions = { title = { handler = Util.wrap(M.onTitle, 2) } }",
			"end",
		}, "\n"),
		"player text 'title' reaches .Name =",
	},
	{
		"an inline function wrapped in a call (handler = guard(function(player, name) ... end))",
		table.concat({
			"return function(ctx, part)",
			"\tpart.actions = { rename = { handler = guard(function(player, name)",
			'\t\tctx.replicate.setAll("sign", name)',
			"\tend) } }",
			"end",
		}, "\n"),
		"player text 'name' reaches ctx.replicate.setAll",
	},
	-- every wire value is a source unless annotated number/boolean
	{
		"a param typed any",
		plant({ 'ctx.replicate.setAll("sign", name)' }, "name: any"),
		"player text 'name'",
	},
	{
		"a param typed as a table",
		plant({ 'ctx.replicate.setAll("sign", data)' }, "data: { title: string }"),
		"player text 'data' reaches ctx.replicate.setAll",
	},
	{
		"varargs",
		plant({ "ctx.net.fireAll(Ev, ...)" }, "..."),
		"player text '...' reaches ctx.net.fireAll",
	},
	{
		"a union with a text type",
		plant({ 'ctx.replicate.setAll("sign", label)' }, "label: number | string"),
		"player text 'label'",
	},
}

GuardTextFilter.PLANTED_PASS = {
	{
		"store then shown",
		plant({
			'local ok, s = TextFilter.store(player, name, "public")',
			'ctx.replicate.setAll("sign", TextFilter.shown(s))',
		}),
	},
	{
		"textFor then fire",
		plant({
			'local t = TextFilter.textFor(player, player, name, "private")',
			"ctx.net.fire(player, Ev, t)",
		}),
	},
	{
		"guarded non-text param",
		plant({
			'if not table.find({ "red", "blue" }, name) then return end',
			"-- a colour from a fixed list, not player text",
			'ctx.replicate.setAll("colour", name) -- guard: allow textfilter',
		}),
	},
	{
		"filtered public string through an alias",
		plant({
			"local tf = ctx.deps[TextFilter]",
			'local ok, r = tf.filter(player, name, "public")',
			'if ok then ctx.replicate.setAll("sign", r.public) end',
		}),
	},
	{
		"a non-string param",
		plant({ 'ctx.replicate.setAll("count", amount)' }, "amount: number"),
	},
	{
		"number and boolean params (also optional)",
		plant({ 'ctx.replicate.setAll("state", { on = on, n = n })' }, "on: boolean, n: number?"),
	},
	{
		"a named handler that sends only the filtered string",
		table.concat({
			"local M = {}",
			"function M.part(ctx, part)",
			"\tlocal function onRename(player, name: string)",
			'\t\tlocal ok, r = ctx.deps[TextFilter].filter(player, name, "public")',
			'\t\tif ok then ctx.replicate.setAll("sign", r.public) end',
			"\tend",
			"\tpart.actions = { rename = { limit = { rate = 1, burst = 2 }, handler = onRename } }",
			"end",
			"return M",
		}, "\n"),
	},
	{
		"a dotted, wrapped handler that sends only the filtered string",
		table.concat({
			"local M = {}",
			"function M.onRename(player, name: string)",
			'\tlocal ok, r = ctx.deps[TextFilter].filter(player, name, "public")',
			'\tif ok then ctx.replicate.setAll("sign", r.public) end',
			"end",
			"function M.part(ctx, part)",
			"\tpart.actions = { rename = { handler = guard(M.onRename) }, alias = { handler = M.onRename } }",
			"end",
			"return M",
		}, "\n"),
	},
	{
		"a wrapper's other arguments aren't handlers (a helper passed alongside, number params)",
		table.concat({
			"local M = {}",
			"function M.onScore(player, amount: number)",
			'\tctx.replicate.setAll("score", amount)',
			"end",
			"local function describe(player, name)",
			"\treturn name",
			"end",
			"function M.part(ctx, part)",
			"\tpart.actions = { score = { handler = guard(M.onScore, 5) } }",
			"end",
			"return M",
		}, "\n"),
	},
	{
		"a literal and the player's own name",
		plant({ 'ctx.replicate.setAll("sign", "Welcome")', "part.Name = player.Name" }),
	},
	{
		"the param as a table key only",
		plant({ "local counts = {}", 'ctx.replicate.setAll("counts", { name = 1 })' }),
	},
}

function GuardTextFilter.selfTest(): { string }
	local failures = {}
	local server = { path = "games/x/modules/m/server/init.luau", isServer = true }
	for _, case in GuardTextFilter.PLANTED_FAIL do
		local name, source, want = case[1], case[2], case[3]
		local got = GuardTextFilter.scanSource(source, server)
		local hit = false
		for _, f in got do
			if string.find(f, "[" .. CHECK .. "]", 1, true) and string.find(f, want, 1, true) then
				hit = true
			end
		end
		if not hit then
			table.insert(
				failures,
				`{name}: expected a finding containing "{want}", got: {table.concat(got, " | ")}`
			)
		end
	end
	for _, case in GuardTextFilter.PLANTED_PASS do
		local name, source = case[1], case[2]
		local got = GuardTextFilter.scanSource(source, server)
		if #got > 0 then
			table.insert(failures, `{name}: expected no findings, got: {table.concat(got, " | ")}`)
		end
	end
	-- client code isn't scanned
	local clientGot = GuardTextFilter.scanSource(
		GuardTextFilter.PLANTED_FAIL[1][2],
		{ path = "games/x/modules/m/client/init.luau", isServer = false }
	)
	if #clientGot > 0 then
		table.insert(failures, "client code: expected no findings")
	end
	return failures
end

GuardTextFilter._tokenize = tokenize

return GuardTextFilter
