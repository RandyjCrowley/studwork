--!nocheck
--[[
	tools/lune/GuardStrings: the `strings` check of tools/lune/guardrails.luau (v1.7.0,
	docs/framework/kits/localization.md, module-api.md §23.12): hard-coded English in the UI kit,
	kit client parts and framework client code, and string keys without an English default.

	  GuardStrings.scanSource(source, ctx) -> { string }   findings for one file's source;
	                                                       ctx = { path, defaults = { [key] = true }?,
	                                                               namespaces = { [Module] = true }? }
	  GuardStrings.collectDefaults(source, defaults, namespaces?)   the keys a Strings.luau table or a
	                                                       module.luau `strings` field declares
	  GuardStrings.isScanned(path) -> boolean              not a spec, not a Strings.luau default table,
	                                                       not a generated Blink file
	  GuardStrings.scanAll(fs) -> { string }               packages/ui/**, packages/kits/*/*/client/**,
	                                                       packages/framework/client/**
	  GuardStrings.selfTest() -> { string }                planted-violation failures (empty = every
	                                                       planted case behaved); called by --self-test

	Each finding: `<path>:<line>: [strings] <message>` (the shape Guard.parseFinding reads).

	What it flags (comments stripped, one line at a time; a right-hand side that continues on the next
	line is not followed):
	  * a string literal with a letter in the value of a text-like property or prop (Text,
	    PlaceholderText, text, title, label, placeholder, emptyText, message): `Text = "Close"`,
	    `label.Text = "x"`, `text = props.text or "Buy"`, `Text = "Claim " .. name`. A literal compared
	    with `==` or `~=`, or inside a UI.text / UI.useText / StudWork.text call, is not display text;
	  * a literal with letters passed as the text of `Feedback.toast(text)`, `Feedback.pop(text, ...)`
	    or `feedback(player, "<kind>", "<text>")`;
	  * a `UI.text("<key>")` / `UI.useText` / `StudWork.text` / `<name>Text.text` call whose literal key has no English
	    default (a key in ctx.defaults, or any key in the namespace of a module whose `strings` is a
	    function, which the check can't run).
	Allowed: empty strings, strings without letters ("0", "%", "×"), `%d`-style format specs and
	`{param}` placeholders alone, and `-- guard: allow strings` with a reason on the line or above it.
]]

local GuardStrings = {}

local TEXT_PROPS =
	{ "Text", "PlaceholderText", "text", "title", "label", "placeholder", "emptyText", "message" }
local KEY_CALLS = { "UI.text", "UI.useText", "StudWork.text", "Text.text", "useText" }

local function isQuote(c: string): boolean
	return c == '"' or c == "'" or c == "`"
end

-- Index of the closing quote of the literal that opens at `i`.
local function literalEnd(code: string, i: number): number
	local q = string.sub(code, i, i)
	local j = i + 1
	while j <= #code do
		local d = string.sub(code, j, j)
		if d == "\\" then
			j += 2
		elseif d == q then
			return j
		else
			j += 1
		end
	end
	return #code
end

-- Comments replaced by nothing (line count kept); `allowed[n]` = `-- guard: allow strings` on line n.
local function prepare(source: string): ({ string }, { [number]: boolean })
	local code: { string } = {}
	local allowed: { [number]: boolean } = {}
	local inBlock = false
	for n, line in string.split(source, "\n") do
		local out = {}
		local i = 1
		while i <= #line do
			if inBlock then
				local close = string.find(line, "]]", i, true)
				if close == nil then
					break
				end
				inBlock = false
				i = close + 2
				continue
			end
			local c = string.sub(line, i, i)
			if isQuote(c) then
				local j = literalEnd(line, i)
				table.insert(out, string.sub(line, i, j))
				i = j + 1
			elseif string.sub(line, i, i + 1) == "--" then
				if string.find(string.sub(line, i), "guard: allow strings", 1, true) then
					allowed[n] = true
				end
				if string.sub(line, i, i + 3) == "--[[" and not string.find(line, "]]", i + 4, true) then
					inBlock = true
				end
				break
			else
				table.insert(out, c)
				i += 1
			end
		end
		code[n] = table.concat(out)
	end
	return code, allowed
end

local function literals(code: string): { any }
	local found = {}
	local i = 1
	while i <= #code do
		if isQuote(string.sub(code, i, i)) then
			local j = literalEnd(code, i)
			table.insert(found, { text = string.sub(code, i + 1, j - 1), from = i })
			i = j + 1
		else
			i += 1
		end
	end
	return found
end

-- A literal shows English when it has a letter outside `%d`-style format specs and `{param}`s.
local function hasEnglish(text: string): boolean
	local stripped = string.gsub(text, "%%[%-%+ #0]*%d*%.?%d*%a", "")
	stripped = string.gsub(stripped, "{[%w_]*}", "")
	return string.find(stripped, "%a") ~= nil
end

-- Splits the argument list that follows an opening `(` (`rest` starts right after it) into
-- argument source strings (this line only).
local function splitArgs(rest: string): { string }
	local args = {}
	local depth = 1
	local start = 1
	local i = 1
	while i <= #rest do
		local c = string.sub(rest, i, i)
		if isQuote(c) then
			i = literalEnd(rest, i)
		elseif c == "(" or c == "{" or c == "[" then
			depth += 1
		elseif c == ")" or c == "}" or c == "]" then
			depth -= 1
			if depth == 0 then
				table.insert(args, string.sub(rest, start, i - 1))
				return args
			end
		elseif c == "," and depth == 1 then
			table.insert(args, string.sub(rest, start, i - 1))
			start = i + 1
		end
		i += 1
	end
	table.insert(args, string.sub(rest, start))
	return args
end

-- The expression that starts at the beginning of `rest` and stops at a `,` `;` or closing
-- bracket at depth 0, or the end of the line.
local function expressionOf(rest: string): string
	local depth = 0
	local i = 1
	while i <= #rest do
		local c = string.sub(rest, i, i)
		if isQuote(c) then
			i = literalEnd(rest, i)
		elseif c == "(" or c == "{" or c == "[" then
			depth += 1
		elseif c == ")" or c == "}" or c == "]" then
			if depth == 0 then
				return string.sub(rest, 1, i - 1)
			end
			depth -= 1
		elseif (c == "," or c == ";") and depth == 0 then
			return string.sub(rest, 1, i - 1)
		end
		i += 1
	end
	return rest
end

local function keyCallPattern(name: string): string
	return string.gsub(name, "%.", "%%.") .. "%s*%("
end

-- `expr` without its UI.text(...) / useText(...) key calls (those carry keys, not display text).
local function withoutKeyCalls(expr: string): string
	for _, name in KEY_CALLS do
		while true do
			local a, b = string.find(expr, keyCallPattern(name))
			if a == nil then
				break
			end
			local args = splitArgs(string.sub(expr, b + 1))
			local used = 0
			for _, arg in args do
				used += #arg + 1
			end
			expr = string.sub(expr, 1, a - 1) .. " " .. string.sub(expr, b + 1 + used)
		end
	end
	return expr
end

local function firstEnglish(expr: string): string?
	expr = withoutKeyCalls(expr)
	for _, lit in literals(expr) do
		local before = string.sub(expr, 1, lit.from - 1)
		local isComparison = string.match(before, "[=~]=%s*$") ~= nil
		-- the class name of an element or instance (`Text = e("Frame", ...)`), not text
		local isClass = string.match(before, "[%w_%.]*[eE]%s*%(%s*$") ~= nil
			or string.match(before, "createElement%s*%(%s*$") ~= nil
			or string.match(before, "Instance%.new%s*%(%s*$") ~= nil
		if hasEnglish(lit.text) and not isComparison and not isClass then
			return lit.text
		end
	end
	return nil
end

function GuardStrings.collectDefaults(
	source: string,
	into: { [string]: boolean },
	namespaces: { [string]: boolean }?
)
	local joined = table.concat((prepare(source)), "\n")
	for key in string.gmatch(joined, "%[%s*[\"']([%a][%w_]*%.[%w_%.]+)[\"']%s*%]%s*=") do
		into[key] = true
	end
	if namespaces ~= nil then
		local name = string.match(joined, "name%s*=%s*[\"']([%a][%w_]*)[\"']")
		if name ~= nil and string.find(joined, "strings%s*=%s*function") then
			namespaces[name] = true
		end
	end
end

local function hardCoded(path: string, line: number, literal: string): string
	return `{path}:{line}: [strings] hard-coded UI text "{string.sub(literal, 1, 30)}" (use UI.text with a key; docs/framework/kits/localization.md)`
end

function GuardStrings.scanSource(source: string, ctx: any): { string }
	local path: string = if type(ctx) == "table" and ctx.path then ctx.path else "?"
	local defaults: { [string]: boolean } = if type(ctx) == "table" and ctx.defaults then ctx.defaults else {}
	local namespaces: { [string]: boolean } = if type(ctx) == "table" and ctx.namespaces
		then ctx.namespaces
		else {}
	local code, allowed = prepare(source)
	local findings: { string } = {}

	for n, line in code do
		if allowed[n] or allowed[n - 1] then
			continue
		end
		-- 1. text-like properties and props
		for _, prop in TEXT_PROPS do
			local from = 1
			while true do
				local a, b = string.find(line, prop .. "%s*=", from)
				if a == nil then
					break
				end
				from = b + 1
				local before = if a > 1 then string.sub(line, a - 1, a - 1) else ""
				if string.match(before, "[%w_=~<>]") or string.sub(line, b + 1, b + 1) == "=" then
					continue
				end
				local lit = firstEnglish(expressionOf(string.sub(line, b + 1)))
				if lit ~= nil then
					table.insert(findings, hardCoded(path, n, lit))
				end
			end
		end
		-- 2. feedback and toast literals: Feedback.toast(text), Feedback.pop(text, ...), feedback(player, kind, text)
		for _, spec in { { "[%.:]toast", 1 }, { "[%.:]pop", 1 }, { "[%.:]feedback", 3 } } do
			local _, b = string.find(line, spec[1] .. "%s*%(")
			if b ~= nil then
				local arg = splitArgs(string.sub(line, b + 1))[spec[2]]
				local lit = if arg ~= nil then firstEnglish(arg) else nil
				if lit ~= nil then
					table.insert(findings, hardCoded(path, n, lit))
				end
			end
		end
		-- 3. keys without a default
		local seen: { [string]: boolean } = {}
		for _, name in KEY_CALLS do
			for key in string.gmatch(line, keyCallPattern(name) .. "%s*[\"']([^\"']+)[\"']") do
				local ns = string.match(key, "^([%a][%w_]*)%.")
				if not seen[key] and not defaults[key] and not (ns ~= nil and namespaces[ns]) then
					seen[key] = true
					table.insert(
						findings,
						`{path}:{n}: [strings] string key "{key}" has no English default (add it to packages/ui/Strings.luau, the framework's Strings.luau or the module's strings; docs/framework/kits/localization.md)`
					)
				end
			end
		end
	end
	return findings
end

function GuardStrings.isScanned(path: string): boolean
	if string.sub(path, -5) ~= ".luau" or string.find(path, ".spec.", 1, true) then
		return false
	end
	local name = string.match(path, "([^/]+)$")
	return name ~= "Strings.luau" and name ~= "Generated.luau" and name ~= "Net.luau"
end

local function walk(fs: any, dir: string, out: { string })
	if not fs.isDir(dir) then
		return
	end
	for _, entry in fs.readDir(dir) do
		local p = dir .. "/" .. entry
		if fs.isDir(p) then
			walk(fs, p, out)
		else
			table.insert(out, p)
		end
	end
end

function GuardStrings.scanAll(fs: any): { string }
	local defaults: { [string]: boolean } = {}
	local namespaces: { [string]: boolean } = {}
	local all: { string } = {}
	walk(fs, "packages", all)
	table.sort(all)
	for _, p in all do
		if
			p == "packages/ui/Strings.luau"
			or p == "packages/framework/shared/Strings.luau"
			or string.match(p, "^packages/kits/[^/]+/[^/]+/module%.luau$") ~= nil
		then
			GuardStrings.collectDefaults(fs.readFile(p), defaults, namespaces)
		end
	end
	local findings: { string } = {}
	for _, p in all do
		local scanned = string.sub(p, 1, 12) == "packages/ui/"
			or string.match(p, "^packages/kits/[^/]+/[^/]+/client/") ~= nil
			or string.sub(p, 1, 25) == "packages/framework/client"
		if scanned and GuardStrings.isScanned(p) then
			local ctx = { path = p, defaults = defaults, namespaces = namespaces }
			for _, f in GuardStrings.scanSource(fs.readFile(p), ctx) do
				table.insert(findings, f)
			end
		end
	end
	return findings
end

-- The planted cases of the plan: each violation must be flagged, each clean line must pass.
function GuardStrings.selfTest(): { string }
	local failures: { string } = {}
	local ctx = {
		path = "packages/ui/Planted.luau",
		defaults = { ["ui.close"] = true },
		namespaces = { Leaderboards = true },
	}
	local function expectFail(label: string, source: string, path: string?)
		local found = GuardStrings.scanSource(
			source,
			{ path = path or ctx.path, defaults = ctx.defaults, namespaces = ctx.namespaces }
		)
		if #found == 0 then
			table.insert(failures, `planted violation not flagged: {label}`)
		end
	end
	local function expectPass(label: string, source: string)
		local found = GuardStrings.scanSource(source, ctx)
		if #found > 0 then
			table.insert(failures, `clean case flagged: {label}: {found[1]}`)
		end
	end

	expectFail("literal prop in a UI file", 'return e("TextLabel", { Text = "Close" })')
	expectFail("property assignment", 'label.Text = "Your items"')
	expectFail(
		"literal button text in a kit client file",
		'return e(UI.Button, { text = "Buy" })',
		"packages/kits/economy/Shop/client/init.luau"
	)
	expectFail(
		"literal feedback text in framework client",
		'ctx.net.feedback(player, "toast", "Saved!")',
		"packages/framework/client/Hud/init.luau"
	)
	expectFail("toast literal", 'Feedback.toast("Saved!")', "packages/framework/client/Hud/init.luau")
	expectFail("key without a default", 'local t = UI.text("ui.doesNotExist")')
	expectFail("fallback literal", 'Text = props.emptyText or "Nothing here yet."')
	expectFail("concatenated literal", 'Text = "Claim " .. name')

	expectPass("keyed text", 'Text = UI.text("ui.close")')
	expectPass("symbol label", 'Text = "%"')
	expectPass("empty text", 'Text = ""')
	expectPass("asset id", 'Image = "rbxassetid://1"')
	expectPass("allow comment above", '-- guard: allow strings (a brand mark)\nText = "Brand"')
	expectPass("allow comment on the line", 'Text = "Brand" -- guard: allow strings (a brand mark)')
	expectPass("commented out", '-- Text = "Close"\nText = UI.text("ui.close")')
	expectPass("comparison", 'Text = if kind == "a" then UI.text("ui.close") else ""')
	expectPass("function-form namespace", 'Text = UI.text("Leaderboards.board.coins")')
	expectPass("format spec only", 'Text = string.format("%d", n)')
	if GuardStrings.isScanned("packages/ui/Button.spec.luau") then
		table.insert(failures, "a spec file is scanned")
	end
	if GuardStrings.isScanned("packages/ui/Strings.luau") then
		table.insert(failures, "a Strings.luau default table is scanned")
	end
	return failures
end

return GuardStrings
