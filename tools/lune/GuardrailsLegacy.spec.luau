--!nocheck
-- (StudWork v1.6.0) transitional guardrails end to end (docs/framework/adopting.md §5): throwaway
-- git repos of an adopted project, checked with `guardrails --legacy-check <dir>` (scan the root
-- game + apply studwork-legacy.json + the git-anchored baseline). The repos live under
-- $GUARD_TEST_TMP (or $TMPDIR) and are removed afterwards; git runs with a throwaway identity
-- passed per command (no config is written).
local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")
local process = luneRequire("@lune/process")
local serde = luneRequire("@lune/serde")

local TMP_BASE = process.env.GUARD_TEST_TMP or process.env.TMPDIR or "/tmp"
TMP_BASE = string.gsub(TMP_BASE, "/+$", "")
local SAVE = "src/server/Save.server.luau"
local SAVE_SRC = table.concat({
	'local DSS = game:GetService("DataStoreService")',
	'local store = DSS:GetDataStore("Old")',
	"local price = 500",
	"return store",
}, "\n") .. "\n"

local seq = 0
local made = {}

-- A git hook (pre-commit runs these specs) exports GIT_DIR / GIT_INDEX_FILE / GIT_AUTHOR_*:
-- inherited, they would point every command at the OUTER repository. Strip them for every
-- process that touches a throwaway repo (git here, and the guardrails CLI's own git calls).
local GIT_ENV = {
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
}
local function isolated(cmd, args)
	local full = {}
	for _, v in GIT_ENV do
		table.insert(full, "-u")
		table.insert(full, v)
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

-- Refuses to go on unless `dir` is its own repository (never the outer one).
local function assertOwnRepo(dir)
	local top = string.gsub(git(dir, { "rev-parse", "--show-toplevel" }), "%s+$", "")
	local want = string.gsub(process.exec("sh", { "-c", 'cd "$1" && pwd -P', "sh", dir }).stdout, "%s+$", "")
	assert(top == want, `throwaway repo check failed: {top} is not {want}`)
end

local function write(dir, path, text)
	local parent = string.match(dir .. "/" .. path, "^(.*)/[^/]+$")
	fs.writeDir(parent)
	fs.writeFile(dir .. "/" .. path, text)
end

local function json(v)
	return serde.encode("json", v, true)
end

local BASE = { files = { [SAVE] = { purchases = 1, numbers = 1 } } }

-- An adopted project: Config, the old save file, studwork.json (+ baseline) and the list.
local function project(o)
	o = o or {}
	seq += 1
	local dir = `{TMP_BASE}/studwork-guard-legacy-{os.time()}-{seq}`
	if fs.isDir(dir) then
		fs.removeDir(dir)
	end
	fs.writeDir(dir)
	table.insert(made, dir)
	git(dir, { "init", "-q" })
	assertOwnRepo(dir)
	write(dir, "src/shared/Config.luau", "return {\n\tmodules = {},\n}\n")
	write(dir, SAVE, o.save or SAVE_SRC)
	write(
		dir,
		"studwork.json",
		json({
			layout = "single-game",
			framework = "studwork",
			adopted = if o.adopted == nil then true else o.adopted,
			legacyBaseline = o.baseline or BASE,
		})
	)
	write(
		dir,
		"studwork-legacy.json",
		json({
			files = o.entries
				or { { path = SAVE, checks = { "purchases", "numbers" }, reason = "old save code" } },
		})
	)
	if o.commit ~= false then
		git(dir, { "add", "." })
		git(dir, { "commit", "-q", "-m", "adopt" })
	end
	return dir
end

local function check(dir)
	local r = isolated("lune", { "run", "tools/lune/guardrails", "--legacy-check", dir })
	return r.ok, r.stdout .. r.stderr
end

local function cleanup()
	for _, d in made do
		pcall(fs.removeDir, d)
	end
	made = {}
end

describe("guardrails: transitional (studwork-legacy.json)", function()
	it("listed findings within the baseline are warnings with the reason", function()
		local ok, out = check(project())
		expect(out).toContain("warning: [legacy] " .. SAVE .. ":1: [purchases]")
		expect(out).toContain("(legacy: old save code)")
		expect(ok).toBe(true)
		cleanup()
	end)

	it("a textfilter finding in a listed file is downgraded like the other checks (v1.7.0)", function()
		local sign = "src/server/Sign.server.luau"
		local dir = project({
			commit = false,
			baseline = { files = { [SAVE] = { purchases = 1, numbers = 1 }, [sign] = { textfilter = 1 } } },
			entries = {
				{ path = SAVE, checks = { "purchases", "numbers" }, reason = "old save code" },
				{ path = sign, checks = { "textfilter" }, reason = "old sign code" },
			},
		})
		write(dir, sign, table.concat({
			"return {",
			"\tactions = {",
			"\t\trename = { handler = function(player, name: string)",
			'\t\t\tctx.replicate.setAll("sign", name)',
			"\t\tend },",
			"\t},",
			"}",
		}, "\n") .. "\n")
		git(dir, { "add", "." })
		git(dir, { "commit", "-q", "-m", "adopt" })
		local ok, out = check(dir)
		expect(out).toContain("warning: [legacy] " .. sign .. ":4: [textfilter] player text 'name'")
		expect(out).toContain("(legacy: old sign code)")
		expect(ok).toBe(true)
		-- unlisted, the same finding fails
		write(
			dir,
			"src/server/Other.server.luau",
			"return {\n\tactions = { x = function(player, s) ctx.net.fireAll(E, s) end },\n}\n"
		)
		local ok2, out2 = check(dir)
		expect(ok2).toBe(false)
		expect(out2).toContain("src/server/Other.server.luau:2: [textfilter]")
		cleanup()
	end)

	it("--raw ignores the list and prints every finding", function()
		local dir = project()
		local r = isolated("lune", { "run", "tools/lune/guardrails", "--raw", dir })
		expect(r.ok).toBe(false)
		expect(r.stdout).toContain(":1: [purchases]")
		expect(r.stdout).never.toContain("[legacy]")
		cleanup()
	end)

	it("a growing count fails (no new DataStore code in a listed file)", function()
		local dir = project()
		write(dir, SAVE, SAVE_SRC .. 'local again = game:GetService("DataStoreService")\n')
		local ok, out = check(dir)
		expect(ok).toBe(false)
		expect(out).toContain("more than the baseline's 1")
		cleanup()
	end)

	it("an unlisted check in a listed file and an unlisted file still fail", function()
		local dir = project()
		write(dir, "src/server/New.server.luau", 'local DSS = game:GetService("DataStoreService")\n')
		write(dir, SAVE, SAVE_SRC .. 'local e = Instance.new("RemoteEvent")\n')
		local ok, out = check(dir)
		expect(ok).toBe(false)
		expect(out).toContain("src/server/New.server.luau:1: [purchases]")
		expect(out).toContain(SAVE .. ":5: [remotes]")
		cleanup()
	end)

	it("ProcessReceipt in a listed file still fails", function()
		local dir = project()
		write(
			dir,
			SAVE,
			SAVE_SRC
				.. 'local MPS = game:GetService("MarketplaceService")\nMPS.ProcessReceipt = function() end\n'
		)
		local ok, out = check(dir)
		expect(ok).toBe(false)
		expect(out).toContain(
			":6: [purchases] only the framework Shop assigns MarketplaceService.ProcessReceipt"
		)
		cleanup()
	end)

	it("an edited baseline (uncommitted or committed later) fails against the first commit", function()
		local dir = project()
		local raised = { files = { [SAVE] = { purchases = 5, numbers = 1 } } }
		write(dir, "studwork.json", json({ layout = "single-game", adopted = true, legacyBaseline = raised }))
		local ok, out = check(dir)
		expect(ok).toBe(false)
		expect(out).toContain("differs from the one in the commit that first added studwork.json")
		git(dir, { "commit", "-q", "-am", "raise" })
		ok = check(dir)
		expect(ok).toBe(false)
		cleanup()
	end)

	it("deleting and re-adding studwork.json doesn't move the anchor", function()
		local dir = project()
		git(dir, { "rm", "-q", "studwork.json" })
		git(dir, { "commit", "-q", "-m", "drop" })
		local raised = { files = { [SAVE] = { purchases = 9, numbers = 1 } } }
		write(dir, "studwork.json", json({ layout = "single-game", adopted = true, legacyBaseline = raised }))
		git(dir, { "add", "studwork.json" })
		git(dir, { "commit", "-q", "-m", "re-add" })
		local ok, out = check(dir)
		expect(ok).toBe(false)
		expect(out).toContain("differs from the one in the commit that first added studwork.json")
		cleanup()
	end)

	it("a shallow clone fails closed", function()
		local src = project()
		write(src, "README.md", "x\n")
		git(src, { "add", "." })
		git(src, { "commit", "-q", "-m", "second" })
		seq += 1
		local clone = `{TMP_BASE}/studwork-guard-legacy-{os.time()}-{seq}`
		table.insert(made, clone)
		local r = isolated("git", { "clone", "-q", "--depth", "1", "file://" .. src, clone })
		expect(r.ok).toBe(true)
		local ok, out = check(clone)
		expect(ok).toBe(false)
		expect(out).toContain("shallow clone")
		cleanup()
	end)

	it("before the first commit nothing is compared, and lint says so", function()
		local ok, out = check(project({ commit = false }))
		expect(out).toContain("isn't committed yet")
		expect(ok).toBe(true)
		cleanup()
	end)

	it("a new file, a new check, a missing reason or a stale entry fails", function()
		local _, out = check(project({
			entries = {
				{ path = SAVE, checks = { "purchases", "numbers", "remotes" }, reason = "" },
				{ path = "src/server/Gone.luau", checks = { "numbers" }, reason = "r" },
			},
		}))
		expect(out).toContain("check remotes isn't in the baseline")
		expect(out).toContain("needs a reason")
		expect(out).toContain("no longer exists")
		cleanup()
		local dir = project({ save = "return 1\n" })
		local ok, out2 = check(dir)
		expect(out2).toContain("nothing legacy left")
		expect(ok).toBe(true)
		cleanup()
	end)

	it("evasions: ./ prefix, different case, a symlink", function()
		for path, needle in
			{
				["./" .. SAVE] = "exactly as it is on disk",
				["src/server/save.server.luau"] = "case doesn't match",
				["src/server/Link.server.luau"] = "symlink can't be listed",
			}
		do
			local dir =
				project({ entries = { { path = path, checks = { "purchases", "numbers" }, reason = "r" } } })
			process.exec("ln", { "-s", "Save.server.luau", dir .. "/src/server/Link.server.luau" })
			local ok, out = check(dir)
			expect(ok).toBe(false)
			expect(out).toContain(needle)
			expect(out).toContain(SAVE .. ":1: [purchases]") -- the real finding still fails
			cleanup()
		end
	end)

	it("a list in a project that isn't adopted is an error", function()
		local ok, out = check(project({ adopted = false }))
		expect(ok).toBe(false)
		expect(out).toContain("only adopted projects may have a legacy list")
		cleanup()
	end)

	it("--self-test plants every transitional rule", function()
		local source = fs.readFile("tools/lune/guardrails.luau")
		for _, case in
			{
				"legacy: growing count",
				"legacy: new file",
				"legacy: new check",
				"legacy: missing reason",
				"legacy: stale entry (file gone)",
				"legacy: edited baseline",
				"legacy: re-added studwork.json (anchor = first add)",
				"legacy: ProcessReceipt in a listed file still fails",
				"legacy: list in a non-adopted project",
				"legacy: a ./ prefix",
				"legacy: a different case",
				"legacy: a symlink",
				"legacy: shallow clone fails closed",
			}
		do
			expect(string.find(source, '"' .. case .. '"', 1, true)).never.toBeNil()
		end
	end)
end)
