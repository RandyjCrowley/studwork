--!nocheck
-- (v1.6.0 dogfood) The test runner never ends silently: a spec whose test yields and is never
-- resumed (a raw coroutine.yield, a sim task.wait on the spec's own thread) used to suspend the
-- runner's main thread, so Lune exited 0 with no output. Each planted spec runs in a child
-- `lune run tools/lune/testkit/run <dir>` over a throwaway folder under $TMPDIR.
local PathUtil = require("tools/lune/testkit/pathutil.luau")
local lune = (getmetatable(getfenv(1)) :: any).__index.require
local fs = lune("@lune/fs")
local process = lune("@lune/process")

local function tmpDir(): string
	local tmp = process.env.TMPDIR -- unset on CI; an empty value counts as unset
	local base = if tmp and tmp ~= "" then tmp else PathUtil.join(process.cwd, ".cache")
	local dir = PathUtil.join(base, "studwork-runner-spec-" .. tostring(math.random(1, 1e9)))
	fs.writeDir(dir)
	return dir
end

local function runPlanted(files: { [string]: string })
	local dir = tmpDir()
	for name, text in files do
		fs.writeFile(dir .. "/" .. name, text)
	end
	local env = table.clone(process.env)
	env.STUDWORK_TEST_TIMEOUT = "1"
	local res = process.exec("lune", { "run", "tools/lune/testkit/run", dir }, { env = env })
	pcall(fs.removeDir, dir)
	return res.code, res.stdout .. res.stderr
end

local PASSING = [[
describe("fine", function()
	it("passes", function()
		expect(1).toBe(1)
	end)
end)
]]

describe("tools/test: a stalled spec is a FAIL, never a silent exit 0", function()
	it("a raw coroutine.yield in a test fails with a reason and the summary still prints", function()
		local code, out = runPlanted({
			["A.spec.luau"] = PASSING,
			["B.spec.luau"] = [[
describe("stall", function()
	it("yields forever", function()
		coroutine.yield()
	end)
	it("runs after the stalled test", function()
		expect(true).toBe(true)
	end)
end)
]],
		})
		expect(code).toBe(1)
		expect(out).toContain("PASS ")
		expect(out).toContain("FAIL ")
		expect(out).toContain("stall > yields forever")
		expect(out).toContain("the test never completed")
		expect(out).toContain("2 spec files, 2 tests passed, 1 failed")
	end)

	it("a yield at load time (outside any it) fails the file", function()
		local code, out = runPlanted({ ["C.spec.luau"] = "coroutine.yield()\n" })
		expect(code).toBe(1)
		expect(out).toContain("(load): the test never completed")
		expect(out).toContain("1 spec files, 0 tests passed, 1 failed")
	end)

	it("Lune's own yields (task.wait) still work inside a test", function()
		local code, out = runPlanted({
			["D.spec.luau"] = [[
it("waits", function()
	task.wait(0.02)
	expect(1).toBe(1)
end)
]],
		})
		expect(code).toBe(0)
		expect(out).toContain("1 spec files, 1 tests passed, 0 failed")
	end)
end)

describe("Harness.guarded keeps pcall's behaviour", function()
	it("a failing assertion is still reported with its message", function()
		local code, out = runPlanted({
			["E.spec.luau"] = [[
it("fails", function()
	error("planted failure", 0)
end)
]],
		})
		expect(code).toBe(1)
		expect(out).toContain("planted failure")
		expect(out).toContain("1 spec files, 0 tests passed, 1 failed")
	end)
end)
