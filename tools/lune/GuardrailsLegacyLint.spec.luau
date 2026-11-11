--!nocheck
-- (StudWork v1.6.0) an adopted project's legacy list vs tools/lint (adopting.md §5):
--   * `guardrails --legacy-files [<dir>]` prints "<path>\t<reason>" for each valid entry (paths
--     with spaces kept) and nothing for a broken list / a project that isn't adopted;
--   * tools/lint skips selene and stylua for the listed files (one `warning: [legacy] ...` line
--     each), still lints every other file, and a broken list lints everything;
--   * the purchases/remotes findings are counted per statement (Guard.statementLines), not per
--     line, so a pure re-wrap (stylua splitting a line) can't raise a file's legacy count.
-- Throwaway projects live under $GUARD_TEST_TMP (or $TMPDIR) and are removed afterwards; git runs
-- with a throwaway identity passed per command (no config is written).
local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")
local process = luneRequire("@lune/process")
local serde = luneRequire("@lune/serde")

local TMP_BASE = process.env.GUARD_TEST_TMP or process.env.TMPDIR or "/tmp"
TMP_BASE = string.gsub(TMP_BASE, "/+$", "")
local OLD = "src/old dir/Old Save.luau"
local OLD_SRC = '_G.Saves = {}\nlocal   DSS=game:GetService("DataStoreService")\nreturn DSS\n'

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
	local dir = `{TMP_BASE}/studwork-guard-lint-{os.time()}-{seq}`
	if fs.isDir(dir) then
		fs.removeDir(dir)
	end
	fs.writeDir(dir)
	table.insert(made, dir)
	return dir
end

-- An adopted project with OLD listed (purchases), committed. o.list = raw list text (optional),
-- o.adopted, o.files = extra { [path] = text }.
local function project(o)
	o = o or {}
	local dir = newDir()
	git(dir, { "init", "-q" })
	write(dir, OLD, o.old or OLD_SRC)
	write(dir, "src/shared/Config.luau", "return {\n\tmodules = {},\n}\n")
	for path, text in o.files or {} do
		write(dir, path, text)
	end
	write(
		dir,
		"studwork.json",
		json({
			layout = "single-game",
			framework = "studwork",
			adopted = if o.adopted == nil then true else o.adopted,
			legacyBaseline = o.baseline or { files = { [OLD] = { purchases = 1 } } },
		})
	)
	write(
		dir,
		"studwork-legacy.json",
		o.list or json({ files = { { path = OLD, checks = { "purchases" }, reason = "old save code" } } })
	)
	git(dir, { "add", "." })
	git(dir, { "commit", "-q", "-m", "adopt" })
	return dir
end

local function legacyFiles(dir)
	return isolated("lune", { "run", "tools/lune/guardrails", "--legacy-files", dir })
end

-- A copy of the core's lint toolchain as the project's studwork/ (enough for selene + stylua).
local function withCore(dir)
	fs.writeDir(dir .. "/studwork")
	for _, f in { "tools", "selene.toml", "stylua.toml", "testkit.yml", "rokit.toml" } do
		local r = process.exec("cp", { "-R", f, dir .. "/studwork/" .. f })
		assert(r.ok, "cp " .. f .. ": " .. r.stderr)
	end
end

local function lint(dir)
	local r = isolated(dir .. "/studwork/tools/lint", {}, { "STUDWORK_PROJECT_ROOT=" .. dir })
	return r.stdout .. r.stderr
end

-- selene and stylua passed: lint went on to the next step
local AFTER_FORMAT = "== sync-projects --check"

describe("guardrails --legacy-files", function()
	it("prints each valid entry's path and reason (spaces kept)", function()
		local r = legacyFiles(project())
		expect(r.ok).toBe(true)
		expect(r.stdout).toBe(OLD .. "\told save code\n")
		cleanup()
	end)

	it("leaves out an invalid entry and prints nothing for a broken list or a non-adopted project", function()
		local r = legacyFiles(project({
			list = json({
				files = {
					{ path = OLD, checks = { "purchases" }, reason = "old" },
					{ path = "src/Gone.luau", checks = { "purchases" }, reason = "gone" },
				},
			}),
		}))
		expect(r.ok).toBe(true)
		expect(r.stdout).toBe(OLD .. "\told\n")
		r = legacyFiles(project({ list = "{ not json" }))
		expect(r.ok).toBe(true)
		expect(r.stdout).toBe("")
		r = legacyFiles(project({ adopted = false }))
		expect(r.stdout).toBe("")
		cleanup()
	end)
end)

describe("tools/lint in an adopted project", function()
	it("skips selene/stylua for listed files and still lints the others", function()
		local dir = project({ files = { ["src/new.luau"] = "return {}\n" } })
		withCore(dir)
		local out = lint(dir)
		expect(out).toContain(
			"warning: [legacy] " .. OLD .. ": selene/stylua skipped (legacy: old save code)"
		)
		expect(out).never.toContain("global_usage")
		expect(out).toContain(AFTER_FORMAT)
		-- an unlisted, unformatted file still fails stylua
		write(dir, "src/bad.luau", "local   z=1\nreturn z\n")
		out = lint(dir)
		expect(out).toContain("src/bad.luau")
		expect(out).never.toContain(AFTER_FORMAT)
		cleanup()
	end)

	it("a broken list skips nothing (selene sees the old file)", function()
		local dir = project({ list = "{ not json" })
		withCore(dir)
		local out = lint(dir)
		expect(out).never.toContain("selene/stylua skipped")
		expect(out).toContain("global_usage")
		expect(out).never.toContain(AFTER_FORMAT)
		cleanup()
	end)
end)

describe("legacy counts survive a re-wrap", function()
	local ONE_LINE = 'local a, b = ProfileStore.New("A"), ProfileStore.New("B")\nreturn a, b\n'
	local WRAPPED = 'local a, b =\n\tProfileStore.New("A"),\n\tProfileStore.New("B")\nreturn a, b\n'
	local CHAINED = 'local a, b = ProfileStore\n\t.New("A"), ProfileStore.New(\n\t\t"B"\n\t)\nreturn a, b\n'

	local function count(dir)
		local r = isolated("lune", { "run", "tools/lune/guardrails", "--raw", dir })
		local _, n = string.gsub(r.stdout, "%[purchases%]", "")
		return n
	end

	it("counts per statement, not per line", function()
		local dir = project({ old = ONE_LINE })
		expect(count(dir)).toBe(1)
		write(dir, OLD, WRAPPED)
		expect(count(dir)).toBe(1)
		write(dir, OLD, CHAINED)
		expect(count(dir)).toBe(1)
		-- separate statements still count separately, also inside a callback body
		write(
			dir,
			OLD,
			'local a = ProfileStore.New("A")\nlocal b = ProfileStore.New("B")\n'
				.. 'game.Players.PlayerAdded:Connect(function(p)\n\tlocal c = ProfileStore.New("C")\n'
				.. '\tlocal d = ProfileStore.New("D")\nend)\n'
		)
		expect(count(dir)).toBe(4)
		cleanup()
	end)

	it("a baseline taken on one line still holds after the line is split", function()
		local dir = project({ old = ONE_LINE, baseline = { files = { [OLD] = { purchases = 1 } } } })
		write(dir, OLD, WRAPPED)
		local r = isolated("lune", { "run", "tools/lune/guardrails", "--legacy-check", dir })
		expect(r.stdout).never.toContain("more than the baseline")
		expect(r.ok).toBe(true)
		-- a real new statement still grows the count
		write(dir, OLD, WRAPPED .. 'local c = ProfileStore.New("C")\n')
		r = isolated("lune", { "run", "tools/lune/guardrails", "--legacy-check", dir })
		expect(r.stdout).toContain("2 [purchases] findings, more than the baseline's 1")
		expect(r.ok).toBe(false)
		cleanup()
	end)
end)
