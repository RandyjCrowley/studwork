--!nocheck
--[[
	tools/lune/guardrails.luau: checks that keep game agents inside the rules (core-v1.2).
	Run by tools/lint. LEAD-OWNED.

	Usage (repo root):
	  lune run tools/lune/guardrails              scan games/* and templates/new-game + git checks
	  lune run tools/lune/guardrails --self-test  plant one violation of each kind in memory and
	                                              prove every check catches it (also run by lint)
	  lune run tools/lune/guardrails <dir> ...    scan only these game folders (no git checks)

	Checks (each finding: path:line: [check] message):
	  modules   game code uses a core module that is not in its GameConfig.modules:
	            Core.<Module>.x, Core.Client.Actions.<action> of that module, or Core internals
	            (CoreServer / CoreClient / FrameworkClient / Compat) required directly.
	  packages  game work edits packages/: on a branch named game/*, any change under packages/
	            since the merge-base with main; on any branch, staged changes that mix packages/
	            with games/<name>/ (other than _sandbox). GUARD_ALLOW_CORE=1 skips it (core owner).
	  numbers   best-effort heuristic: a balance-looking number literal in game code outside
	            src/shared/Config/ (a numeric argument >= 2 to an Economy/Rarity/Upgrades/Shop tx
	            call, or a cost/price/reward/income/luck/chance/weight/amount/... name = number).
	  remotes   a remote that bypasses core's validated Net: OnServerEvent / OnServerInvoke,
	            Instance.new("RemoteEvent"|"RemoteFunction"|"UnreliableRemoteEvent"), or a Blink
	            `.On(` / `.SetCallback(` in server code (use Core.Net.handle).
	  purchases (core-v1.3.0 step 4b, module-api.md §7.1) only the framework may assign
	            MarketplaceService.ProcessReceipt or use Prompt*PurchaseFinished, and only framework
	            Data may touch DataStoreService / ProfileStore. Checked in game code AND in
	            packages/ (every file outside PURCHASES_ALLOWED: framework Shop/Data/Store/Platform,
	            and the v1.2 leftovers still live until Phase 2, listed below with a reason).
	A line ending in `-- guard: allow <check>` (e.g. `-- guard: allow numbers`) is skipped for
	that check; use it rarely and say why on the line above.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Modules = require("../../packages/core/shared/Modules")

local Guard = {}

-- Files/folders under packages/ allowed to own purchases / persistence (the purchases check).
Guard.PURCHASES_ALLOWED = {
	"packages/framework/server/Shop/", -- the exclusive ProcessReceipt owner (§7.1)
	"packages/framework/server/Platform.luau", -- the engine adapter Shop and Data go through
	"packages/framework/server/Store.luau", -- framework Data's ProfileStore store
	"packages/framework/server/Data.luau",
	"packages/framework/test/", -- fakes
	"packages/core/", -- v1.2 Core facade + its tests, the live boot path until step 4b-II; Phase 2 deletes it
	"packages/kits/social/server/Mail/", -- v1.2 Mail's cross-server DataStore (Phase 1 kit work: move to ctx.data.messages)
}

local function purchasesViolation(code: string): string?
	if string.find(code, "ProcessReceipt%s*=[^=]") or string.find(code, "ProcessReceipt%s*=$") then
		return "only the framework Shop assigns MarketplaceService.ProcessReceipt: use ctx.shop.onProduct"
	end
	if string.find(code, "Prompt%a*PurchaseFinished") then
		return "Prompt*PurchaseFinished belongs to the framework Shop: use ctx.shop.onPassOwned / onProduct"
	end
	if string.find(code, "DataStoreService", 1, true) or string.find(code, "ProfileStore", 1, true) then
		return "DataStoreService / ProfileStore only inside framework Data: use ctx.data"
	end
	return nil
end

local MODULE_SET = {}
for _, name in Modules.MODULE_ORDER do
	MODULE_SET[name] = true
end

-- Extracts the module names from a Config init.luau source (`modules = { "A", "B" }`).
function Guard.parseModules(source: string): { [string]: boolean }?
	local body = string.match(source, "modules%s*=%s*(%b{})")
	if body == nil then
		return nil
	end
	local set = {}
	for name in string.gmatch(body, '"([%w_]+)"') do
		set[name] = true
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

-- Scans one file's source. `ctx = { path, modules (set or nil), isServer, isClient, inConfig }`.
function Guard.scanSource(source: string, ctx): { string }
	local findings = {}
	local function add(lineNo: number, check: string, message: string)
		table.insert(findings, `{ctx.path}:{lineNo}: [{check}] {message}`)
	end
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
		local code = stripComment(text)
		if ctx.onlyPurchases then
			local why = not allowed(raw, "purchases") and purchasesViolation(code) or nil
			if why then
				add(lineNo, "purchases", why)
			end
			continue
		end

		-- modules
		if ctx.modules and not allowed(raw, "modules") then
			for ns in string.gmatch(code, "Core%.(%u[%w_]*)%s*[%.:]") do
				if MODULE_SET[ns] and not ctx.modules[ns] then
					add(lineNo, "modules", `Core.{ns} is used but "{ns}" is not in GameConfig.modules`)
				end
			end
			for action in string.gmatch(code, "Actions%.([%a_][%w_]*)%s*%(") do
				local owner = Modules.CLIENT_ACTIONS[action]
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
				or string.find(code, 'Child%(%s*"Compat"')
			)
		then
			add(
				lineNo,
				"modules",
				"game code must use the Core facade, not CoreServer/CoreClient/FrameworkClient/Compat internals"
			)
		end
		if
			not allowed(raw, "modules")
			and (
				string.find(code, 'Child%(%s*"Kits"')
				or string.find(code, "Child%(%s*'Kits'")
				or string.find(code, "%.Kits[%.:]")
			)
		then
			-- core-v1.3.0 step 5: the v1.2 services now live in ServerScriptService.Kits.<Kit>
			add(
				lineNo,
				"modules",
				"game code must use the Core facade, not the kits' service internals (Kits)"
			)
		end

		-- remotes
		if not allowed(raw, "remotes") then
			if string.find(code, "OnServerEvent") or string.find(code, "OnServerInvoke") then
				add(lineNo, "remotes", "raw remote handler: route game remotes through Core.Net.handle")
			end
			if
				string.find(code, "RemoteEvent", 1, true)
				or string.find(code, "RemoteFunction", 1, true)
				or string.find(code, '"OnServer', 1, true)
				or string.find(code, "'OnServer", 1, true)
			then
				add(
					lineNo,
					"remotes",
					"RemoteEvent/RemoteFunction in game code: define remotes in game.blink"
				)
			end
			-- Instance.new with a non-literal class name could create a remote (review R8)
			local newArg = string.match(code, "Instance%.new%s*%(%s*(.)")
			if newArg and newArg ~= '"' and newArg ~= "'" then
				add(lineNo, "remotes", "Instance.new with a dynamic class name: use a string literal")
			end
			-- Blink listeners anywhere outside client code: shared modules run on the server too
			if
				not ctx.isClient
				and (string.find(code, "%.On%s*%(") or string.find(code, "%.SetCallback%s*%("))
			then
				add(
					lineNo,
					"remotes",
					"Blink listener outside client code: use Core.Net.handle(name, event, limit, fn)"
				)
			end
		end

		-- purchases (§7.1)
		if not allowed(raw, "purchases") then
			local why = purchasesViolation(code)
			if why then
				add(lineNo, "purchases", why)
			end
		end

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
	return findings
end

local function walk(dir: string, out: { string })
	if not fs.isDir(dir) then
		return
	end
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			if entry ~= "Packages" and entry ~= "ServerPackages" then
				walk(path, out)
			end
		elseif string.match(entry, "%.luau$") and not string.match(entry, "%.spec%.luau$") then
			table.insert(out, path)
		end
	end
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
		-- extra projects (e.g. _sandbox/foundation-only/) carry their own Config.luau
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
		local isServer = string.find(rel, "server/", 1, true) ~= nil
		local isClient = string.find(rel, "client/", 1, true) ~= nil
		local isGenerated = string.find(rel, "Generated", 1, true) ~= nil
		if not isGenerated then
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
		if not Guard.isPurchasesAllowed(path) and not string.find(path, "Generated", 1, true) then
			for _, f in Guard.scanSource(fs.readFile(path), { path = path, onlyPurchases = true }) do
				table.insert(findings, f)
			end
		end
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
-- main, and staged files.
function Guard.packagesFindings(branch: string, branchFiles: { string }, staged: { string }): { string }
	local findings = {}
	if string.match(branch, "^game") then -- game/x, games/x, gamez/x (review R9)
		for _, f in branchFiles do
			if string.match(f, "^packages/") then
				table.insert(
					findings,
					`{f}: [packages] game branch '{branch}' edits core; add a CORE_REQUESTS.md entry instead`
				)
			end
		end
	end
	local touchesGame, touchesCore = nil, false
	for _, f in staged do
		local game = string.match(f, "^games/([^/]+)/")
		if game and game ~= "_sandbox" then
			touchesGame = game
		elseif string.match(f, "^templates/") then
			touchesGame = touchesGame or "templates"
		end
		if string.match(f, "^packages/") then
			touchesCore = true
		end
	end
	if touchesGame and touchesCore then
		table.insert(
			findings,
			`staged: [packages] one commit edits games/{touchesGame}/ and packages/: games never edit core`
		)
	end
	return findings
end

function Guard.gitFindings(): { string }
	local branch = (git({ "rev-parse", "--abbrev-ref", "HEAD" }) or ""):gsub("%s+$", "")
	-- the core owner's bypass works only on core branches and main (review R9)
	if process.env.GUARD_ALLOW_CORE == "1" and (branch == "main" or string.match(branch, "^core/")) then
		return {}
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
	return Guard.packagesFindings(branch, branchFiles, staged)
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
	expectCheck("action off", Guard.scanSource("Core.Client.Actions.rebirth()", client), "modules")
	expectCheck("internals", Guard.scanSource('require(SSS:WaitForChild("CoreServer"))', server), "modules")
	expectCheck(
		"client internals",
		Guard.scanSource('require(RS:WaitForChild("FrameworkClient"))', client),
		"modules"
	)
	expectCheck(
		"compat",
		Guard.scanSource('require(SSS:WaitForChild("Compat"):WaitForChild("Tx"))', server),
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
	expectCheck(
		"kit internals",
		Guard.scanSource('require(SSS:WaitForChild("Kits"):WaitForChild("Economy"))', server),
		"modules"
	)
	expectCheck("kit internals dot", Guard.scanSource("require(SSS.Kits.Economy.Economy)", server), "modules")
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
	expectClean("core branch", Guard.packagesFindings("core/v12-a", { "packages/core/x.luau" }, {}))
	expectCheck("gamez branch", Guard.packagesFindings("gamez/x", { "packages/core/y.luau" }, {}), "packages")
	expectCheck(
		"templates + core",
		Guard.packagesFindings("main", {}, { "templates/a", "packages/b" }),
		"packages"
	)
	expectClean("sandbox + core", Guard.packagesFindings("main", {}, { "games/_sandbox/x", "packages/y" }))

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
	for _, entry in fs.readDir("games") do
		if fs.isDir("games/" .. entry) then
			table.insert(dirs, "games/" .. entry)
		end
	end
	table.sort(dirs)
	table.insert(dirs, "templates/new-game")
end

local findings = {}
for _, dir in dirs do
	for _, f in Guard.scanGame(dir) do
		table.insert(findings, f)
	end
end
if runGit then
	for _, f in Guard.scanPackages("packages") do
		table.insert(findings, f)
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
