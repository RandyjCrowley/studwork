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
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Doctor = require("./DoctorChecks")

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

local text, failures = Doctor.format(rows)
print(text)
if failures > 0 then
	print(string.format("\ndoctor: %d problem(s)", failures))
	process.exit(1)
end
print("\ndoctor: all good")
