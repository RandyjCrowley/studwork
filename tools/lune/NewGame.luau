--!strict
--[[
	tools/lune/NewGame: pure helpers of tools/new-game (zero requires; the kit module manifest,
	tools/lune/KitModules.luau read from the kit module definitions, is passed in). Specs:
	NewGame.spec.luau.

	parseArgs(args)                 -> (opts?, error?)   opts = { name, modules: {string}?, designDoc }
	resolveModules(Modules, names)  -> (ordered?, added?, errors?)  adds missing hard dependencies
	                                    (transitively) and reports them in `added`
	rewriteModulesBlock(src, list, kitFolder?) -> (src?, error?)
	                                    keeps the template's commented line of every chosen module
	                                    in the Config `modules = { ... }` block. Lines are either
	                                    v1.2 names (`"Items", -- ...`) or v1.3 module refs
	                                    (`require(Collection:WaitForChild("Items")), -- ...`);
	                                    kitFolder(name) names the Kits folder for added ref lines
	trimDependsOn(src, list)        -> (src?, error?)    the game module's `dependsOn = { ... }`:
	                                    drops the refs of modules not in `list` (adds none)
	pruneKitLocals(src)             -> src               drops the kit locals nothing uses any more:
	                                    `local X = KitDefs:WaitForChild("X")`, `local KitDefs =
	                                    ReplicatedStorage:WaitForChild("Kits")` and `local X =
	                                    require(Y:WaitForChild("Z"))` (repeated until stable)
	applyMarkers(src, chosen)       -> (src?, error?)    the template's module markers (below):
	                                    keeps the code of the chosen modules, drops the rest and
	                                    removes every marker
	markerNames(src)                -> { string }        every module name a marker mentions

	Module markers (templates/new-game, core-v1.3.0 Phase 1 agent E). Comments, so the template
	stays a working game; tools/new-game strips them from every .luau file it writes:
	  -- @if A,B      (own line) block start: kept when ALL of A, B are chosen
	  -- @if A|B      (own line) block start: kept when ANY of A, B is chosen
	  -- @if A,B|C    alternatives of all-of groups: (A and B) or C
	  -- @else        (own line) the other branch
	  -- @end         (own line) block end (blocks nest)
	  <code> -- @if A (end of a code line) keep just this line when the condition holds
	  -- @unless A: <code>   (own line) emit <code> (uncommented, same indent) when the
	                         condition does NOT hold: the replacement for a dropped `-- @if A` line
	moduleName(gameId)              -> string            "example-collector" -> "ExampleCollector"
	deployJson(name, port)          -> table             ids 0 = placeholder (tools/publish refuses)
	readme(name, port, designDoc)   -> string            README stub with a "Status: scaffolded" line
]]

local NewGame = {}

export type Opts = { name: string, modules: { string }?, designDoc: boolean }

local USAGE = "usage: tools/new-game <name> [--modules A,B,C] [--no-design-doc]"
NewGame.USAGE = USAGE

function NewGame.validName(name: any): boolean
	return type(name) == "string" and string.match(name, "^[a-z][a-z0-9%-]+$") ~= nil and #name <= 32
end

function NewGame.parseArgs(args: { string }): (Opts?, string?)
	local name: string? = nil
	local modules: { string }? = nil
	local designDoc = true
	local i = 1
	while i <= #args do
		local a = args[i]
		if a == "--no-design-doc" then
			designDoc = false
		elseif a == "--modules" or string.sub(a, 1, 10) == "--modules=" then
			local value: string?
			if a == "--modules" then
				value = args[i + 1]
				i += 1
			else
				value = string.sub(a, 11)
			end
			if value == nil or string.sub(value, 1, 2) == "--" then
				return nil, "--modules needs a comma-separated list (e.g. --modules Items,Inventory)"
			end
			local list = {}
			for part in string.gmatch(value, "[^,]+") do
				local trimmed = string.match(part, "^%s*(.-)%s*$") :: string
				if trimmed ~= "" then
					table.insert(list, trimmed)
				end
			end
			modules = list
		elseif string.sub(a, 1, 2) == "--" then
			return nil, "unknown option " .. a .. "\n" .. USAGE
		elseif name == nil then
			name = a
		else
			return nil, "unexpected argument " .. a .. "\n" .. USAGE
		end
		i += 1
	end
	if name == nil then
		return nil, USAGE
	end
	if not NewGame.validName(name) then
		return nil,
			"bad name '" .. name .. "': lowercase letters, digits, dashes; 2-32 chars, starts with a letter"
	end
	return { name = name, modules = modules, designDoc = designDoc }, nil
end

-- `Modules` = the KitModules manifest. Returns the modules in boot order (Modules.ORDER) with
-- every hard dependency added, plus the list of added dependency notes.
function NewGame.resolveModules(Modules: any, names: { string }): ({ string }?, { string }?, { string }?)
	local errors: { string } = {}
	local chosen: { [string]: boolean } = {}
	for _, n in names do
		if Modules.isFoundation(n) then
			table.insert(errors, `'{n}' is foundation (always on); leave it out of --modules`)
		elseif not Modules.isModule(n) then
			table.insert(errors, `unknown module '{n}' (known: {table.concat(Modules.ORDER, ", ")})`)
		elseif chosen[n] then
			table.insert(errors, `'{n}' listed twice`)
		else
			chosen[n] = true
		end
	end
	if #errors > 0 then
		return nil, nil, errors
	end
	local added: { string } = {}
	local changed = true
	while changed do
		changed = false
		for _, n in Modules.ORDER do
			if chosen[n] then
				for _, dep in Modules.SPECS[n].requires do
					if not chosen[dep] then
						chosen[dep] = true
						changed = true
						table.insert(added, `{dep} (required by {n})`)
					end
				end
			end
		end
	end
	local order: { string } = {}
	for _, n in Modules.ORDER do
		if chosen[n] then
			table.insert(order, n)
		end
	end
	-- the manifest's resolver must agree (guards against this file drifting from it)
	local resolved, resolveErrors = Modules.resolve(order)
	if resolved == nil then
		return nil, nil, resolveErrors
	end
	return order, added, nil
end

local function lineModule(line: string): string?
	local ref = string.match(line, 'require%([%w_]+:WaitForChild%("([%w_]+)"%)%)')
	if ref then
		return ref
	end
	return string.match(line, '^%s*"([%w_]+)"')
end

-- Rewrites the `<field> = { ... }` block: keeps the lines of the chosen modules (and comments),
-- drops the others; `add` = append a line for each chosen module the block doesn't have.
local function rewriteBlock(
	source: string,
	field: string,
	list: { string },
	add: ((name: string, refStyle: boolean) -> string)?
): (string?, string?)
	local s, e = string.find(source, field .. "%s*=%s*%b{}")
	if s == nil then
		return nil, "could not find `" .. field .. " = { ... }` in the source"
	end
	local block = string.sub(source, s :: number, e :: number)
	local open = string.find(block, "{", 1, true) :: number
	local inner = string.sub(block, open + 1, #block - 1)
	local keep: { [string]: boolean } = {}
	for _, n in list do
		keep[n] = true
	end
	local found: { [string]: boolean } = {}
	local lines: { string } = {}
	local closingIndent = ""
	local refStyle = false
	for line in string.gmatch(inner .. "\n", "([^\n]*)\n") do
		local mod = lineModule(line)
		if mod then
			refStyle = refStyle or string.find(line, "require(", 1, true) ~= nil
			if keep[mod] then
				found[mod] = true
				table.insert(lines, line)
			end
		elseif string.match(line, "^%s*$") then
			closingIndent = line -- trailing indent before `}`
		else
			table.insert(lines, line) -- comments inside the block
		end
	end
	if add then
		for _, n in list do
			if not found[n] then
				table.insert(lines, add(n, refStyle))
				found[n] = true
			end
		end
	end
	local any = false
	for _ in found do
		any = true
	end
	local newBlock
	if not any then
		newBlock = field .. " = {}"
	else
		newBlock = field .. " = {\n" .. table.concat(lines, "\n") .. "\n" .. closingIndent .. "}"
	end
	return string.sub(source, 1, (s :: number) - 1) .. newBlock .. string.sub(source, (e :: number) + 1), nil
end

function NewGame.rewriteModulesBlock(
	source: string,
	list: { string },
	kitFolder: ((name: string) -> string?)?
): (string?, string?)
	local out, err = rewriteBlock(source, "modules", list, function(n: string, refStyle: boolean): string
		local folder = kitFolder and kitFolder(n)
		if refStyle and folder then
			return `\t\trequire({folder}:WaitForChild("{n}")),`
		end
		return '\t\t"' .. n .. '",'
	end)
	if out == nil then
		return nil, "could not find `modules = { ... }` in the Config"
	end
	return out, err
end

function NewGame.trimDependsOn(source: string, list: { string }): (string?, string?)
	return rewriteBlock(source, "dependsOn", list, nil)
end

local KIT_LOCAL_PATTERNS = {
	'^local ([%w_]+) = KitDefs:WaitForChild%("[%w_]+"%)$',
	'^local ([%w_]+) = ReplicatedStorage:WaitForChild%("Kits"%)$',
	'^local ([%w_]+) = require%([%w_]+:WaitForChild%("[%w_]+"%)%)$',
	'^local ([%w_]+) = game:GetService%("%a+"%)$',
}

local function kitLocal(line: string): string?
	local code = string.gsub(line, "%s*%-%-.*$", "")
	for _, pattern in KIT_LOCAL_PATTERNS do
		local name = string.match(code, pattern)
		if name then
			return name
		end
	end
	return nil
end

-- Code without comments (so a name mentioned in a comment doesn't count as a use).
local function stripComments(source: string): string
	local noBlocks = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
	return (string.gsub(noBlocks, "%-%-[^\n]*", ""))
end

local function countWord(code: string, name: string): number
	local n = 0
	for _ in string.gmatch(code, "%f[%w_]" .. name .. "%f[^%w_]") do
		n += 1
	end
	return n
end

-- Drops the kit locals (see the header) whose name isn't used anywhere else, until stable.
function NewGame.pruneKitLocals(source: string): string
	local current = source
	while true do
		local code = stripComments(current)
		local out = {}
		local dropped = false
		for _, line in string.split(current, "\n") do
			local name = kitLocal(line)
			if name and countWord(code, name) - countWord(stripComments(line), name) <= 0 then
				dropped = true
				continue
			end
			table.insert(out, line)
		end
		current = table.concat(out, "\n")
		if not dropped then
			return current
		end
	end
end

-- "A,B|C" -> { { "A", "B" }, { "C" } }: alternatives (|) of all-of groups (,), i.e. (A and B) or C
local function parseCondition(text: string): { { string } }
	local alternatives = {}
	for alt in string.gmatch(text, "[^|]+") do
		local group = {}
		for name in string.gmatch(alt, "[^,%s]+") do
			table.insert(group, name)
		end
		table.insert(alternatives, group)
	end
	return alternatives
end

local function holds(alternatives: { { string } }, chosen: { [string]: boolean }): boolean
	for _, group in alternatives do
		local all = true
		for _, n in group do
			if not chosen[n] then
				all = false
				break
			end
		end
		if all then
			return true
		end
	end
	return false
end

function NewGame.markerNames(source: string): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	local conds: { string } = {}
	for cond in string.gmatch(source, "%-%- @if ([%w_,|]+)") do
		table.insert(conds, cond)
	end
	for cond in string.gmatch(source, "%-%- @unless ([%w_,|]+):") do
		table.insert(conds, cond)
	end
	for _, cond in conds do
		for _, group in parseCondition(cond) do
			for _, n in group do
				if not seen[n] then
					seen[n] = true
					table.insert(out, n)
				end
			end
		end
	end
	table.sort(out)
	return out
end

-- `chosen` = set of enabled module names. Errors: unbalanced @if/@else/@end (with line numbers).
function NewGame.applyMarkers(source: string, chosen: { [string]: boolean }): (string?, string?)
	local out: { string } = {}
	-- stack of { keep = this branch kept, parentKeep, cond = condition result, line }
	local stack: { { keep: boolean, parent: boolean, cond: boolean, sawElse: boolean, line: number } } = {}
	local function active(): boolean
		local top = stack[#stack]
		return top == nil or top.keep
	end
	local lineNo = 0
	local lines = string.split(source, "\n")
	for _, line in lines do
		lineNo += 1
		local blockIf = string.match(line, "^%s*%-%- @if ([%w_,|]+)%s*$")
		if blockIf then
			local parent = active()
			local cond = holds(parseCondition(blockIf), chosen)
			table.insert(
				stack,
				{ keep = parent and cond, parent = parent, cond = cond, sawElse = false, line = lineNo }
			)
			continue
		end
		if string.match(line, "^%s*%-%- @else%s*$") then
			local top = stack[#stack]
			if top == nil or top.sawElse then
				return nil, `line {lineNo}: @else without a matching @if`
			end
			top.sawElse = true
			top.keep = top.parent and not top.cond
			continue
		end
		if string.match(line, "^%s*%-%- @end%s*$") then
			if #stack == 0 then
				return nil, `line {lineNo}: @end without a matching @if`
			end
			table.remove(stack)
			continue
		end
		local indent, unlessCond, alt = string.match(line, "^(%s*)%-%- @unless ([%w_,|]+): (.*)$")
		if indent then
			if active() and not holds(parseCondition(unlessCond), chosen) then
				table.insert(out, indent .. alt)
			end
			continue
		end
		if string.find(line, "-- @", 1, true) and string.match(line, "^%s*%-%- @") then
			return nil, `line {lineNo}: unknown marker '{string.match(line, "@%S*")}'`
		end
		local code, inlineCond = string.match(line, "^(.-)%s*%-%- @if ([%w_,|]+)%s*$")
		if code then
			if active() and holds(parseCondition(inlineCond), chosen) then
				table.insert(out, code)
			end
			continue
		end
		if active() then
			table.insert(out, line)
		end
	end
	if #stack > 0 then
		return nil, `line {stack[#stack].line}: @if without @end`
	end
	return table.concat(out, "\n"), nil
end

function NewGame.moduleName(gameId: string): string
	local out = {}
	for part in string.gmatch(gameId, "[^%-]+") do
		table.insert(out, string.upper(string.sub(part, 1, 1)) .. string.sub(part, 2))
	end
	return table.concat(out)
end

NewGame.PLACEHOLDER_NOTE = "PLACEHOLDER ids (0): create the test and live experiences, paste their "
	.. "universe/place ids here (docs/publishing.md). tools/publish refuses 0 ids."

function NewGame.deployJson(name: string, port: number): { [string]: any }
	return {
		name = name,
		servePort = port,
		idsNote = NewGame.PLACEHOLDER_NOTE,
		test = { universeId = 0, placeId = 0 },
		live = { universeId = 0, placeId = 0 },
	}
end

function NewGame.readme(name: string, port: number, designDoc: boolean, modules: { string }?): string
	local out = {
		"# " .. name,
		"",
		"Status: scaffolded",
		"",
	}
	if designDoc then
		table.insert(out, `- Design doc: [docs/games/{name}.md](../../docs/games/{name}.md)`)
	else
		table.insert(out, "- Design doc: none yet (scaffolded with --no-design-doc)")
	end
	table.insert(
		out,
		`- Modules: {if modules
			then (if #modules == 0 then "foundation only" else table.concat(modules, ", "))
			else "template default (all)"}`
	)
	table.insert(out, `- Dev: \`tools/dev {name}\` (rojo serve on port {port})`)
	table.insert(out, `- Publish: \`tools/publish {name} --test\`, then \`--live\` (docs/publishing.md)`)
	table.insert(out, "- deploy.json ids are placeholders (0) until the experiences exist on Roblox.")
	table.insert(out, "")
	return table.concat(out, "\n")
end

return NewGame
