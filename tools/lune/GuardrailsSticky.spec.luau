--!nocheck
-- (StudWork v1.6.1) the sticky adopted marker and `guardrails --anchor-remote` end to end
-- (docs/framework/adopting.md §5, docs/framework/guardrails.md): throwaway git repos of an adopted
-- project under $GUARD_TEST_TMP (or $TMPDIR), checked with `guardrails --legacy-check <dir>` and
-- `guardrails --anchor-remote <dir>`. git runs with a throwaway identity passed per command (no
-- config is written); every process touching a throwaway repo runs without the GIT_* variables a
-- hook exports. A "remote" is a local remote-tracking ref (refs/remotes/origin/...) or a local
-- clone: nothing is fetched from or pushed to a network.
local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")
local process = luneRequire("@lune/process")
local serde = luneRequire("@lune/serde")

local TMP_BASE = process.env.GUARD_TEST_TMP or process.env.TMPDIR or "/tmp"
TMP_BASE = string.gsub(TMP_BASE, "/+$", "")
local BRIDGE = "src/server/Bridge.luau"
-- an onLegacyProduct bridge: tools/adopt --verify fails while it's there (no guardrail finding)
local BRIDGE_SRC =
	"local M = {}\nfunction M.init(ctx)\n\tctx.shop.onLegacyProduct(123, function()\n\t\treturn true\n\tend)\nend\nreturn M\n"
local PROJECT_JSON =
	'{ "name": "g", "tree": { "$className": "DataModel", "ReplicatedStorage": { "Shared": { "$path": "src/shared" } } } }\n'

local seq = 0
local made = {}

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
		"-c",
		"init.defaultBranch=main",
	}
	for _, a in args do
		table.insert(full, a)
	end
	local r = isolated("git", full)
	assert(r.ok, "git " .. table.concat(args, " ") .. ": " .. r.stderr)
	return r.stdout
end

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

local function marker(o)
	local m =
		{ layout = "single-game", framework = "studwork", legacyBaseline = o.baseline or { files = {} } }
	for k, v in o.extra or {} do
		m[k] = v
	end
	if o.adopted ~= nil then
		m.adopted = o.adopted
	end
	return json(m)
end

local function newDir()
	seq += 1
	local dir = `{TMP_BASE}/studwork-guard-sticky-{os.time()}-{seq}`
	if fs.isDir(dir) then
		fs.removeDir(dir)
	end
	fs.writeDir(dir)
	table.insert(made, dir)
	return dir
end

-- An adopted project (clean: no guardrail finding, --verify passes), committed once.
local function project(o)
	o = o or {}
	local dir = newDir()
	git(dir, { "init", "-q" })
	assertOwnRepo(dir)
	write(dir, "default.project.json", PROJECT_JSON)
	write(dir, "src/shared/Config.luau", "return {\n\tmodules = {},\n}\n")
	write(
		dir,
		"studwork.json",
		marker({ adopted = if o.adopted == nil then true else o.adopted, baseline = o.baseline })
	)
	write(dir, "studwork-legacy.json", json({ files = {} }))
	git(dir, { "add", "." })
	git(dir, { "commit", "-q", "-m", "adopt" })
	return dir
end

local function commitAll(dir, msg)
	assertOwnRepo(dir)
	git(dir, { "add", "-A" })
	git(dir, { "commit", "-q", "-m", msg })
end

local function check(dir)
	local r = isolated("lune", { "run", "tools/lune/guardrails", "--legacy-check", dir })
	return r.ok, r.stdout .. r.stderr
end

local function remote(dir)
	local r = isolated("lune", { "run", "tools/lune/guardrails", "--anchor-remote", dir })
	return r.ok, r.stdout .. r.stderr
end

local function cleanup()
	for _, d in made do
		pcall(fs.removeDir, d)
	end
	made = {}
end

describe("guardrails: the adopted marker is sticky (v1.6.1)", function()
	it("flag removed while tools/adopt --verify fails: lint fails, naming the commit", function()
		local dir = project()
		write(dir, BRIDGE, BRIDGE_SRC)
		write(dir, "studwork.json", marker({}))
		local ok, out = check(dir)
		expect(ok).toBe(false)
		expect(out).toContain('studwork.json no longer says "adopted": true')
		expect(out).toContain("onLegacyProduct left")
		cleanup()
	end)

	it("flag removed after tools/adopt --verify passes: lint passes (graduated)", function()
		local dir = project()
		write(dir, "studwork.json", marker({}))
		local ok, out = check(dir)
		expect(out).toContain("graduated")
		expect(ok).toBe(true)
		cleanup()
	end)

	it("flag removed and studwork-legacy.json deleted: still fails while --verify fails", function()
		local dir = project()
		write(dir, BRIDGE, BRIDGE_SRC)
		write(dir, "studwork.json", marker({}))
		fs.removeFile(dir .. "/studwork-legacy.json")
		commitAll(dir, "drop the flag and the list")
		local ok, out = check(dir)
		expect(ok).toBe(false)
		expect(out).toContain("no longer says")
		cleanup()
	end)

	it("the flag still set: lint doesn't run --verify", function()
		local dir = project()
		write(dir, BRIDGE, BRIDGE_SRC)
		local ok, out = check(dir)
		expect(out).never.toContain("no longer says")
		expect(ok).toBe(true)
		cleanup()
	end)

	it('evasions in the working copy: "adopted": "true", "adopted": false, "Adopted": true', function()
		for _, extra in { { adopted = "true" }, { adopted = false }, { Adopted = true } } do
			local dir = project()
			write(dir, BRIDGE, BRIDGE_SRC)
			write(dir, "studwork.json", marker({ extra = extra }))
			local ok, out = check(dir)
			expect(ok).toBe(false)
			expect(out).toContain("no longer says")
			cleanup()
		end
	end)

	it("studwork.json deleted and re-added without the flag stays adopted", function()
		local dir = project()
		fs.removeFile(dir .. "/studwork.json")
		commitAll(dir, "delete the marker")
		write(dir, "studwork.json", marker({}))
		write(dir, BRIDGE, BRIDGE_SRC)
		commitAll(dir, "re-add it")
		local ok, out = check(dir)
		expect(ok).toBe(false)
		expect(out).toContain("no longer says")
		cleanup()
	end)

	it("a commit that adds the flag and a later one that removes it: still adopted", function()
		local dir = project({ adopted = false })
		write(dir, "studwork.json", marker({ adopted = true }))
		commitAll(dir, "adopt later")
		write(dir, "studwork.json", marker({}))
		write(dir, BRIDGE, BRIDGE_SRC)
		commitAll(dir, "remove it again")
		local ok, out = check(dir)
		expect(ok).toBe(false)
		expect(out).toContain("no longer says")
		cleanup()
	end)

	it("a project never adopted is unaffected", function()
		local dir = project({ adopted = false })
		fs.removeFile(dir .. "/studwork-legacy.json")
		write(dir, BRIDGE, BRIDGE_SRC)
		local ok, out = check(dir)
		expect(out).never.toContain("no longer says")
		expect(ok).toBe(true)
		cleanup()
	end)
end)

describe("guardrails --anchor-remote (v1.6.1)", function()
	local BASE1 = { files = { ["src/server/Old.luau"] = { purchases = 1 } } }
	local BASE2 = { files = { ["src/server/Old.luau"] = { purchases = 9 } } }

	-- HEAD becomes a new root commit (a rewritten history); the old history stays reachable
	-- only through `ref`
	local function rewrite(dir, ref, o)
		local old = string.gsub(git(dir, { "rev-parse", "HEAD" }), "%s+$", "")
		git(dir, { "update-ref", ref, old })
		git(dir, { "checkout", "-q", "--orphan", "rewritten" })
		if o.studwork == false then
			git(dir, { "rm", "-q", "--cached", "studwork.json" })
			fs.removeFile(dir .. "/studwork.json")
		else
			write(dir, "studwork.json", marker({ adopted = o.adopted, baseline = o.baseline }))
		end
		commitAll(dir, "rewritten root")
	end

	it("no remote default branch: a note, and it passes (optional)", function()
		local dir = project({ baseline = BASE1 })
		local ok, out = remote(dir)
		expect(out).toContain("no remote default branch")
		expect(ok).toBe(true)
		cleanup()
	end)

	it("the same anchor and marker as origin/main: passes", function()
		local dir = project({ baseline = BASE1 })
		git(dir, { "update-ref", "refs/remotes/origin/main", "HEAD" })
		write(dir, "src/server/New.luau", "return 1\n")
		commitAll(dir, "local work ahead of the remote")
		local ok, out = remote(dir)
		expect(out).toContain("clean")
		expect(ok).toBe(true)
		cleanup()
	end)

	it("a local history rewrite with a bigger baseline while origin/main keeps the old one: fails", function()
		local dir = project({ baseline = BASE1 })
		rewrite(dir, "refs/remotes/origin/main", { adopted = true, baseline = BASE2 })
		-- the local check alone can't see it (the new root IS the first commit now)
		local okLocal = check(dir)
		expect(okLocal).toBe(true)
		local ok, out = remote(dir)
		expect(ok).toBe(false)
		expect(out).toContain("legacyBaseline in the first commit that added studwork.json differs")
		cleanup()
	end)

	it("the remote has an anchor, the local history has none: fails", function()
		local dir = project({ baseline = BASE1 })
		rewrite(dir, "refs/remotes/origin/main", { studwork = false })
		local ok, out = remote(dir)
		expect(ok).toBe(false)
		expect(out).toContain("no commit that added studwork.json")
		cleanup()
	end)

	it("the adopted marker dropped from a rewritten local history: fails", function()
		local dir = project({ baseline = BASE1 })
		rewrite(dir, "refs/remotes/origin/main", { baseline = BASE1 })
		local ok, out = remote(dir)
		expect(ok).toBe(false)
		expect(out).toContain('"adopted": true in its history')
		cleanup()
	end)

	it("refs/remotes/origin/HEAD wins over origin/main", function()
		local dir = project({ baseline = BASE1 })
		local good = string.gsub(git(dir, { "rev-parse", "HEAD" }), "%s+$", "")
		rewrite(dir, "refs/remotes/origin/main", { adopted = true, baseline = BASE2 })
		-- origin/HEAD -> origin/trunk, whose history matches the local one
		local head = string.gsub(git(dir, { "rev-parse", "HEAD" }), "%s+$", "")
		git(dir, { "update-ref", "refs/remotes/origin/trunk", head })
		git(dir, { "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk" })
		local ok, out = remote(dir)
		expect(out).toContain("clean")
		expect(ok).toBe(true)
		-- pointed at the old history it fails
		git(dir, { "update-ref", "refs/remotes/origin/trunk", good })
		local ok2 = remote(dir)
		expect(ok2).toBe(false)
		cleanup()
	end)

	it("a shallow clone fails closed, asking for the full history", function()
		local src = project({ baseline = BASE1 })
		write(src, "src/server/New.luau", "return 1\n")
		commitAll(src, "second")
		local dir = newDir()
		fs.removeDir(dir)
		local r = isolated("git", { "clone", "-q", "--depth", "1", "file://" .. src, dir })
		assert(r.ok, r.stderr)
		assertOwnRepo(dir)
		local ok, out = remote(dir)
		expect(ok).toBe(false)
		expect(out).toContain("fetch-depth: 0")
		cleanup()
	end)
end)
