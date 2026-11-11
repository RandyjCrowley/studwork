--!nocheck
-- (StudWork v1.6.0) testkit/harness: which default.project.json maps a spec (Harness.findGameDir).
-- The closest folder above the spec with one wins; when none has one, the project root's
-- ./default.project.json (a single-game project: the root IS the game). The core repo and a games
-- repo have no root project file, so their mapping doesn't change. The harness is a Lune script
-- (it can't load inside a spec), so a probe script in a throwaway folder under $GUARD_TEST_TMP
-- (or $TMPDIR) requires it and prints the answers.
local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")
local process = luneRequire("@lune/process")

local TMP_BASE = process.env.GUARD_TEST_TMP or process.env.TMPDIR or "/tmp"
TMP_BASE = string.gsub(TMP_BASE, "/+$", "")

local function real(dir)
	return (string.gsub(process.exec("sh", { "-c", 'cd "$1" && pwd -P', "sh", dir }).stdout, "%s+$", ""))
end

-- runs `body` (Luau using `H` = the harness module) in a probe script; returns its stdout
local function probe(body)
	local dir = `{TMP_BASE}/studwork-harness-probe-{os.time()}-{math.random(1, 1e6)}`
	fs.writeDir(dir)
	-- a symlink to this repo's tools/lune: the probe requires the harness relative to itself
	local ln = process.exec("ln", { "-s", real(".") .. "/tools/lune", dir .. "/lune" })
	assert(ln.ok, "ln: " .. ln.stderr)
	fs.writeFile(dir .. "/probe.luau", `local H = require("./lune/testkit/harness")\n{body}\n`)
	local r = process.exec("lune", { "run", dir .. "/probe.luau" })
	pcall(fs.removeFile, dir .. "/lune")
	pcall(fs.removeDir, dir)
	assert(r.ok, "probe failed: " .. r.stderr)
	return (string.gsub(r.stdout, "%s+$", ""))
end

local HAS = [[
local function has(set)
	return function(p) return set[p] == true end
end
local function show(v) print(if v == nil then "nil" else v) end
]]

describe("Harness.findGameDir", function()
	it("the closest folder with a default.project.json wins over the root", function()
		expect(probe(HAS .. [[
show(H.findGameDir("games/g/modules/M/x.spec.luau", has({
	["games/g/default.project.json"] = true, ["default.project.json"] = true })))
]])).toBe("games/g")
	end)

	it("falls back to the project root's default.project.json (single-game project)", function()
		expect(probe(HAS .. [[
show(H.findGameDir("modules/Game/module.spec.luau", has({ ["default.project.json"] = true })))
show(H.findGameDir("x.spec.luau", has({ ["default.project.json"] = true })))
]])).toBe(".\n.")
	end)

	it("no project file anywhere (core repo, games repo root): nil, the base mapping", function()
		expect(probe(HAS .. [[
show(H.findGameDir("packages/framework/test/X.spec.luau", has({})))
show(H.findGameDir(nil, has({ ["default.project.json"] = true })))
show(H.findGameDir("/abs/x.spec.luau", has({ ["default.project.json"] = true })))
]])).toBe("nil\nnil\nnil")
	end)

	it("this repo has no root default.project.json, so its specs keep their mapping", function()
		expect(fs.isFile("default.project.json")).toBe(false)
	end)
end)
