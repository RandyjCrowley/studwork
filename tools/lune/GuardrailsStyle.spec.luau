--!nocheck
-- (StudWork v1.6.0) the "style" pseudo-check of studwork-legacy.json (old code that fails selene /
-- StyLua / luau-lsp), end to end in throwaway adopted projects:
--   * the guardrails accept it, never count it, never say "nothing legacy left" for a style-only
--     entry, and still refuse one added after the adoption commit;
--   * `guardrails --legacy-style-files` lists only the style entries (--legacy-files: all of them);
--   * tools/typecheck prints a style file's problems as `warning: [legacy] ...` and passes, while a
--     problem in any other file still fails;
--   * tools/format formats with the core's stylua.toml, skips listed files, and --check = lint's check;
--   * the remotes guardrail names module actions, not the v1.2 Core.Net.handle.
-- Throwaway projects live under $GUARD_TEST_TMP (or $TMPDIR) and are removed afterwards; git runs
-- with a throwaway identity passed per command (no config is written).
local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")
local process = luneRequire("@lune/process")
local serde = luneRequire("@lune/serde")

local TMP_BASE = process.env.GUARD_TEST_TMP or process.env.TMPDIR or "/tmp"
TMP_BASE = string.gsub(TMP_BASE, "/+$", "")

-- a git hook exports these; inherited, they would point git at the OUTER repository
local STRIP = {
	"GIT_DIR",
	"GIT_WORK_TREE",
	"GIT_INDEX_FILE",
	"GIT_PREFIX",
	"GIT_COMMON_DIR",
	"GIT_OBJECT_DIRECTORY",
	"GIT_ALTERNATE_OBJECT_DIRECTORIES",
	"GIT_NAMESPACE",
	"GIT_CEILING_DIRECTORIES",
	"GIT_AUTHOR_NAME",
	"GIT_AUTHOR_EMAIL",
	"GIT_AUTHOR_DATE",
	"GIT_COMMITTER_NAME",
	"GIT_COMMITTER_EMAIL",
	"GIT_COMMITTER_DATE",
	"GIT_REFLOG_ACTION",
	"STUDWORK_PROJECT_ROOT",
	"STUDWORK_CORE_DIR",
	"STUDWORK_LAYOUT",
}
local function isolated(cmd, args, extra)
	local full = {}
	for _, v in STRIP do
		table.insert(full, "-u")
		table.insert(full, v)
	end
	for _, kv in extra or {} do
		table.insert(full, kv)
	end
	table.insert(full, cmd)
	for _, a in args do
		table.insert(full, a)
	end
	return process.exec("env", full)
end

local function git(dir, args)
	local full = {
		"-C",
		dir,
		"-c",
		"user.name=Test",
		"-c",
		"user.email=test@example.invalid",
		"-c",
		"commit.gpgsign=false",
		"-c",
		"core.hooksPath=/dev/null",
	}
	for _, a in args do
		table.insert(full, a)
	end
	local r = isolated("git", full)
	assert(r.ok, "git " .. table.concat(args, " ") .. ": " .. r.stderr)
	return r.stdout
end

local function write(dir, path, text)
	local parent = string.match(dir .. "/" .. path, "^(.*)/[^/]+$")
	fs.writeDir(parent)
	fs.writeFile(dir .. "/" .. path, text)
end

local function json(v)
	return serde.encode("json", v, true)
end

local seq = 0
local made = {}
local function cleanup()
	for _, d in made do
		pcall(fs.removeDir, d)
	end
	made = {}
end

local function newDir()
	seq += 1
	local dir = `{TMP_BASE}/studwork-guard-style-{os.time()}-{seq}`
	if fs.isDir(dir) then
		fs.removeDir(dir)
	end
	fs.writeDir(dir)
	table.insert(made, dir)
	return dir
end

local OLD = "src/server/Old Code.luau"
-- not StyLua-formatted, and a type error under --!strict
local OLD_SRC = '--!strict\nlocal   n: number = "x"\nreturn n\n'
local SAVE = "src/server/Save.luau"
local SAVE_SRC = 'local DSS = game:GetService("DataStoreService")\nreturn DSS\n'

-- An adopted project, committed: OLD listed with only "style", SAVE with purchases + style.
-- o.list / o.baseline override, o.files = extra { [path] = text } (committed too).
local function project(o)
	o = o or {}
	local dir = newDir()
	git(dir, { "init", "-q" })
	write(dir, OLD, OLD_SRC)
	write(dir, SAVE, SAVE_SRC)
	write(dir, "src/shared/Config.luau", "return {\n\tmodules = {},\n}\n")
	write(
		dir,
		"default.project.json",
		json({
			name = "test-game",
			tree = {
				["$className"] = "DataModel",
				ServerScriptService = { ["$path"] = "src/server" },
				ReplicatedStorage = { ["$path"] = "src/shared" },
			},
		})
	)
	for path, text in o.files or {} do
		write(dir, path, text)
	end
	write(
		dir,
		"studwork.json",
		json({
			layout = "single-game",
			framework = "studwork",
			adopted = true,
			legacyBaseline = o.baseline or { files = { [OLD] = {}, [SAVE] = { purchases = 1 } } },
		})
	)
	write(dir, "studwork-legacy.json", o.list or json({
		files = {
			{ path = OLD, checks = { "style" }, reason = "old code" },
			{ path = SAVE, checks = { "purchases", "style" }, reason = "old save code" },
		},
	}))
	git(dir, { "add", "." })
	git(dir, { "commit", "-q", "-m", "adopt" })
	return dir
end

local function guard(args)
	return isolated("lune", table.move(args, 1, #args, 3, { "run", "tools/lune/guardrails" }))
end

-- A copy of the core's tools and configs as the project's studwork/ (+ the cached Roblox type
-- definitions, so typecheck needs no network).
local DEFS = ".cache/globalTypes-1.70.1.d.luau"
local function withCore(dir)
	fs.writeDir(dir .. "/studwork")
	for _, f in { "tools", "selene.toml", "stylua.toml", "testkit.yml", "rokit.toml" } do
		local r = process.exec("cp", { "-R", f, dir .. "/studwork/" .. f })
		assert(r.ok, "cp " .. f .. ": " .. r.stderr)
	end
	if fs.isFile(DEFS) then
		fs.writeDir(dir .. "/.cache")
		fs.copy(DEFS, dir .. "/" .. DEFS)
	end
end

local function tool(dir, name, args)
	local r = isolated(dir .. "/studwork/tools/" .. name, args or {}, { "STUDWORK_PROJECT_ROOT=" .. dir })
	return r.ok, r.stdout .. r.stderr
end

describe("guardrails: the style pseudo-check", function()
	it("is valid, has no count and never says 'nothing legacy left' for a style-only entry", function()
		local dir = project()
		local r = guard({ "--legacy-check", dir })
		expect(r.stdout).never.toContain("unknown check")
		expect(r.stdout).never.toContain("nothing legacy left")
		expect(r.stdout).toContain("[purchases]")
		expect(r.ok).toBe(true)
		cleanup()
	end)

	it("an entry that keeps style after its guardrail findings are gone says to keep only style", function()
		local dir = project()
		write(dir, SAVE, "return {}\n")
		local r = guard({ "--legacy-check", dir })
		expect(r.stdout).toContain(SAVE .. ': no guardrail findings left; keep only "style"')
		expect(r.stdout).never.toContain("nothing legacy left")
		expect(r.ok).toBe(true)
		cleanup()
	end)

	it("a style entry added after the adoption commit is refused", function()
		local dir = project()
		write(dir, "src/server/Later.luau", "return 1\n")
		write(
			dir,
			"studwork-legacy.json",
			json({
				files = {
					{ path = OLD, checks = { "style" }, reason = "old code" },
					{ path = SAVE, checks = { "purchases", "style" }, reason = "old save code" },
					{ path = "src/server/Later.luau", checks = { "style" }, reason = "later" },
				},
			})
		)
		git(dir, { "add", "." })
		git(dir, { "commit", "-q", "-m", "later" })
		local r = guard({ "--legacy-check", dir })
		expect(r.stdout).toContain("src/server/Later.luau: not in studwork.json's legacyBaseline")
		expect(r.ok).toBe(false)
		cleanup()
	end)

	it("--legacy-style-files lists only style entries; --legacy-files lists every entry", function()
		local dir = project({
			list = json({
				files = {
					{ path = OLD, checks = { "style" }, reason = "old code" },
					{ path = SAVE, checks = { "purchases" }, reason = "old save code" },
				},
			}),
		})
		local r = guard({ "--legacy-style-files", dir })
		expect(r.ok).toBe(true)
		expect(r.stdout).toBe(OLD .. "\told code\n")
		r = guard({ "--legacy-files", dir })
		expect(r.stdout).toBe(OLD .. "\told code\n" .. SAVE .. "\told save code\n")
		cleanup()
	end)
end)

describe("the remotes guardrail message", function()
	it("names module actions, not Core.Net.handle", function()
		local dir = project({
			files = { ["src/server/Remote.luau"] = "local r = workspace.R\nr.OnServerEvent:Connect(print)\n" },
		})
		local r = guard({ "--raw", dir })
		expect(r.stdout).toContain(
			"raw remote handler: use a module action (net.blink + ctx.net, module-api.md §9)"
		)
		expect(r.stdout).never.toContain("Core.Net")
		cleanup()
	end)
end)

describe("tools/typecheck in an adopted project", function()
	it("prints a style file's problems as legacy warnings; any other problem still fails", function()
		if not fs.isFile(DEFS) then
			print("skip: no cached " .. DEFS .. " (run tools/typecheck once)")
			return
		end
		local dir = project()
		withCore(dir)
		local ok, out = tool(dir, "typecheck")
		expect(out).toContain("warning: [legacy] ")
		expect(out).toContain("Old Code.luau")
		expect(out).toContain("typecheck: clean")
		expect(ok).toBe(true)
		write(dir, "src/server/New.luau", '--!strict\nlocal m: number = "y"\nreturn m\n')
		ok, out = tool(dir, "typecheck")
		expect(out).toContain("New.luau")
		expect(out).toContain("typecheck: 1 problem(s)")
		expect(ok).toBe(false)
		-- without "style" the old file's problem fails too
		write(
			dir,
			"studwork-legacy.json",
			json({ files = { { path = SAVE, checks = { "purchases" }, reason = "old save code" } } })
		)
		fs.removeFile(dir .. "/src/server/New.luau")
		ok, out = tool(dir, "typecheck")
		expect(out).never.toContain("warning: [legacy]")
		expect(ok).toBe(false)
		cleanup()
	end)
end)

describe("tools/format", function()
	it("formats with the core's config, skips listed files, and --check is lint's check", function()
		local dir = project()
		withCore(dir)
		-- an unformatted new file
		write(dir, "src/server/New.luau", "local   z=1\nreturn z\n")
		local ok, out = tool(dir, "format", { "--check" })
		expect(ok).toBe(false)
		expect(out).toContain("New.luau")
		expect(out).toContain("warning: [legacy] " .. OLD .. ": selene/stylua skipped")
		ok, out = tool(dir, "format")
		expect(ok).toBe(true)
		expect(out).toContain("format: done")
		expect(fs.readFile(dir .. "/src/server/New.luau")).toBe("local z = 1\nreturn z\n")
		-- the listed old file is untouched
		expect(fs.readFile(dir .. "/" .. OLD)).toBe(OLD_SRC)
		ok, out = tool(dir, "format", { "--check" })
		expect(ok).toBe(true)
		expect(out).toContain("format: clean")
		ok, out = tool(dir, "format", { "--bogus" })
		expect(ok).toBe(false)
		expect(out).toContain("usage: tools/format [--check]")
		cleanup()
	end)

	it("uses the core's column width (110), not StyLua's default", function()
		local dir = project()
		withCore(dir)
		-- 115 columns: fine for StyLua's default 120, too long for the core's 110
		local long = "local value = { " .. string.rep('"abcdefgh", ', 8) .. '"x" }\nreturn value\n'
		write(dir, "src/server/Long.luau", long)
		tool(dir, "format")
		expect(fs.readFile(dir .. "/src/server/Long.luau")).never.toBe(long)
		cleanup()
	end)
end)
