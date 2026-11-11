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
	pruneKitLocals(src)             -> src               drops `local X = KitDefs:WaitForChild("X")`
	                                    lines nothing uses any more
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

-- Drops `local X = KitDefs:WaitForChild("Y")` lines whose X isn't used anywhere else.
function NewGame.pruneKitLocals(source: string): string
	local out = {}
	for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
		local name = string.match(line, '^local ([%w_]+) = KitDefs:WaitForChild%("[%w_]+"%)$')
		if name then
			-- used = indexed or called somewhere (`Economy:WaitForChild(...)`, `Base.x`)
			if string.find(source, "%f[%w_]" .. name .. "%s*[:%.%[]") == nil then
				continue
			end
		end
		table.insert(out, line)
	end
	return table.concat(out, "\n")
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
