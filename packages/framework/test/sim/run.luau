--!nocheck
--[[
	Runner for the simulation files tools/test does NOT pick up (tools/test-sim):
	  lune run packages/framework/test/sim/run              every sim *.spec.luau + *.slow.luau
	  lune run packages/framework/test/sim/run --pending    ... plus *.pending.luau (fails on stubs)
	  lune run packages/framework/test/sim/run <file> ...   just these files
	Uses the same harness as tools/test (Harness.runSpec), so the files get the same globals.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Harness = require("../../../../tools/lune/testkit/harness")

local DIR = "packages/framework/test/sim"

local pending = false
local files = {}
for _, arg in process.args do
	if arg == "--pending" then
		pending = true
	else
		table.insert(files, arg)
	end
end

if #files == 0 then
	for _, entry in fs.readDir(DIR) do
		local wanted = string.match(entry, "%.spec%.luau$")
			or string.match(entry, "%.slow%.luau$")
			or (pending and string.match(entry, "%.pending%.luau$"))
		if wanted then
			table.insert(files, DIR .. "/" .. entry)
		end
	end
	table.sort(files)
end

local totalPassed, totalFailed = 0, 0
local failures = {}
for _, file in files do
	local started = os.clock()
	local passed, failed, list = Harness.runSpec(file)
	totalPassed += passed
	totalFailed += failed
	print(
		string.format(
			"%s %-62s %d passed, %d failed (%.2fs)",
			failed == 0 and "PASS" or "FAIL",
			file,
			passed,
			failed,
			os.clock() - started
		)
	)
	for _, f in list do
		table.insert(failures, f)
	end
end

if #failures > 0 then
	print("\nFailures:")
	for _, f in failures do
		print("  - " .. f)
	end
end
print(string.format("\n%d sim files, %d tests passed, %d failed", #files, totalPassed, totalFailed))
process.exit(if totalFailed > 0 or #files == 0 then 1 else 0)
