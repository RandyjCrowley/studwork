--!nocheck
--[[
	tools/lune/doctor: environment check behind tools/doctor. Prints one line per check with a fix
	hint and exits 1 when any check FAILs (WARN lines don't fail). Pure parts: DoctorChecks.luau.
	  toolchain  each rokit.toml tool's `--version` matches the pin              (FAIL)
	  packages   every deps/wally.toml dependency is in deps/Packages|ServerPackages
	             at the pinned version (_Index/<owner>_<name>@<version>)          (FAIL)
	  hook       git core.hooksPath = .githooks and .githooks/pre-commit exists  (FAIL)
	  .env       each key of .env.example: present / missing (NEVER the value)   (WARN)
	  ports      each game's servePort: free or in use (lsof)                    (WARN)
	  framework  the core v1.3.0 layout (Layout.luau): packages/framework/{shared,server,client},
	             StudWork.VERSION, packages/kits/<kit>/{shared,server}, no packages/core   (FAIL)
	  projects   every games/*/*.project.json and templates/new-game maps Framework,
	             FrameworkClient and each kit it lists to that layout, nothing into
	             packages/core                                                   (FAIL)
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Doctor = require("./DoctorChecks")
local Layout = require("./Layout")
local CoreInfo = require("./core-info")

local rows = {}
local function add(level, item, detail, fix)
	table.insert(rows, { level = level, item = item, detail = detail, fix = fix })
end

local function run(cmd: string, args: { string }): (boolean, string)
	local ok, result = pcall(process.exec, cmd, args)
	if not ok then
		return false, tostring(result)
	end
	return result.ok, (string.gsub(result.stdout .. result.stderr, "%s+$", ""))
end

-- toolchain
for _, tool in Doctor.parseRokit(fs.readFile("rokit.toml")) do
	local bin = Doctor.BINARY[tool.name] or string.lower(tool.name)
	local ok, out = run(bin, { "--version" })
	local first = string.match(out, "^[^\n]*") or ""
	if not ok then
		add(
			"fail",
			"tool " .. bin,
			"not runnable (want " .. tool.version .. ")",
			"tools/install (rokit install)"
		)
	elseif Doctor.versionMatches(first, tool.version) then
		add("ok", "tool " .. bin, tool.version)
	else
		add(
			"fail",
			"tool " .. bin,
			string.format("'%s', want %s", first, tool.version),
			"rokit install (pins in rokit.toml)"
		)
	end
end

-- wally packages
if fs.isFile("deps/wally.toml") then
	local missing = 0
	local deps = Doctor.parseWally(fs.readFile("deps/wally.toml"))
	for _, dep in deps do
		local folder = if dep.realm == "server"
			then "deps/ServerPackages"
			elseif dep.realm == "dev" then "deps/DevPackages"
			else "deps/Packages"
		local link = folder .. "/" .. dep.alias .. ".lua"
		local index = folder .. "/_Index/" .. dep.index
		if not fs.isFile(link) or not fs.isDir(index) then
			missing += 1
			add(
				"fail",
				"package " .. dep.alias,
				"missing " .. (if fs.isFile(link) then index else link),
				"tools/install (cd deps && wally install)"
			)
		end
	end
	if missing == 0 then
		add("ok", "wally packages", string.format("%d/%d present at pinned versions", #deps, #deps))
	end
else
	add("fail", "wally packages", "deps/wally.toml missing", "restore deps/wally.toml from git")
end

-- hook
local _, hooksPath = run("git", { "config", "--get", "core.hooksPath" })
if hooksPath == ".githooks" and fs.isFile(".githooks/pre-commit") then
	add("ok", "pre-commit hook", "core.hooksPath = .githooks")
elseif not fs.isFile(".githooks/pre-commit") then
	add("fail", "pre-commit hook", ".githooks/pre-commit missing", "restore .githooks/ from git")
else
	add(
		"fail",
		"pre-commit hook",
		"core.hooksPath is '" .. hooksPath .. "', want .githooks",
		"tools/install --hooks-only"
	)
end

-- .env keys (names only, never values)
if fs.isFile(".env.example") then
	local envText = if fs.isFile(".env") then fs.readFile(".env") else nil
	for _, k in Doctor.envKeys(fs.readFile(".env.example"), envText) do
		if k.present then
			add("ok", ".env " .. k.key, "present")
		else
			add(
				"warn",
				".env " .. k.key,
				"missing" .. (if envText == nil then " (no .env file)" else ""),
				"only needed to publish: cp .env.example .env and fill it in (docs/publishing.md)"
			)
		end
	end
end

-- serve ports
local entries = fs.readDir("games")
table.sort(entries)
for _, entry in entries do
	local path = "games/" .. entry .. "/deploy.json"
	if fs.isFile(path) then
		local ok, deploy = pcall(serde.decode, "json", fs.readFile(path))
		local port = ok and type(deploy) == "table" and deploy.servePort
		if type(port) ~= "number" then
			add("fail", "port " .. entry, "deploy.json has no servePort", 'add "servePort" to ' .. path)
		else
			local inUse, out = run("lsof", { "-nP", "-iTCP:" .. tostring(port), "-sTCP:LISTEN" })
			if inUse and out ~= "" then
				local who = string.match(out, "\n(%S+)") or "?"
				add(
					"warn",
					"port " .. entry,
					string.format("%d in use (%s)", port, who),
					"stop the other process, unless it is your own tools/dev " .. entry
				)
			else
				add("ok", "port " .. entry, string.format("%d free", port))
			end
		end
	end
end

-- framework layout (core v1.3.0: StudWork in packages/framework, kits in packages/kits)
local kits = {}
if fs.isDir(Layout.KITS_DIR) then
	for _, entry in fs.readDir(Layout.KITS_DIR) do
		if fs.isDir(Layout.KITS_DIR .. "/" .. entry) then
			table.insert(kits, entry)
		end
	end
end
table.sort(kits)
local function exists(path: string): boolean
	return fs.isFile(path) or fs.isDir(path)
end
local layoutIssues = Layout.repoIssues(exists, kits)
for _, issue in layoutIssues do
	local fix = if string.find(issue, "still exists", 1, true)
		then "delete it (git rm -r): its code lives in packages/framework and packages/kits since core v1.3.0"
		else "restore it from git (git status / git checkout -- <path>)"
	add("fail", "framework layout", issue, fix)
end
if #layoutIssues == 0 then
	local okVersion, version = pcall(CoreInfo.version)
	if okVersion then
		add("ok", "framework", string.format("StudWork %s, kits: %s", version, table.concat(kits, ", ")))
	else
		add("fail", "framework", tostring(version), "restore packages/framework/shared/init.luau")
	end
end

-- every Rojo project maps the v1.3 layout
local projects = {}
for _, entry in entries do
	local dir = "games/" .. entry
	if fs.isDir(dir) then
		for _, file in fs.readDir(dir) do
			if string.match(file, "%.project%.json$") then
				table.insert(projects, { dir = dir, file = dir .. "/" .. file })
			end
		end
	end
end
table.insert(projects, { dir = "templates/new-game", file = "templates/new-game/default.project.json" })
local badProjects = 0
for _, proj in projects do
	if fs.isFile(proj.file) then
		local ok, decoded = pcall(serde.decode, "json", fs.readFile(proj.file))
		local issues = if ok then Layout.projectIssues(decoded, proj.dir, kits) else { "not valid JSON" }
		for _, issue in issues do
			badProjects += 1
			add("fail", "project " .. proj.file, issue, "map it like templates/new-game/default.project.json")
		end
	end
end
if badProjects == 0 then
	add("ok", "rojo projects", string.format("%d map packages/framework + packages/kits", #projects))
end

local text, failures = Doctor.format(rows)
print(text)
if failures > 0 then
	print(string.format("\ndoctor: %d problem(s)", failures))
	process.exit(1)
end
print("\ndoctor: all good")
