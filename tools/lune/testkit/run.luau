--!nocheck
--[[
	Test runner: finds every *.spec.luau under packages/ and games/ (or the paths given as args)
	and runs it through the harness. Exit code 1 on any failure.

	Usage (from repo root): lune run tools/lune/testkit/run [path ...]
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Harness = require("./harness")

local SKIP_DIRS =
	{ Packages = true, ServerPackages = true, DevPackages = true, [".git"] = true, node_modules = true }

local function collect(dir: string, out: { string })
	if fs.isFile(dir) then
		if string.match(dir, "%.spec%.luau$") then
			table.insert(out, dir)
		end
		return
	end
	if not fs.isDir(dir) then
		return
	end
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			if not SKIP_DIRS[entry] then
				collect(path, out)
			end
		elseif string.match(entry, "%.spec%.luau$") then
			table.insert(out, path)
		end
	end
end

local roots = process.args
if #roots == 0 then
	roots = { "packages", "games", "tools" }
end

local specs = {}
for _, root in roots do
	collect(root, specs)
end
table.sort(specs)

local totalPassed, totalFailed = 0, 0
local allFailures = {}
for _, spec in specs do
	local passed, failed, failures = Harness.runSpec(spec)
	totalPassed += passed
	totalFailed += failed
	print(
		string.format("%s %-70s %d passed, %d failed", failed == 0 and "PASS" or "FAIL", spec, passed, failed)
	)
	for _, f in failures do
		table.insert(allFailures, f)
	end
end

if #allFailures > 0 then
	print("\nFailures:")
	for _, f in allFailures do
		print("  - " .. f)
	end
end

print(string.format("\n%d spec files, %d tests passed, %d failed", #specs, totalPassed, totalFailed))
if #specs == 0 then
	print("No spec files found.")
	process.exit(1)
end
process.exit(if totalFailed > 0 then 1 else 0)
