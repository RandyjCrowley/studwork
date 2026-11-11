--!nocheck
--[[
	tools/lune/adopt (StudWork v1.6.0): the Lune side of tools/adopt --audit / --from-place /
	--verify (docs/framework/adopting.md §1). tools/adopt (bash) runs it from the project root;
	user paths are relative to $STUDWORK_CALLER_PWD (where the command was typed).

	  --audit <project|place> [...]     writes studwork-adopt-report.json + .md into the first
	                                    project's root (or next to the place file). Exit 1 if a
	                                    project can't be read.
	  --from-place <file> [--out <dir>] the code containers -> a Rojo project in --out (default:
	                                    the place file's folder) + its audit report. Exit 1 on any
	                                    refusal (nothing written then).
	  --verify <project>                re-runs the audit (writes nothing) and exits 1 while
	                                    anything unsafe for going live is left, one line each.
	Usage errors exit 2. Never touches live data, never publishes.
]]
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local Roots = require("./Roots")
local Scan = require("./AdoptScan")
local Audit = require("./AdoptAudit")
local Place = require("./AdoptPlace")

local USAGE =
	"usage: tools/adopt --audit <project|place> [...] | --from-place <file> [--out <dir>] | --verify <project>"

local function studworkVersion(): string
	local ok, text = pcall(fs.readFile, Roots.core("packages/framework/shared/init.luau"))
	local v = ok and string.match(text, 'StudWork%.VERSION%s*=%s*"([^"]+)"')
	return v or "1.6.0"
end

local env = {
	fs = fs,
	process = process,
	roblox = roblox,
	serde = serde,
	Scan = Scan,
	Audit = Audit,
	version = studworkVersion(),
}

-- Where the command was typed. tools/_common.sh sets STUDWORK_CALLER_PWD; until it exports it,
-- OLDPWD is the same folder: _common.sh's `cd "$PROJECT_ROOT"` always sets it to the caller's
-- folder (bash exports it when the caller's environment had it). Last resort: the project root.
local function callerFolder(): string
	for _, v in { process.env.STUDWORK_CALLER_PWD, process.env.OLDPWD } do
		if type(v) == "string" and string.sub(v, 1, 1) == "/" and fs.isDir(v) then
			return v
		end
	end
	return process.cwd
end
local callerPwd = Audit.normalize(callerFolder())
local function resolve(path: string): string
	if string.sub(path, 1, 1) == "/" then
		return Audit.normalize(path)
	end
	return Audit.join(callerPwd, path)
end
-- how to show a path to the user: relative to where they typed the command
local function show(abs: string): string
	return Audit.relative(callerPwd, abs)
end

local function fail(msg: string, code: number)
	stdio.ewrite("error: " .. msg .. "\n")
	process.exit(code)
end

local function usage(msg: string?)
	if msg then
		stdio.ewrite("error: " .. msg .. "\n")
	end
	stdio.ewrite(USAGE .. "\n")
	process.exit(2)
end

local function summary(report)
	local c = Audit.counts(report)
	print(
		string.format(
			"  %d scripts, %d DataStores, %d save-library uses, %d products, %d remotes, %d left in the place",
			#report.scripts,
			#report.datastores,
			#report.libraries,
			#report.purchases.products,
			#report.remotes,
			#report.notExtracted
		)
	)
	print(
		string.format("  risks: %d critical, %d high, %d medium, %d low", c.critical, c.high, c.medium, c.low)
	)
	print(string.format("  plan: %d steps", #report.plan))
end

local args = process.args
local mode = args[1]
if mode == "--audit" then
	if #args < 2 then
		usage("--audit needs at least one project or place file")
	end
	local paths = {}
	for i = 2, #args do
		if string.sub(args[i], 1, 2) == "--" then
			usage("unknown option " .. args[i])
		end
		table.insert(paths, resolve(args[i]))
	end
	local report, err, dir = Audit.run(env, paths, { write = true })
	if report == nil then
		fail(tostring(err), 1)
	end
	print(
		"tools/adopt --audit: wrote "
			.. show(dir .. "/" .. Audit.REPORT_JSON)
			.. " and "
			.. show(dir .. "/" .. Audit.REPORT_MD)
	)
	summary(report)
	process.exit(0)
elseif mode == "--from-place" then
	local file, out = nil, nil
	local i = 2
	while i <= #args do
		local a = args[i]
		if a == "--out" then
			out = args[i + 1]
			if out == nil then
				usage("--out needs a folder")
			end
			i += 2
		elseif string.sub(a, 1, 2) == "--" then
			usage("unknown option " .. a)
		elseif file == nil then
			file = a
			i += 1
		else
			usage("one place file only")
		end
	end
	if file == nil then
		usage("--from-place needs a place file")
	end
	local placeAbs = resolve(file)
	local outAbs = if out then resolve(out) else Audit.dirname(placeAbs)
	local res, err = Place.run(env, placeAbs, outAbs)
	if res == nil then
		fail(tostring(err), 1)
	end
	print(string.format("tools/adopt --from-place: wrote %d files into %s", #res.files, show(res.out)))
	for _, c in res.collisions do
		print("  name collision: " .. c.name .. " -> " .. c.path)
	end
	for _, r in res.renamed do
		print(
			"  renamed: "
				.. r.name
				.. " -> "
				.. r.path
				.. " (Rojo syncs the file name; update code that finds it by name)"
		)
	end
	for _, s in res.stale do
		print("  no longer generated (left as is): " .. s)
	end
	print("  report: " .. show(res.out .. "/" .. Audit.REPORT_MD))
	summary(res.report)
	process.exit(0)
elseif mode == "--verify" then
	if #args ~= 2 then
		usage("--verify needs exactly one project")
	end
	local issues, err = Audit.verifyIssues(env, resolve(args[2]))
	if issues == nil then
		fail(tostring(err), 1)
	end
	for _, line in issues do
		print(line)
	end
	if #issues > 0 then
		print(string.format("tools/adopt --verify: %d issue(s) left; not ready to go live", #issues))
		process.exit(1)
	end
	print("tools/adopt --verify: clean")
	process.exit(0)
else
	usage(nil)
end
