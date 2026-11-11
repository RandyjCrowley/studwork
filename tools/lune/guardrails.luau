--!nocheck
--[[
	tools/lune/guardrails.luau: checks that keep game agents inside the rules (core-v1.2).
	Run by tools/lint.

	Usage (repo root):
	  lune run tools/lune/guardrails              scan every game folder (tools/lune/Roots.luau:
	                                              games/*, examples/sandbox, examples/overrides/*)
	                                              and templates/new-game + packages + git checks
	  lune run tools/lune/guardrails --self-test  plant one violation of each kind in memory and
	                                              prove every check catches it (also run by lint)
	  lune run tools/lune/guardrails <dir> ...    scan only these game folders (no git checks)

	Checks (each finding: path:line: [check] message):
	  modules   game code uses a core module that is not in its GameConfig.modules:
	            Core.<Module>.x, Core.Client.Actions.<action> of that module, or Core internals
	            (CoreServer / CoreClient / FrameworkClient) required directly.
	  packages  game work edits packages/: on a branch named game/*, any change under packages/
	            since the merge-base with main; on any branch, staged changes that mix packages/
	            with games/<name>/ (or templates/, outside the core repo). GUARD_ALLOW_CORE=1 skips
	            it (core owner, core repo only). In a games repo (v1.4.0) the core submodule
	            (roblox-core/) counts as packages/, and the core pin is checked: the submodule is a
	            git checkout, its HEAD is exactly a release tag, and it has no local changes.
	  numbers   best-effort heuristic: a balance-looking number literal in game code outside
	            src/shared/Config/ (a numeric argument >= 2 to an Economy/Rarity/Upgrades/Shop tx
	            call, or a cost/price/reward/income/luck/chance/weight/amount/... name = number).
	  remotes   a remote that bypasses core's validated Net: OnServerEvent / OnServerInvoke,
	            Instance.new("RemoteEvent"|"RemoteFunction"|"UnreliableRemoteEvent"), or a Blink
	            `.On(` / `.SetCallback(` in server code (use Core.Net.handle).
	  purchases (v1.3.0, module-api.md §7.1) only the framework may assign
	            MarketplaceService.ProcessReceipt or use Prompt*PurchaseFinished, and only framework
	            Data (and its shared store) may touch DataStoreService / ProfileStore / MemoryStoreService. Checked in game code AND in
	            packages/ (every file outside PURCHASES_ALLOWED: framework Shop/Data/Store/Platform,
	            listed below with a reason).
	  special   (v1.3.0, "nothing is special") a kit (packages/kits/**), an example
	            (examples/**) or a game module (games/*/modules/**) reaches framework internals:
	            anything under ReplicatedStorage.Framework / FrameworkClient / FrameworkTest other
	            than the public StudWork facade (require(...Framework) itself) and UI, the server
	            runtime (ServerScriptService.Framework), RuntimeSlot / CompatDoor by name, or
	            another module's server part (ServerScriptService.Modules.<Other>, core-v1.3.1; the
	            pre-v1.3.1 ServerScriptService.Kits.<Other> too). Catches alias variables,
	            WaitForChild / FindFirstChild chains, literal string concatenation, dynamic child
	            names on those chains and script.Parent climbing into the framework.
	            Framework half (core-v1.3.1 R19): framework code (packages/framework/{shared,
	            server,client}, not test/, specs or Blink outputs) and framework.blink may not name
	            a kit module (whole word, from packages/kits/*/*/module.luau), an event a kit's
	            net.blink declares, a v1.2 kit request event, or Kits / ModuleServers /
	            ModuleClients / kitLoadServer; on the comment-stripped and the normalised text.
	            No allow-list (the core-v1.3.1 transitional list is gone).
	  theme     (D's R4) a hex colour literal ("#RRGGBB"), a Color3.fromRGB literal or an asset id
	            ("rbxassetid://123") in UI or kit/example/game-module client code outside a theme or
	            config file (THEME_ALLOWED): colours and assets come from the theme.
	A line ending in `-- guard: allow <check>` (e.g. `-- guard: allow numbers`) is skipped for
	that check; use it rarely and say why on the line above.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

-- the kit module manifest, read from the kit module definitions (packages/kits/<kit>/<Module>/
-- module.luau since core-v1.3.1; v1.3.0, was the v1.2 module manifest)
local Modules = require("./KitModules").load(fs)

local Guard = {}

-- Files/folders under packages/ allowed to own purchases / persistence (the purchases check).
Guard.PURCHASES_ALLOWED = {
	"packages/framework/server/Shop/", -- the exclusive ProcessReceipt owner (§7.1)
	"packages/framework/server/Platform.luau", -- the engine adapter Shop and Data go through
	"packages/framework/server/Store.luau", -- framework Data's ProfileStore store
	"packages/framework/server/Data.luau",
	"packages/framework/server/SharedStore.luau", -- ctx.data.shared: the framework-owned shared DataStore
	"packages/framework/test/", -- fakes
}

local MODULE_SET = {}
for _, name in Modules.ORDER do
	MODULE_SET[name] = true
end

-- Extracts the module names from a Config init.luau source: module refs
-- (`modules = { require(Modules:WaitForChild("Items"):WaitForChild("module")), ... }`, core-v1.3.1;
-- the v1.3.0 `require(Collection:WaitForChild("Items"))` form) or v1.2 names
-- (`modules = { "A", "B" }`). Comments inside the block are ignored.
function Guard.parseModules(source: string): { [string]: boolean }?
	local body = string.match(source, "modules%s*=%s*(%b{})")
	if body == nil then
		return nil
	end
	local set = {}
	for line in string.gmatch(body, "[^\n]+") do
		local code = string.gsub(line, "%-%-.*$", "")
		-- core-v1.3.1 refs: require(Modules:WaitForChild("Items"):WaitForChild("module"))
		local ref = string.match(code, 'WaitForChild%("([%w_]+)"%):WaitForChild%("module"%)%)')
			or string.match(code, 'WaitForChild%("([%w_]+)"%)%)')
		if ref then
			set[ref] = true
		else
			for name in string.gmatch(code, '"([%w_]+)"') do
				set[name] = true
			end
		end
	end
	return set
end

local function stripComment(line: string): string
	-- good enough for game code: drop `--` comments that aren't inside a string
	local out = {}
	local quote: string? = nil
	local i = 1
	while i <= #line do
		local c = string.sub(line, i, i)
		if quote then
			if c == "\\" then
				table.insert(out, string.sub(line, i, i + 1))
				i += 2
				continue
			elseif c == quote then
				quote = nil
			end
			table.insert(out, c)
		elseif c == '"' or c == "'" or c == "`" then
			quote = c
			table.insert(out, c)
		elseif c == "-" and string.sub(line, i + 1, i + 1) == "-" then
			break
		else
			table.insert(out, c)
		end
		i += 1
	end
	return table.concat(out)
end

local function allowed(line: string, check: string): boolean
	return string.find(line, "%-%-%s*guard:%s*allow[%w%s,]*" .. check) ~= nil
end

local BALANCE_CALL = {
	"Economy%.grant%s*%(",
	"Economy%.spend%s*%(",
	"Economy%.addIncomeSource%s*%(",
	"Economy%.addMultiplier%s*%(",
	"Rarity%.roll%s*%(",
	"Rarity%.setLuck%s*%(",
	"tx%.grant%s*%(",
	"tx%.roll%s*%(",
}

local BALANCE_NAMES = {
	"cost",
	"price",
	"reward",
	"income",
	"payout",
	"mult",
	"luck",
	"chance",
	"weight",
	"amount",
	"bonus",
	"xp",
	"coins",
	"gems",
	"cash",
	"damage",
	"health",
	"odds",
}

-- words of an identifier: fooBarBaz / foo_bar -> { "foo", "bar", "baz" }
local function words(name: string): { string }
	local spaced = string.gsub(name, "(%u)", " %1")
	local out = {}
	for w in string.gmatch(string.lower(spaced), "[%l%d]+") do
		table.insert(out, w)
	end
	return out
end

local function hasBigNumber(text: string): boolean
	for num in string.gmatch(text, "[^%w_%.](%d[%w%.]*)") do -- 250, 2.5, 1e3, 0xFF (review R14)
		local n = tonumber(num)
		if n and n >= 2 then
			return true
		end
	end
	return false
end

local function balanceAssignment(code: string): boolean
	-- `local fooCost = 50`, `cost = 50,`, `self.rewardAmount = 2.5`
	for name, value in string.gmatch(code, "([%a_][%w_]*)%s*=%s*%-?(%d[%w%.]*)") do
		local n = tonumber(value)
		if n and n >= 2 then
			for _, w in words(name) do
				for _, key in BALANCE_NAMES do
					if string.sub(w, 1, #key) == key then -- "mult" matches "multiplier"
						return true
					end
				end
			end
		end
	end
	return false
end

-- v1.3.0: the remotes and purchases checks run on a NORMALISED copy
-- of the whole file, so layout can't hide a call: comments stripped, all whitespace and newlines
-- removed (an assignment split across lines is one expression), adjacent string literals joined
-- (`"Data" .. "StoreService"` -> `"DataStoreService"`), and `x["Name"]` read as `x.Name`. Each
-- character keeps its source line for the finding (and `-- guard: allow <check>` on that line).
function Guard.normalize(codeLines: { string }): (string, { number })
	-- tokens: { kind = "str" | "ch", val, line }
	local tokens = {}
	for lineNo, code in codeLines do
		local i = 1
		while i <= #code do
			local c = string.sub(code, i, i)
			if c == '"' or c == "'" or c == "`" then
				local j = i + 1
				local buf = {}
				while j <= #code do
					local d = string.sub(code, j, j)
					if d == "\\" then
						table.insert(buf, string.sub(code, j + 1, j + 1))
						j += 2
						continue
					elseif d == c then
						break
					end
					table.insert(buf, d)
					j += 1
				end
				table.insert(tokens, { kind = "str", val = table.concat(buf), line = lineNo })
				i = j + 1
			elseif string.match(c, "%s") then
				i += 1
			else
				table.insert(tokens, { kind = "ch", val = c, line = lineNo })
				i += 1
			end
		end
	end
	-- join "a" .. "b" (repeatedly)
	local folded = {}
	local k = 1
	while k <= #tokens do
		local t = tokens[k]
		if t.kind == "str" then
			local val = t.val
			while
				tokens[k + 1]
				and tokens[k + 1].val == "."
				and tokens[k + 2]
				and tokens[k + 2].val == "."
				and tokens[k + 3]
				and tokens[k + 3].kind == "str"
			do
				val ..= tokens[k + 3].val
				k += 3
			end
			table.insert(folded, { kind = "str", val = val, line = t.line })
		else
			table.insert(folded, t)
		end
		k += 1
	end
	-- emit, reading ["Name"] as .Name
	local chars, lines = {}, {}
	local function emit(text: string, line: number)
		for n = 1, #text do
			table.insert(chars, string.sub(text, n, n))
			table.insert(lines, line)
		end
	end
	k = 1
	while k <= #folded do
		local t = folded[k]
		local nextT, after = folded[k + 1], folded[k + 2]
		if
			t.val == "["
			and t.kind == "ch"
			and nextT
			and nextT.kind == "str"
			and string.match(nextT.val, "^[%a_][%w_]*$")
			and after
			and after.kind == "ch"
			and after.val == "]"
		then
			emit("." .. nextT.val, t.line)
			k += 3
		elseif t.kind == "str" then
			emit('"' .. t.val .. '"', t.line)
			k += 1
		else
			emit(t.val, t.line)
			k += 1
		end
	end
	return table.concat(chars), lines
end

-- (pattern, check, message, plain?) checked on the normalised file.
local NORMALIZED_RULES = {
	{
		"ProcessReceipt=[^=]",
		"purchases",
		"only the framework Shop assigns MarketplaceService.ProcessReceipt: use ctx.shop.onProduct",
	},
	{
		"ProcessReceipt=$",
		"purchases",
		"only the framework Shop assigns MarketplaceService.ProcessReceipt: use ctx.shop.onProduct",
	},
	{
		'"ProcessReceipt"',
		"purchases",
		"only the framework Shop assigns MarketplaceService.ProcessReceipt: use ctx.shop.onProduct",
		true,
	},
	{
		"Prompt%a*PurchaseFinished",
		"purchases",
		"Prompt*PurchaseFinished belongs to the framework Shop: use ctx.shop.onPassOwned / onProduct",
	},
	{
		"DataStoreService",
		"purchases",
		"DataStoreService / ProfileStore only inside framework Data: use ctx.data (shared state: ctx.data.shared)",
		true,
	},
	{
		"ProfileStore",
		"purchases",
		"DataStoreService / ProfileStore only inside framework Data: use ctx.data (shared state: ctx.data.shared)",
		true,
	},
	{
		"MemoryStoreService",
		"purchases",
		"MemoryStoreService only inside the framework: use ctx.data.shared",
		true,
	},
	{ "OnServerEvent", "remotes", "raw remote handler: route game remotes through Core.Net.handle", true },
	{ "OnServerInvoke", "remotes", "raw remote handler: route game remotes through Core.Net.handle", true },
	{
		"RemoteEvent",
		"remotes",
		"RemoteEvent/RemoteFunction in game code: define remotes in game.blink",
		true,
	},
	{
		"RemoteFunction",
		"remotes",
		"RemoteEvent/RemoteFunction in game code: define remotes in game.blink",
		true,
	},
	{ '"OnServer', "remotes", "RemoteEvent/RemoteFunction in game code: define remotes in game.blink", true },
}

function Guard.normalizedFindings(codeLines: { string }, rawLines: { string }, ctx): { any }
	local norm, lines = Guard.normalize(codeLines)
	local out = {}
	local seen = {}
	local function hit(pos: number, check: string, message: string)
		local line = lines[pos] or lines[#lines] or 1
		if ctx.onlyPurchases and check ~= "purchases" then
			return
		end
		if allowed(rawLines[line] or "", check) then
			return
		end
		local key = `{line}|{check}|{message}`
		if not seen[key] then
			seen[key] = true
			table.insert(out, { line = line, check = check, message = message })
		end
	end
	for _, rule in NORMALIZED_RULES do
		local init = 1
		while true do
			local s, e = string.find(norm, rule[1], init, rule[4] == true)
			if s == nil then
				break
			end
			hit(s, rule[2], rule[3])
			init = (e or s) + 1
		end
	end
	-- GetService / Instance.new need a single literal name (a computed name can be anything)
	for pos, arg in string.gmatch(norm, "()GetService%(([^%)]*)%)") do
		if not string.match(arg, '^"[%w_]*"$') then
			hit(pos, "purchases", "GetService with a computed service name: use a string literal")
		end
	end
	for pos in string.gmatch(norm, "Instance%.new%(()") do
		if not string.match(string.sub(norm, pos), '^"[^"]*"[,%)]') then
			hit(pos, "remotes", "Instance.new with a dynamic class name: use a string literal")
		end
	end
	-- Blink listeners anywhere outside client code: shared modules run on the server too
	if not ctx.isClient then
		for _, pattern in { "()%.On%(", "()%.SetCallback%(" } do
			for pos in string.gmatch(norm, pattern) do
				hit(
					pos,
					"remotes",
					"Blink listener outside client code: use Core.Net.handle(name, event, limit, fn)"
				)
			end
		end
	end
	return out
end

-- Scans one file's source. `ctx = { path, modules (set or nil), isServer, isClient, inConfig }`.
function Guard.scanSource(source: string, ctx): { string }
	local findings = {}
	local function add(lineNo: number, check: string, message: string)
		table.insert(findings, `{ctx.path}:{lineNo}: [{check}] {message}`)
	end
	local codeLines, rawLines = {}, {}
	local lineNo = 0
	local inBlock = false
	for raw in string.gmatch(source .. "\n", "([^\n]*)\n") do
		lineNo += 1
		local text = raw
		if inBlock then
			local close = string.find(text, "]]", 1, true)
			if close == nil then
				table.insert(codeLines, "")
				table.insert(rawLines, raw)
				continue
			end
			inBlock = false
			text = string.sub(text, close + 2)
		end
		local open = string.find(text, "--[[", 1, true) or string.find(text, "--[=[", 1, true)
		if open then
			local close = string.find(text, "]]", open + 4, true)
			if close == nil then
				inBlock = true
				text = string.sub(text, 1, open - 1)
			else
				text = string.sub(text, 1, open - 1) .. string.sub(text, close + 2)
			end
		end
		local code = stripComment(text)
		table.insert(codeLines, code)
		table.insert(rawLines, raw)
		if ctx.onlyPurchases then
			continue
		end

		-- modules
		if ctx.modules and not allowed(raw, "modules") then
			for ns in string.gmatch(code, "Core%.(%u[%w_]*)%s*[%.:]") do
				if MODULE_SET[ns] and not ctx.modules[ns] then
					add(lineNo, "modules", `Core.{ns} is used but "{ns}" is not in GameConfig.modules`)
				end
			end
			-- v1.3: a kit module ref required in game code (`require(Economy:WaitForChild("Rebirth"))`
			-- for ctx.deps / StudWork.use / dependsOn) must be enabled. Config/ itself is the list.
			if not ctx.inConfig then
				local refs = {}
				for ref in string.gmatch(code, 'require%([%w_]+:WaitForChild%("([%w_]+)"%)%)') do
					table.insert(refs, ref)
				end
				-- core-v1.3.1: require(Modules:WaitForChild("Rebirth"):WaitForChild("module"))
				for ref in string.gmatch(code, 'WaitForChild%("([%w_]+)"%)%s*:%s*WaitForChild%("module"%)') do
					table.insert(refs, ref)
				end
				for _, ref in refs do
					if MODULE_SET[ref] and not ctx.modules[ref] then
						add(
							lineNo,
							"modules",
							`module {ref} is used but "{ref}" is not in GameConfig.modules`
						)
					end
				end
			end
			for action in string.gmatch(code, "Actions%.([%a_][%w_]*)%s*%(") do
				local owner = Modules.ACTIONS[action]
				if owner and not ctx.modules[owner] then
					add(
						lineNo,
						"modules",
						`Actions.{action} needs module "{owner}", which is not in GameConfig.modules`
					)
				end
			end
		end
		if
			not allowed(raw, "modules")
			and (
				string.find(code, "CoreServer")
				or string.find(code, "CoreClient")
				or string.find(code, "FrameworkClient")
			)
		then
			add(
				lineNo,
				"modules",
				"game code must use the StudWork facade, not CoreServer/CoreClient/FrameworkClient internals"
			)
		end
		if
			not allowed(raw, "modules")
			and (string.find(code, 'Child%(%s*"Kits"') or string.find(code, "Child%(%s*'Kits'") or string.find(
				code,
				"%.Kits[%.:]"
			))
			-- v1.3.0: ReplicatedStorage.Kits.<Kit>.<Module> are the kits' module
			-- DEFINITIONS (ModuleRefs), which a game lists in GameConfig.modules and passes to
			-- StudWork.use / dependsOn (module-api.md §3). Only the server internals are off limits.
			and not string.find(code, "ReplicatedStorage")
		then
			-- v1.3.0: the v1.2 services now live in ServerScriptService.Kits.<Kit>
			add(
				lineNo,
				"modules",
				"game code must use the Core facade, not the kits' service internals (Kits)"
			)
		end

		-- remotes and purchases: checked on the whole normalised file below (normalizedFindings)

		-- numbers (outside Config)
		if not ctx.inConfig and not allowed(raw, "numbers") then
			local flagged = false
			for _, pattern in BALANCE_CALL do
				local s = string.find(code, pattern)
				if s and hasBigNumber(string.sub(code, s)) then
					flagged = true
				end
			end
			if flagged or balanceAssignment(code) then
				add(
					lineNo,
					"numbers",
					"balance number in game code: move it to src/shared/Config (Balance.luau)"
				)
			end
		end
	end
	for _, f in Guard.normalizedFindings(codeLines, rawLines, ctx) do
		add(f.line, f.check, f.message)
	end
	return findings
end

-- v1.3.0: which files the guardrails scan. Every `.luau` / `.lua`
-- file Rojo would sync is scanned; specs (`*.spec.luau`, glob-ignored by every project) are not.
-- The only exclusions are by EXACT path: the Wally dependency folders (Guard.DEPS_EXCLUDED) and
-- the Blink output files the `.blink` IDL files declare (Guard.generatedFiles). No substring
-- ("Generated"), extension (".lua") or folder-name ("Packages") exclusions: those shipped files.
Guard.DEPS_EXCLUDED = { "deps/Packages", "deps/ServerPackages", "deps/DevPackages" }

local function normalizePath(path: string): string
	local parts = {}
	for _, part in string.split(path, "/") do
		if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
			table.remove(parts)
		elseif part ~= "." and part ~= "" then
			table.insert(parts, part)
		end
	end
	return table.concat(parts, "/")
end

-- The Blink outputs one `.blink` source declares (ServerOutput / ClientOutput / TypesOutput),
-- resolved against the blink file's folder. Pure (testable).
function Guard.blinkOutputs(blinkPath: string, source: string): { string }
	local dir = string.match(blinkPath, "^(.*)/[^/]+$") or "."
	local out = {}
	for _, key in { "ServerOutput", "ClientOutput", "TypesOutput" } do
		local rel = string.match(source, "option%s+" .. key .. '%s*=%s*"([^"]+)"')
		if rel then
			table.insert(out, normalizePath(dir .. "/" .. rel))
		end
	end
	return out
end

local function findBlink(dir: string, out: { string })
	if not fs.isDir(dir) then
		return
	end
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			if not table.find(Guard.DEPS_EXCLUDED, normalizePath(path)) then
				findBlink(path, out)
			end
		elseif string.match(entry, "%.blink$") then
			table.insert(out, path)
		end
	end
end

local generatedCache: { [string]: boolean }? = nil
-- Set of the exact generated (Blink output) file paths in the repo.
function Guard.generatedFiles(): { [string]: boolean }
	if generatedCache then
		return generatedCache
	end
	local set = {}
	local blinks = {}
	for _, root in { "packages", "games", "templates", "examples" } do
		findBlink(root, blinks)
	end
	for _, b in blinks do
		for _, f in Guard.blinkOutputs(b, fs.readFile(b)) do
			set[f] = true
		end
	end
	generatedCache = set
	return set
end

-- Whether a file found under a scan root is scanned. Pure (testable): `generated` is the set of
-- exact Blink output paths.
function Guard.isScannedFile(path: string, generated: { [string]: boolean }): boolean
	local norm = normalizePath(path)
	if not (string.match(norm, "%.luau$") or string.match(norm, "%.lua$")) then
		return false
	end
	if string.match(norm, "%.spec%.luau$") or string.match(norm, "%.spec%.lua$") then
		return false
	end
	if generated[norm] then
		return false
	end
	for _, dep in Guard.DEPS_EXCLUDED do
		if string.sub(norm, 1, #dep + 1) == dep .. "/" then
			return false
		end
	end
	return true
end

local function walk(dir: string, out: { string })
	if not fs.isDir(dir) then
		return
	end
	local generated = Guard.generatedFiles()
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			if not table.find(Guard.DEPS_EXCLUDED, normalizePath(path)) then
				walk(path, out)
			end
		elseif Guard.isScannedFile(path, generated) then
			table.insert(out, path)
		end
	end
end

-- A path's folder segments (relative to a game folder): client / server code is classified by an
-- exact `client` / `server` folder segment, never by a substring (`server/netclient/` is server).
function Guard.hasSegment(rel: string, segment: string): boolean
	local parts = string.split(rel, "/")
	for i = 1, #parts - 1 do
		if parts[i] == segment then
			return true
		end
	end
	return false
end

-- Scans a game folder (games/<name> or templates/new-game).
function Guard.scanGame(dir: string): { string }
	local findings = {}
	local configPaths = { dir .. "/src/shared/Config/init.luau", dir .. "/src/shared/Config.luau" }
	local modules = nil
	for _, p in configPaths do
		if fs.isFile(p) then
			modules = Guard.parseModules(fs.readFile(p))
			break
		end
	end
	if modules == nil then
		table.insert(findings, `{dir}: [modules] can't read GameConfig.modules from src/shared/Config`)
	end
	local files = {}
	walk(dir, files)
	table.sort(files)
	for _, path in files do
		-- extra projects (e.g. examples/sandbox/foundation-only/) carry their own Config.luau
		local sub = string.match(path, "^" .. dir:gsub("%p", "%%%0") .. "/([^/]+)/")
		local mods = modules
		if sub and sub ~= "src" then
			local extra = dir .. "/" .. sub .. "/shared/Config.luau"
			if fs.isFile(extra) then
				mods = Guard.parseModules(fs.readFile(extra))
			end
		end
		local rel = string.sub(path, #dir + 2)
		local inConfig = string.find(rel, "/shared/Config/", 1, true) ~= nil
			or string.match(rel, "/shared/Config%.luau$") ~= nil
		local isServer = Guard.hasSegment(rel, "server")
		local isClient = Guard.hasSegment(rel, "client") and not isServer
		do -- generated files never reach here (walk excludes them by exact path)
			for _, f in
				Guard.scanSource(fs.readFile(path), {
					path = path,
					modules = mods,
					isServer = isServer,
					isClient = isClient,
					inConfig = inConfig,
				})
			do
				table.insert(findings, f)
			end
		end
	end
	return findings
end

-- The purchases check over packages/ (everything outside Guard.PURCHASES_ALLOWED).
function Guard.isPurchasesAllowed(path: string): boolean
	for _, prefix in Guard.PURCHASES_ALLOWED do
		if string.sub(path, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

function Guard.scanPackages(root: string): { string }
	local findings = {}
	local files = {}
	walk(root, files)
	table.sort(files)
	for _, path in files do
		if not Guard.isPurchasesAllowed(path) then
			for _, f in Guard.scanSource(fs.readFile(path), { path = path, onlyPurchases = true }) do
				table.insert(findings, f)
			end
		end
	end
	return findings
end

--------------------------------------------------------------------------------
-- special: "nothing is special" (v1.3.0). Kits, examples and game modules use only
-- the public StudWork facade, UI and module refs, like a third-party module would.
--------------------------------------------------------------------------------

-- Folders the check covers (relative to the repo root); specs and tests/ folders are skipped
-- (tests may use StudWork.test and the harness).
Guard.SPECIAL_ROOTS = {
	"packages/kits",
	"examples/modules",
	"games/*/modules",
	"examples/*/modules", -- example games (examples/sandbox)
	"examples/overrides/*/modules",
}

-- Internal names a module may never mention as a child (any path, any receiver).
local INTERNAL_NAMES = { "RuntimeSlot", "CompatDoor", "FrameworkClient", "FrameworkTest" }

local KIT_FOLDERS = {
	collection = "Collection",
	economy = "Economy",
	base = "Base",
	social = "Social",
	engagement = "Engagement",
}

-- "a" .. "b" -> "ab" (repeatedly), so a name split into literals is still seen whole.
local function foldConcat(code: string): string
	local prev = nil
	while prev ~= code do
		prev = code
		code = string.gsub(code, '"([^"]*)"%s*%.%.%s*"([^"]*)"', '"%1%2"')
		code = string.gsub(code, "'([^']*)'%s*%.%.%s*'([^']*)'", "'%1%2'")
	end
	return code
end

local function escape(name: string): string
	return (string.gsub(name, "%p", "%%%0"))
end

-- Child access right after position `i` of `code`: :WaitForChild("x") / :FindFirstChild("x") /
-- .x / ["x"]. Returns (kind, name?) or nil. kind "dynamic" = a non-literal child name.
local function childAfter(code: string, i: number): (string?, string?)
	local rest = string.sub(code, i)
	local lit = string.match(rest, "^%s*:%s*Wait%a*Child%s*%(%s*[\"']([^\"']*)[\"']")
		or string.match(rest, "^%s*:%s*Find%a*Child%a*%s*%(%s*[\"']([^\"']*)[\"']")
		or string.match(rest, "^%s*%[%s*[\"']([^\"']*)[\"']%s*%]")
	if lit then
		return "child", lit
	end
	if
		string.match(rest, "^%s*:%s*Wait%a*Child%s*%(") or string.match(rest, "^%s*:%s*Find%a*Child%a*%s*%(")
	then
		return "dynamic", nil
	end
	if string.match(rest, "^%s*%[") then
		return "dynamic", nil
	end
	-- enumerating the children finds the internals by name at run time
	if string.match(rest, "^%s*:%s*Get[CD]%a+%s*%(") then
		return "dynamic", nil
	end
	local dot = string.match(rest, "^%.([%a_][%w_]*)")
	if dot then
		return "child", dot
	end
	return nil, nil
end

-- Positions just after every reference to a child named `name` (`:WaitForChild("name")`,
-- `:FindFirstChild("name")`, `.name`, `["name"]`) in code.
local function childRefs(code: string, name: string): { number }
	local out = {}
	local e = escape(name)
	for _, pattern in
		{
			":%s*Wait%a*Child%s*%(%s*[\"']" .. e .. "[\"']%s*%)()",
			":%s*Find%a*Child%a*%s*%(%s*[\"']" .. e .. "[\"']%s*%)()",
			"%[%s*[\"']" .. e .. "[\"']%s*%]()",
			"%." .. e .. "()%f[^%w_]",
		}
	do
		for pos in string.gmatch(code, pattern) do
			table.insert(out, pos)
		end
	end
	return out
end

-- Scans one module file. ctx = { path, kit? (own kit folder name, e.g. "Economy"), module? (own
-- module folder, e.g. "Upgrades": packages/kits/<kit>/<Module>/) }.
function Guard.scanSpecial(source: string, ctx: any): { string }
	local findings = {}
	local function add(lineNo: number, message: string)
		table.insert(findings, `{ctx.path}:{lineNo}: [special] {message}`)
	end
	-- aliases: variables holding ServerScriptService, ReplicatedStorage.Framework (unrequired),
	-- ServerScriptService.Kits, or another alias
	local sss = { ServerScriptService = true }
	local fw = {}
	local kits = {}
	local mods = {}
	local lineNo = 0
	local inBlock = false
	for raw in string.gmatch(source .. "\n", "([^\n]*)\n") do
		lineNo += 1
		local text = raw
		if inBlock then
			local close = string.find(text, "]]", 1, true)
			if close == nil then
				continue
			end
			inBlock = false
			text = string.sub(text, close + 2)
		end
		local open = string.find(text, "--[[", 1, true) or string.find(text, "--[=[", 1, true)
		if open then
			local close = string.find(text, "]]", open + 4, true)
			if close == nil then
				inBlock = true
				text = string.sub(text, 1, open - 1)
			else
				text = string.sub(text, 1, open - 1) .. string.sub(text, close + 2)
			end
		end
		if allowed(raw, "special") then
			continue
		end
		local code = foldConcat(stripComment(text))
		local flagged: string? = nil
		local function flag(message: string)
			flagged = flagged or message
		end

		-- 1. internal names anywhere (as a child or a string)
		for _, name in INTERNAL_NAMES do
			if string.find(code, "[\"']" .. name .. "[\"']") or #childRefs(code, name) > 0 then
				flag(`{name} is a framework internal: use the StudWork facade (StudWork.use / ctx)`)
			end
		end

		-- track aliases assigned on this line: local X = <expr>
		local lhs, rhs = string.match(code, "^%s*local%s+([%a_][%w_]*)%s*[:=][^=]*=%s*(.+)$")
		if lhs == nil then
			lhs, rhs = string.match(code, "^%s*local%s+([%a_][%w_]*)%s*=%s*(.+)$")
		end
		if lhs == nil then
			lhs, rhs = string.match(code, "^%s*([%a_][%w_]*)%s*=%s*(.+)$")
		end

		-- 2. receivers: ServerScriptService (GetService or alias) and Framework (unrequired)
		local function isSSS(expr: string): boolean
			if string.find(expr, "GetService%s*%(%s*[\"']ServerScriptService[\"']%s*%)") then
				return true
			end
			for name in sss do
				if string.find(expr, "%f[%w_]" .. escape(name) .. "%f[^%w_]") then
					return true
				end
			end
			return false
		end
		-- ServerScriptService.Framework / ServerScriptService.Kits.<other kit>
		if isSSS(code) then
			for _, pos in childRefs(code, "Framework") do
				local _ = pos
				flag("ServerScriptService.Framework is the framework's server runtime (internal)")
			end
			for _, pos in childRefs(code, "Kits") do
				local kind, name = childAfter(code, pos)
				if kind == "dynamic" then
					flag("dynamic child name under ServerScriptService.Kits: name the kit literally")
				elseif kind == "child" and name ~= ctx.kit then
					flag(
						`ServerScriptService.Kits.{name}: another kit's server internals (use its module ref)`
					)
				elseif kind == nil and ctx.kit == nil then
					flag("ServerScriptService.Kits: kit server internals (use module refs)")
				end
			end
			-- core-v1.3.1 (R19): ServerScriptService.Modules.<Other> is another module's server part
			for _, pos in childRefs(code, "Modules") do
				local kind, name = childAfter(code, pos)
				if kind == "dynamic" then
					flag("dynamic child name under ServerScriptService.Modules: name the module literally")
				elseif kind == "child" and name ~= ctx.module then
					flag(
						`ServerScriptService.Modules.{name}: another module's server internals (use its module ref, ReplicatedStorage.Modules.{name}.module)`
					)
				end
			end
			-- a dynamic child of ServerScriptService itself (evasion of the names above)
			local receivers = { "GetService%s*%(%s*[\"']ServerScriptService[\"']%s*%)()" }
			for name in sss do
				table.insert(receivers, "%f[%w_]" .. escape(name) .. "()%f[^%w_]")
			end
			for _, pattern in receivers do
				for pos in string.gmatch(code, pattern) do
					if childAfter(code, pos) == "dynamic" then
						flag("dynamic child name under ServerScriptService: name the child literally")
					end
				end
			end
		end
		-- Framework chains: a child of ReplicatedStorage.Framework other than the facade itself
		for _, pos in childRefs(code, "Framework") do
			local kind, name = childAfter(code, pos)
			if kind ~= nil then
				flag(
					`Framework.{name or "<dynamic>"} is a framework internal: require the StudWork facade only`
				)
			end
		end
		-- aliases of Framework / SSS / Kits used with a child
		for name in fw do
			for pos in string.gmatch(code, "%f[%w_]" .. escape(name) .. "()%f[^%w_]") do
				local kind, child = childAfter(code, pos)
				if kind ~= nil then
					flag(`{name} (= Framework) .{child or "<dynamic>"}: framework internal`)
				end
			end
		end
		for name in mods do
			for pos in string.gmatch(code, "%f[%w_]" .. escape(name) .. "()%f[^%w_]") do
				local kind, child = childAfter(code, pos)
				if kind == "dynamic" or (kind == "child" and child ~= ctx.module) then
					flag(
						`{name} (= ServerScriptService.Modules) .{child or "<dynamic>"}: another module's server internals`
					)
				end
			end
		end
		for name in kits do
			for pos in string.gmatch(code, "%f[%w_]" .. escape(name) .. "()%f[^%w_]") do
				local kind, child = childAfter(code, pos)
				if kind == "dynamic" or (kind == "child" and child ~= ctx.kit) then
					flag(
						`{name} (= ServerScriptService.Kits) .{child or "<dynamic>"}: another kit's server internals`
					)
				end
			end
		end
		-- 3. script.Parent climbing into the framework (or out of the kit to packages/)
		if
			string.find(code, "script%.Parent[%w_%.:%(%)\"']-[%.\"'][Ff]ramework")
			or string.find(code, "FindFirstAncestor%s*%(")
		then
			flag("script.Parent / FindFirstAncestor climbing into the framework: require the StudWork facade")
		end

		-- remember aliases defined on this line (after the checks: `local F = RS.Framework` is fine
		-- on its own; using F's children is not)
		if lhs and rhs and not string.find(rhs, "^%s*require") then
			if isSSS(rhs) and not string.find(rhs, "Child") and not string.find(rhs, "%.[%a_]") then
				sss[lhs] = true
			end
			local fwPositions = childRefs(rhs, "Framework")
			if #fwPositions > 0 then
				fw[lhs] = true
			end
			for name in fw do
				if rhs == name or string.match(rhs, "^" .. escape(name) .. "%s*$") then
					fw[lhs] = true
				end
			end
			if #childRefs(rhs, "Kits") > 0 and isSSS(rhs) then
				kits[lhs] = true
			end
			if #childRefs(rhs, "Modules") > 0 and isSSS(rhs) then
				local _, child = childAfter(rhs, childRefs(rhs, "Modules")[1])
				if child == nil then
					mods[lhs] = true
				end
			end
			for name in sss do
				if string.match(rhs, "^" .. escape(name) .. "%s*$") then
					sss[lhs] = true
				end
			end
		end

		if flagged then
			add(lineNo, flagged :: string)
		end
	end
	return findings
end

-- theme (D's R4): literal colours / asset ids in UI and client code outside theme/config files.
Guard.THEME_ROOTS = {
	"packages/ui",
	"packages/kits/*/client",
	"examples/modules/*/client",
	"games/*/modules/*/client",
	"games/*/src/client",
	"examples/*/modules/*/client", -- example games (examples/sandbox, examples/overrides/<g>)
	"examples/*/src/client",
	"examples/overrides/*/modules/*/client",
	"examples/overrides/*/src/client",
}
-- Theme and config files may hold literals (the palette, tier colours, sound/asset ids).
function Guard.isThemeAllowed(path: string): boolean
	local base = string.match(path, "([^/]+)$") or path
	return string.find(base, "Theme", 1, true) ~= nil
		or string.find(base, "Palette", 1, true) ~= nil
		or string.find(path, "/Config/", 1, true) ~= nil
		or string.match(base, "^Config%.luau$") ~= nil
end

function Guard.scanTheme(source: string, ctx: any): { string }
	local findings = {}
	local lineNo = 0
	for raw in string.gmatch(source .. "\n", "([^\n]*)\n") do
		lineNo += 1
		if allowed(raw, "theme") then
			continue
		end
		local code = stripComment(raw)
		local why = nil
		if
			string.find(code, "[\"'`]#%x%x%x%x%x%x%x?%x?[\"'`]") or string.find(code, "[\"'`]#%x%x%x[\"'`]")
		then
			why = "hex colour literal: use a theme colour token (ThemeTokens / StudWork theme)"
		elseif string.find(code, "fromHex%s*%(%s*[\"']") then
			why = "Color3.fromHex literal: use a theme colour token"
		elseif string.find(code, "fromRGB%s*%(%s*%d") then
			why = "Color3.fromRGB literal: use a theme colour token"
		elseif string.find(code, "rbxassetid://%d") or string.find(code, "rbxasset://") then
			why = "asset id literal: put it in the theme (or a config file) and read it from there"
		end
		if why then
			table.insert(findings, `{ctx.path}:{lineNo}: [theme] {why}`)
		end
	end
	return findings
end

-- Expands "a/*/b" against the file system (one * per segment).
local function expand(pattern: string): { string }
	local parts = string.split(pattern, "/")
	local out = { "" }
	for _, part in parts do
		local nextOut = {}
		for _, base in out do
			local prefix = if base == "" then "" else base .. "/"
			if part == "*" then
				if base ~= "" and fs.isDir(base) then
					for _, entry in fs.readDir(base) do
						if fs.isDir(prefix .. entry) then
							table.insert(nextOut, prefix .. entry)
						end
					end
				end
			else
				table.insert(nextOut, prefix .. part)
			end
		end
		out = nextOut
	end
	local dirs = {}
	for _, d in out do
		if fs.isDir(d) then
			table.insert(dirs, d)
		end
	end
	table.sort(dirs)
	return dirs
end

local function moduleFiles(roots: { string }): { string }
	local files = {}
	for _, pattern in roots do
		for _, dir in expand(pattern) do
			local found = {}
			walk(dir, found)
			for _, f in found do
				-- kits' and examples' tests/ folders are not synced by any project (only shared/,
				-- server/, client/ are); games/*/modules sync only module.luau + server/.
				if
					not string.match(f, "^packages/kits/[^/]+/tests/")
					and not string.match(f, "^examples/.-/tests/")
				then
					table.insert(files, f)
				end
			end
		end
	end
	table.sort(files)
	return files
end

function Guard.scanSpecialAll(): { string }
	local findings = {}
	for _, path in moduleFiles(Guard.SPECIAL_ROOTS) do
		local kitFolder, moduleFolder = string.match(path, "^packages/kits/([^/]+)/([^/]+)/")
		local ctx = {
			path = path,
			kit = if kitFolder then KIT_FOLDERS[kitFolder] else nil,
			module = moduleFolder,
		}
		for _, f in Guard.scanSpecial(fs.readFile(path), ctx) do
			table.insert(findings, f)
		end
	end
	for _, path in moduleFiles(Guard.THEME_ROOTS) do
		if not Guard.isThemeAllowed(path) then
			for _, f in Guard.scanTheme(fs.readFile(path), { path = path }) do
				table.insert(findings, f)
			end
		end
	end
	return findings
end

--------------------------------------------------------------------------------
-- special, framework half (core-v1.3.1 R19, "nothing is special, for real"): the framework knows no
-- kit. Framework code (packages/framework/{shared,server,client}/**, not test/, not specs, not the
-- generated Blink outputs) and the framework's own Blink file may not name a kit module (a whole
-- word, case-sensitive: every `name = "..."` of packages/kits/*/*/module.luau), an event a kit
-- declares in its own net.blink, or the pre-v1.3.1 kit loader names. Read on the comment-stripped
-- code AND on the normalised text (Guard.normalize: whitespace removed, "a" .. "b" folded, x["N"]
-- read as x.N), so string literals, field access, indexing and concatenation are all seen.
--------------------------------------------------------------------------------

Guard.FRAMEWORK_SPECIAL_ROOTS =
	{ "packages/framework/shared", "packages/framework/server", "packages/framework/client" }
Guard.FRAMEWORK_BLINK = "packages/framework/shared/net/framework.blink"

-- The pre-v1.3.1 kit layout's names: never in framework code.
Guard.FRAMEWORK_FIXED_NAMES = { "Kits", "ModuleServers", "ModuleClients", "kitLoadServer" }

-- The kit request events that lived in framework.blink before R19 (v1.2 -> v1.3.0).
Guard.KIT_V12_EVENTS = {
	"RequestDisplay",
	"RequestClearDisplay",
	"RequestRebirth",
	"RequestUpgrade",
	"RequestRoll",
	"RequestGift",
	"RequestMailClaim",
}

-- The names the scan flags: { [name] = reason }. Pure: `kitModules` = kit module names,
-- `kitEvents` = Blink event names declared in kit net.blink files.
function Guard.frameworkSpecialNames(kitModules: { string }, kitEvents: { string }): { [string]: string }
	local names = {}
	for _, n in kitModules do
		names[n] = `kit module '{n}'`
	end
	for _, n in kitEvents do
		names[n] = names[n] or `kit event '{n}' (declared in a kit net.blink)`
	end
	for _, n in Guard.KIT_V12_EVENTS do
		names[n] = names[n] or `kit request event '{n}' (belongs in the kit module's own net.blink)`
	end
	for _, n in Guard.FRAMEWORK_FIXED_NAMES do
		names[n] = `pre-v1.3.1 kit layout name '{n}'`
	end
	return names
end

-- Blink event names in a .blink source (`event Name {`), comments ignored.
function Guard.blinkEvents(source: string): { string }
	local out = {}
	for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
		local code = string.gsub(line, "%-%-.*$", "")
		local name = string.match(code, "^%s*event%s+([%a_][%w_]*)")
		if name then
			table.insert(out, name)
		end
	end
	return out
end

-- Kit module names and kit net.blink events from the repo (ModuleDiscovery).
function Guard.kitNamesOnDisk(): ({ string }, { string })
	local ModuleDiscovery = require("./ModuleDiscovery")
	local modules, events = {}, {}
	for _, entry in ModuleDiscovery.discover(fs, require("./Roots").CORE) do
		if entry.kit ~= nil then
			table.insert(modules, entry.name)
			if entry.blink then
				for _, e in Guard.blinkEvents(fs.readFile(entry.blink)) do
					table.insert(events, e)
				end
			end
		end
	end
	return modules, events
end

-- Comment-stripped lines of a Luau (or, with isBlink, a Blink) source; line numbers kept.
local function codeLinesOf(source: string, isBlink: boolean?): ({ string }, { string })
	local codeLines, rawLines = {}, {}
	local inBlock = false
	for raw in string.gmatch(source .. "\n", "([^\n]*)\n") do
		local text = raw
		if isBlink then
			text = string.gsub(text, "%-%-.*$", "")
		else
			if inBlock then
				local close = string.find(text, "]]", 1, true)
				if close == nil then
					text = ""
				else
					inBlock = false
					text = string.sub(text, close + 2)
				end
			end
			local open = string.find(text, "--[[", 1, true) or string.find(text, "--[=[", 1, true)
			if open then
				local close = string.find(text, "]]", open + 4, true)
				if close == nil then
					inBlock = true
					text = string.sub(text, 1, open - 1)
				else
					text = string.sub(text, 1, open - 1) .. string.sub(text, close + 2)
				end
			end
			text = stripComment(text)
		end
		table.insert(codeLines, text)
		table.insert(rawLines, raw)
	end
	return codeLines, rawLines
end

-- Scans one framework file. ctx = { path, names ({ [name] = reason }), isBlink? }. No allow-list:
-- the v1.3.1 transitional list (TRANSITIONAL_V131) was deleted in v1.3.1.
function Guard.scanFrameworkSpecial(source: string, ctx: any): { string }
	local codeLines, _rawLines = codeLinesOf(source, ctx.isBlink)
	local norm, lineOf = Guard.normalize(codeLines)
	local findings, seen = {}, {}
	local function add(line: number, message: string)
		-- no `-- guard: allow special` here: the framework half has no allow-list
		local key = `{line}|{message}`
		if not seen[key] then
			seen[key] = true
			table.insert(findings, { line = line, text = `{ctx.path}:{line}: [special] {message}` })
		end
	end
	local function message(reason: string): string
		return `{reason} in framework code: the framework knows no kit (R19; move it into the kit module)`
	end
	local names = {}
	for name in ctx.names do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local pattern = "%f[%w_]" .. escape(name) .. "%f[^%w_]"
		-- 1. each comment-stripped line, concatenations folded (`return Mail`, `"Ma" .. "il"`)
		for lineNo, code in codeLines do
			if string.find(foldConcat(code), pattern) then
				add(lineNo, message(ctx.names[name]))
			end
		end
		-- 2. the normalised file (split across lines, x["Mail"] -> x.Mail)
		local init = 1
		while true do
			local s, e = string.find(norm, pattern, init)
			if s == nil then
				break
			end
			add(lineOf[s] or 1, message(ctx.names[name]))
			init = (e or s) + 1
		end
	end
	-- the old kit net marker `net = "framework"` (kit client parts on the framework's Blink file)
	local marker = 'net=="framework"'
	local ms = string.find(norm, marker, 1, true)
	if ms then
		add(lineOf[ms] or 1, message('the kit net marker net == "framework"'))
	end
	table.sort(findings, function(a, b)
		return a.line < b.line
	end)
	local out = {}
	for _, f in findings do
		table.insert(out, f.text)
	end
	return out
end

function Guard.scanFrameworkSpecialAll(): { string }
	local modules, events = Guard.kitNamesOnDisk()
	local names = Guard.frameworkSpecialNames(modules, events)
	local generated = Guard.generatedFiles()
	local findings = {}
	local files = {}
	for _, root in Guard.FRAMEWORK_SPECIAL_ROOTS do
		walk(root, files)
	end
	table.sort(files)
	for _, path in files do
		if not string.match(path, "%.spec%.luau$") and not generated[normalizePath(path)] then
			for _, f in Guard.scanFrameworkSpecial(fs.readFile(path), { path = path, names = names }) do
				table.insert(findings, f)
			end
		end
	end
	local blink = Guard.FRAMEWORK_BLINK
	for _, f in
		Guard.scanFrameworkSpecial(fs.readFile(blink), { path = blink, names = names, isBlink = true })
	do
		table.insert(findings, f)
	end
	return findings
end

local function git(args: { string }): string?
	local ok, result = pcall(process.exec, "git", args)
	if not ok or not result.ok then
		return nil
	end
	return result.stdout
end

local function lines(text: string?): { string }
	local out = {}
	for l in string.gmatch(text or "", "[^\n]+") do
		table.insert(out, l)
	end
	return out
end

-- Pure part of the packages check (testable): branch name, files changed on the branch since
-- main, and staged files. opts (v1.4.0, both optional):
--   coreRepo  the working tree IS the core (roblox-core): templates/ are core paths there, so a
--             commit may mix them with packages/ (only games/<name>/ counts as game work)
--   coreDir   a games repo's core submodule folder (e.g. "roblox-core"): it is treated like
--             packages/ (the submodule pointer or anything under it is a core change)
function Guard.packagesFindings(
	branch: string,
	branchFiles: { string },
	staged: { string },
	opts: { coreRepo: boolean?, coreDir: string? }?
): { string }
	local o = opts or {}
	local coreDir = o.coreDir
	local function isCore(f: string): boolean
		if string.match(f, "^packages/") then
			return true
		end
		return coreDir ~= nil and (f == coreDir or string.sub(f, 1, #coreDir + 1) == coreDir .. "/")
	end
	local coreName = if coreDir then coreDir .. "/" else "packages/"
	local findings = {}
	if string.match(branch, "^game") then -- game/x, games/x, gamez/x (review R9)
		for _, f in branchFiles do
			if isCore(f) then
				table.insert(
					findings,
					`{f}: [packages] game branch '{branch}' edits the framework; file a FRAMEWORK_REQUESTS.md entry (games repo) instead`
				)
			end
		end
	end
	local touchesGame, touchesCore = nil, false
	for _, f in staged do
		local game = string.match(f, "^games/([^/]+)/")
		if game then
			touchesGame = game
		elseif string.match(f, "^templates/") and not o.coreRepo then
			touchesGame = touchesGame or "templates"
		end
		if isCore(f) then
			touchesCore = true
		end
	end
	if touchesGame and touchesCore then
		table.insert(
			findings,
			`staged: [packages] one commit edits games/{touchesGame}/ and {coreName}: games never edit the framework (bump the submodule in its own commit)`
		)
	end
	return findings
end

-- v1.4.0 core pin (games repo): the core submodule must be exactly a release tag with no local
-- changes. Pure: `tag` = `git -C <coreDir> describe --tags --exact-match HEAD` output (nil/"" when
-- HEAD is not a tag), `status` = `git -C <coreDir> status --porcelain` output (nil when the folder
-- isn't a git checkout: submodule not initialised).
function Guard.corePinFindings(coreDir: string, tag: string?, status: string?): { string }
	local findings = {}
	if status == nil then
		table.insert(
			findings,
			`{coreDir}: [packages] not a git checkout; run git submodule update --init (docs/framework/games-repo.md)`
		)
		return findings
	end
	if tag == nil or not string.match(tag, "^v%d+%.%d+%.%d+$") then
		table.insert(
			findings,
			`{coreDir}: [packages] the framework submodule is not at a release tag (git -C {coreDir} checkout vX.Y.Z)`
		)
	end
	for line in string.gmatch(status, "[^\n]+") do
		table.insert(
			findings,
			`{coreDir}/{string.sub(line, 4)}: [packages] local change in the framework submodule; games never edit {coreDir}/ (git -C {coreDir} checkout -- . / file a FRAMEWORK_REQUESTS.md entry)`
		)
	end
	return findings
end

function Guard.gitFindings(): { string }
	local Roots = require("./Roots")
	local findings = {}
	if Roots.external then
		local tag = git({ "-C", Roots.CORE, "describe", "--tags", "--exact-match", "HEAD" })
		local status = git({ "-C", Roots.CORE, "status", "--porcelain" })
		for _, f in Guard.corePinFindings(Roots.CORE, tag and (string.gsub(tag, "%s+$", "")), status) do
			table.insert(findings, f)
		end
	end
	local branch = (git({ "rev-parse", "--abbrev-ref", "HEAD" }) or ""):gsub("%s+$", "")
	-- the core owner's bypass works only on core branches and main (review R9), never in a games repo
	if
		not Roots.external
		and process.env.GUARD_ALLOW_CORE == "1"
		and (branch == "main" or string.match(branch, "^core/"))
	then
		return findings
	end
	local branchFiles = {}
	if string.match(branch, "^game") then -- game/x, games/x, gamez/x (review R9)
		local base = (git({ "merge-base", "HEAD", "main" }) or ""):gsub("%s+$", "")
		if base ~= "" then
			branchFiles = lines(git({ "diff", "--name-only", base }))
			for _, f in lines(git({ "ls-files", "--others", "--exclude-standard" })) do
				table.insert(branchFiles, f)
			end
		end
	end
	local staged = lines(git({ "diff", "--cached", "--name-only" }))
	local opts = if Roots.external then { coreDir = Roots.CORE } else { coreRepo = true }
	for _, f in Guard.packagesFindings(branch, branchFiles, staged, opts) do
		table.insert(findings, f)
	end
	return findings
end

local function selfTest(): boolean
	local failures = {}
	local function expectCheck(name: string, findings: { string }, check: string)
		for _, f in findings do
			if string.find(f, "[" .. check .. "]", 1, true) then
				return
			end
		end
		table.insert(failures, `{name}: expected a [{check}] finding, got {#findings}`)
	end
	local function expectClean(name: string, findings: { string })
		if #findings > 0 then
			table.insert(failures, `{name}: expected no findings, got: {table.concat(findings, " | ")}`)
		end
	end
	local mods = Guard.parseModules('modules = { "Items", "Inventory", "Economy" },')
	local server = { path = "games/x/src/server/Main.server.luau", modules = mods, isServer = true }
	local client =
		{ path = "games/x/src/client/Main.client.luau", modules = mods, isServer = false, isClient = true }

	expectCheck("module off", Guard.scanSource("Core.Rebirth.rebirth(player)", server), "modules")
	-- v1.3 module refs (v1.3.0)
	local refMods = Guard.parseModules(
		'modules = {\n\trequire(Collection:WaitForChild("Items")), -- "Rebirth" in a comment\n'
			.. '\trequire(Economy:WaitForChild("Economy")),\n} :: { any },'
	)
	if not (refMods and refMods.Items and refMods.Economy and not refMods.Rebirth) then
		table.insert(failures, "parseModules: v1.3 ref lines not read (or a comment was)")
	end
	local refServer = { path = "games/x/modules/x/server/init.luau", modules = refMods, isServer = true }
	expectCheck(
		"ref off",
		Guard.scanSource('local Rebirth = require(EconomyKit:WaitForChild("Rebirth"))', refServer),
		"modules"
	)
	expectClean(
		"ref on",
		Guard.scanSource('local Economy = require(EconomyKit:WaitForChild("Economy"))', refServer)
	)
	expectCheck("action off", Guard.scanSource("Core.Client.Actions.rebirth()", client), "modules")
	expectCheck("internals", Guard.scanSource('require(SSS:WaitForChild("CoreServer"))', server), "modules")
	expectCheck(
		"client internals",
		Guard.scanSource('require(RS:WaitForChild("FrameworkClient"))', client),
		"modules"
	)
	expectCheck(
		"ProcessReceipt",
		Guard.scanSource("MarketplaceService.ProcessReceipt = function(r) return 1 end", server),
		"purchases"
	)
	expectCheck(
		"ProcessReceipt spaced",
		Guard.scanSource("MarketplaceService.ProcessReceipt=myHandler", server),
		"purchases"
	)
	expectCheck(
		"PromptFinished",
		Guard.scanSource("MPS.PromptProductPurchaseFinished:Connect(fn)", client),
		"purchases"
	)
	expectCheck(
		"DataStore",
		Guard.scanSource('local ds = game:GetService("DataStoreService")', server),
		"purchases"
	)
	expectCheck("ProfileStore", Guard.scanSource("local PS = require(SS.ProfileStore)", server), "purchases")
	expectClean("ProcessReceipt compare", Guard.scanSource("if MPS.ProcessReceipt == mine then end", server))
	local pkg = { path = "packages/kits/x/server/Thing.luau", onlyPurchases = true }
	expectCheck("package ProcessReceipt", Guard.scanSource("MPS.ProcessReceipt = fn", pkg), "purchases")
	expectClean("package other checks off", Guard.scanSource("local eggCost = 500", pkg))
	if Guard.isPurchasesAllowed("packages/kits/x/server/Thing.luau") then
		table.insert(failures, "purchases allow-list: a kit file must not be allowed")
	end
	if not Guard.isPurchasesAllowed("packages/framework/server/Shop/init.luau") then
		table.insert(failures, "purchases allow-list: framework Shop must be allowed")
	end
	-- v1.3.0: MemoryStoreService is framework-only too, and Mail is off the allow-list
	expectCheck(
		"package MemoryStore",
		Guard.scanSource('local MS = game:GetService("MemoryStoreService")', pkg),
		"purchases"
	)
	if Guard.isPurchasesAllowed("packages/kits/social/server/Mail/init.luau") then
		table.insert(failures, "purchases allow-list: Mail must not be allowed (it uses ctx.data.shared)")
	end
	expectCheck(
		"kit internals",
		Guard.scanSource('require(SSS:WaitForChild("Kits"):WaitForChild("Economy"))', server),
		"modules"
	)
	expectCheck("kit internals dot", Guard.scanSource("require(SSS.Kits.Economy.Economy)", server), "modules")
	expectClean(
		"kit module definitions",
		Guard.scanSource('local Kits = ReplicatedStorage:WaitForChild("Kits")', server)
	)
	expectClean("module on", Guard.scanSource("Core.Economy.grant(player, Balance.reward, 'x')", server))
	expectClean("comment", Guard.scanSource("-- Core.Rebirth.rebirth(player)", server))
	expectClean(
		"block comment",
		Guard.scanSource("--[[\n  Core.Rebirth.rebirth(player)\n]]\nlocal x = 1", server)
	)
	expectCheck("after block", Guard.scanSource("--[[ c ]] Core.Rebirth.rebirth(p)", server), "modules")

	expectCheck("OnServerEvent", Guard.scanSource("remote.OnServerEvent:Connect(fn)", server), "remotes")
	expectCheck("new remote", Guard.scanSource('Instance.new("RemoteEvent")', client), "remotes")
	expectCheck("blink On", Guard.scanSource("GameNet.PlaceItem.On(function(p) end)", server), "remotes")
	expectClean(
		"Core.Net",
		Guard.scanSource("Core.Net.handle('PlaceItem', GameNet.PlaceItem, Limits.place, onPlace)", server)
	)
	expectClean("client On", Guard.scanSource("GameNet.Ping.On(function() end)", client))
	local shared = { path = "games/x/src/shared/NetGlue.luau", modules = mods }
	expectCheck("shared On", Guard.scanSource("GameNet.PlaceItem.On(function(p) end)", shared), "remotes")
	expectCheck(
		"concat OnServer",
		Guard.scanSource('remote["OnServer" .. "Event"]:Connect(fn)', server),
		"remotes"
	)
	expectCheck("dynamic new", Guard.scanSource("local r = Instance.new(cls)", server), "remotes")
	expectClean("literal new", Guard.scanSource('local p = Instance.new("Part")', server))

	-- which files are scanned (exact-path exclusions only)
	local gen = { ["packages/framework/server/Net/Generated.luau"] = true }
	for _, f in
		{
			"games/my-game/modules/my-game/server/EvilGenerated.luau",
			"games/my-game/modules/my-game/server/Generated/Evil.luau",
			"games/my-game/modules/my-game/server/Evil.lua",
			"games/my-game/modules/my-game/server/Packages/Evil.luau",
			"games/my-game/src/server/ServerPackages/Evil.luau",
			"packages/kits/economy/server/Generated.luau",
		}
	do
		if not Guard.isScannedFile(f, gen) then
			table.insert(failures, "scan set: " .. f .. " is shipped by Rojo and must be scanned")
		end
	end
	for _, f in
		{
			"packages/framework/server/Net/Generated.luau",
			"deps/Packages/Promise.lua",
			"deps/ServerPackages/x/init.luau",
			"games/x/src/server/Thing.spec.luau",
			"games/x/README.md",
		}
	do
		if Guard.isScannedFile(f, gen) then
			table.insert(failures, "scan set: " .. f .. " must not be scanned")
		end
	end
	local outs = Guard.blinkOutputs(
		"packages/framework/shared/net/framework.blink",
		'option ServerOutput = "../../server/Net/Generated.luau"\noption TypesOutput = "Generated.Types.luau"'
	)
	if
		not table.find(outs, "packages/framework/server/Net/Generated.luau")
		or not table.find(outs, "packages/framework/shared/net/Generated.Types.luau")
	then
		table.insert(failures, "blinkOutputs: " .. table.concat(outs, ", "))
	end
	-- textual evasions of the purchases / remotes checks
	local gm = { path = "games/x/modules/x/server/init.luau", modules = mods, isServer = true }
	expectCheck("bracket ProcessReceipt", Guard.scanSource('MS["ProcessReceipt"] = fn', gm), "purchases")
	expectCheck("bracket ProcessReceipt sq", Guard.scanSource("MS[ 'ProcessReceipt' ]=fn", gm), "purchases")
	expectCheck("split ProcessReceipt", Guard.scanSource("MS.ProcessReceipt\n\t= fn", gm), "purchases")
	expectCheck(
		"split ProcessReceipt comment",
		Guard.scanSource("MS.ProcessReceipt -- later\n-- more\n= fn", gm),
		"purchases"
	)
	expectCheck(
		"rawset ProcessReceipt",
		Guard.scanSource('rawset(MS, "Process" .. "Receipt", fn)', gm),
		"purchases"
	)
	expectCheck(
		"concat DataStore",
		Guard.scanSource('local ds = game:GetService("Data" .. "StoreService")', gm),
		"purchases"
	)
	expectCheck(
		"concat DataStore lines",
		Guard.scanSource('local ds = game:GetService(\n\t"Data"\n\t.. "StoreService"\n)', gm),
		"purchases"
	)
	expectCheck("computed GetService", Guard.scanSource("local s = game:GetService(name)", gm), "purchases")
	expectCheck("concat new remote", Guard.scanSource('Instance.new("Remote" .. "Function")', gm), "remotes")
	expectCheck("bracket new", Guard.scanSource('Instance["new"](cls)', gm), "remotes")
	expectCheck("bracket OnServerEvent", Guard.scanSource('r["OnServerEvent"]:Connect(fn)', gm), "remotes")
	expectCheck(
		"blink On in server/netclient",
		Guard.scanSource(
			"GameNet.Cheat.On(fn)",
			{ path = "games/x/modules/x/server/netclient/Handlers.luau", modules = mods, isServer = true }
		),
		"remotes"
	)
	if Guard.hasSegment("modules/x/server/netclient/Handlers.luau", "client") then
		table.insert(failures, "hasSegment: server/netclient/ is not a client folder")
	end
	if not Guard.hasSegment("src/client/Main.client.luau", "client") then
		table.insert(failures, "hasSegment: src/client/ is a client folder")
	end
	expectCheck(
		"package concat DataStore",
		Guard.scanSource('local d = game:GetService("DataStore" .. "Service")', pkg),
		"purchases"
	)
	expectClean("literal GetService", Guard.scanSource('local P = game:GetService("Players")', gm))
	expectClean(
		"ProcessReceipt compare split",
		Guard.scanSource("if MPS.ProcessReceipt\n== mine then end", gm)
	)
	expectClean(
		"allowed normalised",
		Guard.scanSource('local d = game:GetService("DataStoreService") -- guard: allow purchases', gm)
	)
	expectCheck("exp literal", Guard.scanSource("Core.Economy.grant(player, 1e3, 'q')", server), "numbers")
	expectCheck("hex literal", Guard.scanSource("Core.Economy.grant(player, 0xFF, 'q')", server), "numbers")

	expectCheck(
		"grant literal",
		Guard.scanSource("Core.Economy.grant(player, 250, 'quest')", server),
		"numbers"
	)
	expectCheck("cost literal", Guard.scanSource("local eggCost = 500", server), "numbers")
	expectClean("zero/one", Guard.scanSource("local count = 0\nlocal luckBase = 1", server))
	expectClean("ui sizes", Guard.scanSource("frame.Size = UDim2.fromOffset(200, 48)", client))
	expectClean(
		"not a balance word",
		Guard.scanSource("local expandTime = 5\nlocal captionSize = 14", client)
	)
	expectClean(
		"config ok",
		Guard.scanSource("local eggCost = 500", { path = "c", modules = mods, inConfig = true })
	)
	expectClean("allowed", Guard.scanSource("local eggCost = 500 -- guard: allow numbers", server))

	expectCheck(
		"game branch",
		Guard.packagesFindings("game/example-shop", { "packages/kits/social/server/Mail/init.luau" }, {}),
		"packages"
	)
	expectCheck(
		"mixed staged",
		Guard.packagesFindings("main", {}, { "games/example-shop/src/x.luau", "packages/ui/Button.luau" }),
		"packages"
	)
	expectClean("core branch", Guard.packagesFindings("core/v12-a", { "packages/framework/x.luau" }, {}))
	expectCheck(
		"gamez branch",
		Guard.packagesFindings("gamez/x", { "packages/framework/y.luau" }, {}),
		"packages"
	)
	expectCheck(
		"templates + core",
		Guard.packagesFindings("main", {}, { "templates/a", "packages/b" }),
		"packages"
	)
	expectClean("sandbox + core", Guard.packagesFindings("main", {}, { "examples/sandbox/x", "packages/y" }))
	-- v1.4.0: in the core repo templates are core; in a games repo the core submodule is core
	expectClean(
		"core repo: templates + packages",
		Guard.packagesFindings("main", {}, { "templates/a", "packages/b" }, { coreRepo = true })
	)
	expectCheck(
		"core repo: a scratch game + packages",
		Guard.packagesFindings("main", {}, { "games/x/a", "packages/b" }, { coreRepo = true }),
		"packages"
	)
	local inGames = { coreDir = "roblox-core" }
	expectCheck(
		"games repo: game + submodule bump in one commit",
		Guard.packagesFindings("main", {}, { "games/x/src/a.luau", "roblox-core" }, inGames),
		"packages"
	)
	expectCheck(
		"games repo: game branch moves the submodule",
		Guard.packagesFindings("game/x", { "roblox-core" }, {}, inGames),
		"packages"
	)
	expectClean(
		"games repo: submodule bump alone",
		Guard.packagesFindings("main", {}, { "roblox-core" }, inGames)
	)
	expectClean("core pin: tag, clean", Guard.corePinFindings("roblox-core", "v1.4.0", ""))
	expectCheck("core pin: not a tag", Guard.corePinFindings("roblox-core", nil, ""), "packages")
	expectCheck(
		"core pin: not a tag (describe)",
		Guard.corePinFindings("roblox-core", "v1.4.0-3-gabc", ""),
		"packages"
	)
	expectCheck(
		"core pin: local change",
		Guard.corePinFindings("roblox-core", "v1.4.0", " M packages/ui/Button.luau\n"),
		"packages"
	)
	expectCheck("core pin: not initialised", Guard.corePinFindings("roblox-core", nil, nil), "packages")

	-- special ("nothing is special", v1.3.0): planted violations and evasions are caught
	local kitCtx = { path = "packages/kits/economy/server/X.luau", kit = "Economy" }
	local exCtx = { path = "examples/modules/x/server/init.luau" }
	local specialCases = {
		{ "facade child", 'local S = require(RS:WaitForChild("Framework"):WaitForChild("RuntimeSlot"))' },
		{ "facade child dot", "local R = require(ReplicatedStorage.Framework.Resolve)" },
		{ "alias", 'local F = RS:WaitForChild("Framework")\nlocal Sig = require(F:WaitForChild("Signal"))' },
		{ "alias of alias", "local F = RS.Framework\nlocal G = F\nlocal R = require(G.Resolve)" },
		{
			"server runtime chain",
			'local D = require(game:GetService("ServerScriptService"):WaitForChild("Framework"):WaitForChild("Data"))',
		},
		{
			"SSS alias",
			'local SSS = game:GetService("ServerScriptService")\nlocal St = require(SSS.Framework.Store)',
		},
		{
			"concat",
			'local S = require(RS:WaitForChild("Frame" .. "work"):WaitForChild("Runtime" .. "Slot"))',
		},
		{ "concat name only", 'local x = RS:FindFirstChild("Compat" .. "Door")' },
		{ "FindFirstChild", 'local T = require(RS:FindFirstChild("Framework"):FindFirstChild("Theme"))' },
		{ "dynamic child", "local name = pick()\nlocal M = require(RS.Framework[name])" },
		{
			"dynamic SSS child",
			'local SSS = game:GetService("ServerScriptService")\nlocal M = SSS:WaitForChild(name)',
		},
		{ "script.Parent climb", "local D = require(script.Parent.Parent.Parent.framework.server.Data)" },
		{ "FindFirstAncestor", 'local F = script:FindFirstAncestor("Framework")' },
		{ "FrameworkClient", 'local N = require(RS:WaitForChild("FrameworkClient"):WaitForChild("Net"))' },
		{ "CompatDoor", 'local C = require(SSS:WaitForChild("CompatDoor"))' },
		{
			"other kit internals",
			'local SSS = game:GetService("ServerScriptService")\nlocal I = require(SSS:WaitForChild("Kits"):WaitForChild("Collection"):WaitForChild("Inventory"))',
		},
		{
			"other kit alias",
			'local SSS = game:GetService("ServerScriptService")\nlocal K = SSS:WaitForChild("Kits")\nlocal M = require(K.Social.Mail)',
		},
	}
	-- enumerating ServerScriptService / Framework children
	table.insert(specialCases, {
		"GetChildren loop",
		'local SSS = game:GetService("ServerScriptService")\nfor _, c in SSS:GetChildren() do\n\tif c.Name:sub(1, 5) == "Frame" then F = require(c) end\nend',
	})
	table.insert(specialCases, {
		"GetDescendants direct",
		'for _, c in game:GetService("ServerScriptService"):GetDescendants() do end',
	})
	table.insert(specialCases, { "Framework GetChildren", "for _, m in RS.Framework:GetChildren() do end" })
	for _, case in specialCases do
		expectCheck("special " .. case[1], Guard.scanSpecial(case[2], kitCtx), "special")
	end
	expectCheck(
		"special example kit internals",
		Guard.scanSpecial('local x = game:GetService("ServerScriptService").Kits.Economy', exCtx),
		"special"
	)
	for _, clean in
		{
			{ "facade", 'local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))' },
			{ "facade dot", "local StudWork = require(ReplicatedStorage.Framework)" },
			{ "UI", 'local Button = require(ReplicatedStorage:WaitForChild("UI"):WaitForChild("Button"))' },
			{ "kit refs", 'local Economy = require(Kits:WaitForChild("Economy"):WaitForChild("Economy"))' },
			{
				"own kit server",
				'local SSS = game:GetService("ServerScriptService")\nlocal M = SSS:WaitForChild("Kits"):WaitForChild("Economy")',
			},
			{ "comment", "-- ServerScriptService.Framework.Data is internal" },
			{ "own children", "local Rules = require(script.Parent.Rules)" },
		}
	do
		expectClean("special clean " .. clean[1], Guard.scanSpecial(clean[2], kitCtx))
	end
	expectClean(
		"special allowed",
		Guard.scanSpecial("local S = require(RS.Framework.Resolve) -- guard: allow special", kitCtx)
	)
	-- special, SSS.Modules (core-v1.3.1 R19): another module's server part is internal
	local modCtx =
		{ path = "packages/kits/economy/Upgrades/server/init.luau", kit = "Economy", module = "Upgrades" }
	for _, case in
		{
			{
				"other module server",
				'local SSS = game:GetService("ServerScriptService")\nlocal I = require(SSS:WaitForChild("Modules"):WaitForChild("Inventory"))',
			},
			{
				"other module server dot",
				'local I = require(game:GetService("ServerScriptService").Modules.Inventory)',
			},
			{
				"other module alias",
				'local SSS = game:GetService("ServerScriptService")\nlocal M = SSS:WaitForChild("Modules")\nlocal I = require(M.Inventory)',
			},
			{
				"dynamic module",
				'local SSS = game:GetService("ServerScriptService")\nlocal I = require(SSS.Modules[name])',
			},
		}
	do
		expectCheck("special " .. case[1], Guard.scanSpecial(case[2], modCtx), "special")
	end
	expectClean(
		"special clean module refs",
		Guard.scanSpecial(
			'local Economy = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))',
			modCtx
		)
	)
	-- v1.3.1 module refs in Config and game code (modules check)
	local refMods131 = Guard.parseModules(
		'modules = {\n\trequire(Modules:WaitForChild("Items"):WaitForChild("module")), -- "Rebirth"\n} :: { any },'
	)
	if not (refMods131 and refMods131.Items and not refMods131.Rebirth and not refMods131.module) then
		table.insert(failures, "parseModules: v1.3.1 ref lines not read (or a comment / 'module' was)")
	end
	expectCheck(
		"ref off v1.3.1",
		Guard.scanSource(
			'local Rebirth = require(Modules:WaitForChild("Rebirth"):WaitForChild("module"))',
			{ path = "games/x/modules/x/server/init.luau", modules = refMods131, isServer = true }
		),
		"modules"
	)

	-- special, framework half (core-v1.3.1 R19): planted kit names in framework code are caught
	local fwNames = Guard.frameworkSpecialNames({ "Mail", "Economy" }, { "SendGift" })
	local fwCtx = { path = "packages/framework/server/X.luau", names = fwNames }
	for _, case in
		{
			{ "string literal", 'local x = "Mail"' },
			{ "field", "local n = state.modules.Mail" },
			{ "index", 'local n = state.modules["Mail"]' },
			{ "concat", 'local n = state.modules["Ma" .. "il"]' },
			{ "concat split", 'local n = "Ma"\n\t.. "il"' },
			{ "bare word", "return Mail" },
			{ "widget id", 'UI.registerWidget("Economy.currency", spec)' },
			{ "kit event", "local e = Generated.SendGift" },
			{ "loader name", 'local k = sss:FindFirstChild("Kits")' },
			{ "loader fn", "local function kitLoadServer() end" },
			{ "ModuleClients", "local c = require(kit.ModuleClients)" },
		}
	do
		expectCheck("framework special " .. case[1], Guard.scanFrameworkSpecial(case[2], fwCtx), "special")
	end
	expectCheck(
		"framework special kit event in framework.blink",
		Guard.scanFrameworkSpecial(
			"event SendGift {\n    From: Client,\n    Data: u8\n}",
			{ path = Guard.FRAMEWORK_BLINK, names = fwNames, isBlink = true }
		),
		"special"
	)
	expectCheck(
		"framework special kit module in a framework.blink field",
		Guard.scanFrameworkSpecial(
			"struct M {\n    Mail: string?\n}",
			{ path = Guard.FRAMEWORK_BLINK, names = fwNames, isBlink = true }
		),
		"special"
	)
	for _, clean in
		{
			{ "comment only", "-- Mail and Economy are kits\nlocal x = 1" },
			{ "block comment", "--[[\n\tMail\n]]\nlocal x = 1" },
			{ "longer word", "local MailboxEntry = 1\nlocal t: RarityTier? = nil" },
			{ "lower case key", "local mail = section.mail" },
		}
	do
		expectClean("framework special clean " .. clean[1], Guard.scanFrameworkSpecial(clean[2], fwCtx))
	end
	expectClean(
		"framework special blink comment",
		Guard.scanFrameworkSpecial(
			"-- the Mail kit used to live here\nevent Ping {\n    From: Client\n}",
			{ path = Guard.FRAMEWORK_BLINK, names = fwNames, isBlink = true }
		)
	)
	-- the old v1.2 kit request events and the old `net = "framework"` marker (no allow-list since v1.3.1)
	expectCheck(
		"framework special ignores a guard: allow comment",
		Guard.scanFrameworkSpecial("local m = Modules.Mail -- guard: allow special", fwCtx),
		"special"
	)
	expectCheck(
		"framework special old kit event",
		Guard.scanFrameworkSpecial("local e = Generated.RequestMailClaim", fwCtx),
		"special"
	)
	expectCheck(
		"framework special old kit net marker",
		Guard.scanFrameworkSpecial('if net == "framework" then end', fwCtx),
		"special"
	)
	expectCheck(
		"framework special old kit event in framework.blink",
		Guard.scanFrameworkSpecial(
			"event RequestUpgrade {\n    From: Client\n}",
			{ path = Guard.FRAMEWORK_BLINK, names = fwNames, isBlink = true }
		),
		"special"
	)
	if #Guard.blinkEvents("-- event Nope {\nevent Yes {\n}\n") ~= 1 then
		table.insert(failures, "blinkEvents: commented-out event read")
	end

	-- theme (D's R4)
	local ui = { path = "packages/ui/Badge.luau" }
	expectCheck(
		"theme hex",
		Guard.scanTheme('frame.BackgroundColor3 = Color3.fromHex("#FF3B30")', ui),
		"theme"
	)
	expectCheck("theme hex string", Guard.scanTheme('local accent = "#FFD23F"', ui), "theme")
	expectCheck("theme rgb", Guard.scanTheme("label.TextColor3 = Color3.fromRGB(255, 0, 0)", ui), "theme")
	expectCheck("theme asset", Guard.scanTheme('img.Image = "rbxassetid://1234567"', ui), "theme")
	expectClean("theme token", Guard.scanTheme('frame.BackgroundColor3 = Theme.color("accent")', ui))
	expectClean("theme comment", Guard.scanTheme('-- e.g. "#FF3B30"', ui))
	expectClean("theme allowed", Guard.scanTheme('local x = "#FFFFFF" -- guard: allow theme', ui))
	if
		not Guard.isThemeAllowed("packages/ui/Theme.luau")
		or not Guard.isThemeAllowed("packages/ui/ThemeTokens.luau")
	then
		table.insert(failures, "theme allow-list: theme files must be allowed")
	end
	if Guard.isThemeAllowed("packages/ui/Button.luau") then
		table.insert(failures, "theme allow-list: Button.luau must not be allowed")
	end

	if #failures > 0 then
		print("guardrails self-test FAILED:")
		for _, f in failures do
			print("  - " .. f)
		end
		return false
	end
	print("guardrails self-test: every check catches its planted violation")
	return true
end

-- CLI
local args = process.args
if args[1] == "--self-test" then
	process.exit(if selfTest() then 0 else 1)
end

local dirs = {}
local runGit = #args == 0
if #args > 0 then
	dirs = args
else
	-- every game folder of the project (games/*, and in the core repo examples/sandbox +
	-- examples/overrides/*; tools/lune/Roots.luau) and the new-game template
	dirs = require("./Roots").gameDirs(fs)
	if fs.isDir("templates/new-game") then
		table.insert(dirs, "templates/new-game")
	end
end

local findings = {}
for _, dir in dirs do
	for _, f in Guard.scanGame(dir) do
		table.insert(findings, f)
	end
end
if runGit then
	-- the framework's own scans run in the core repo; a games repo pins a released (already
	-- scanned) core and checks its games (special/theme over games/*/modules, games/*/src/client)
	local external = require("./Roots").external
	if not external then
		for _, f in Guard.scanPackages("packages") do
			table.insert(findings, f)
		end
	end
	for _, f in Guard.scanSpecialAll() do
		table.insert(findings, f)
	end
	if not external then
		for _, f in Guard.scanFrameworkSpecialAll() do
			table.insert(findings, f)
		end
	end
end
if runGit then
	for _, f in Guard.gitFindings() do
		table.insert(findings, f)
	end
end

if #findings > 0 then
	for _, f in findings do
		print(f)
	end
	print(`guardrails: {#findings} finding(s) (see tools/lune/guardrails.luau for each check)`)
	process.exit(1)
end
print(`guardrails: clean ({#dirs} game folder(s))`)
