--!nocheck
--[[
	tools/lune/publish-gate: CLI wrapper around PublishGate (pure) for tools/publish.

	  lune run tools/lune/publish-gate check <name> <test|live> <dryRun 0|1> <keyPresent 0|1>
	      gathers git facts (HEAD, dirty build paths, test-commit equivalence), prints warnings
	      and errors, exits 1 when the publish must be refused.
	  lune run tools/lune/publish-gate url <name> <test|live>
	  lune run tools/lune/publish-gate preview <name> <test|live> <file> <bytes>

	The API key is never passed to this script (only whether it is set).
	(v1.6.0) An adopted project (studwork.json "adopted": true): --live runs `tools/adopt --verify .`
	and passes its exit code to PublishGate (refused unless 0); a "placeFile" project is refused.
	Build-relevant paths: the game folder (minus deploy.json), packages, deps (in a games repo: the
	roblox-core submodule; in a single-game project, v1.5.0: the whole project + studwork/). <name> is a game name (tools/lune/Roots.luau findGame) or folder.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local PublishGate = require("./PublishGate")
local Roots = require("./Roots")

local function git(args: { string }): (boolean, string)
	local result = process.exec("git", args)
	return result.ok, (string.gsub(result.stdout, "%s+$", ""))
end

local function lines(text: string): { string }
	local out = {}
	for l in string.gmatch(text, "[^\n]+") do
		table.insert(out, l)
	end
	return out
end

local cmd, name, target = process.args[1], process.args[2], process.args[3]
if cmd == nil or name == nil or (target ~= "test" and target ~= "live") then
	print("usage: publish-gate check|url|preview <name> <test|live> ...")
	process.exit(2)
end
local gameDir = Roots.findGame(fs, name) or ("games/" .. name)
local deployPath = if gameDir == "." then "deploy.json" else gameDir .. "/deploy.json"
-- build inputs: the game folder, and the core (its packages + deps in the core repo; the whole
-- roblox-core submodule in a games repo, whose pointer/working tree shows up as one path)
-- (v1.5.0) single-game project: the whole project (it IS the game) + the studwork/ submodule
local BUILD_PATHS = if Roots.single
	then { ".", Roots.CORE }
	elseif Roots.external then { gameDir, Roots.CORE }
	else { gameDir, "packages", "deps" }
local ok, deploy = pcall(serde.decode, "json", fs.readFile(deployPath))
if not ok then
	print("error: cannot read " .. deployPath .. ": " .. tostring(deploy))
	process.exit(1)
end

if cmd == "url" then
	print(PublishGate.url(deploy, target))
	process.exit(0)
elseif cmd == "preview" then
	print(PublishGate.requestPreview(deploy, target, process.args[4] or "?", tonumber(process.args[5]) or 0))
	process.exit(0)
elseif cmd ~= "check" then
	print("unknown command " .. cmd)
	process.exit(2)
end

local dryRun = process.args[4] == "1"
local keyPresent = process.args[5] == "1"

local headOk, head = git({ "rev-parse", "HEAD" })
if not headOk or head == "" then
	print("error: git rev-parse HEAD failed")
	process.exit(1)
end

local excludeDeploy = ":(exclude)" .. deployPath
local statusArgs = { "status", "--porcelain", "--" }
for _, p in BUILD_PATHS do
	table.insert(statusArgs, p)
end
table.insert(statusArgs, excludeDeploy)
local _, status = git(statusArgs)
local dirty = {}
for _, l in lines(status) do
	table.insert(dirty, (string.gsub(l, "^...", "")))
end

-- The recorded test commit may differ from HEAD only by the stamp files (deploy.json/GAMES.md
-- committed after the test publish): same build, so it still counts.
local testEquivalent = false
local testCommit = PublishGate.recordCommit(deploy, "test", "published")
if target == "live" and testCommit and testCommit ~= head then
	local diffArgs = { "diff", "--quiet", testCommit, head, "--" }
	for _, p in BUILD_PATHS do
		table.insert(diffArgs, p)
	end
	table.insert(diffArgs, excludeDeploy)
	local result = process.exec("git", diffArgs)
	testEquivalent = result.code == 0
end

-- (v1.6.0, docs/framework/adopting.md) an adopted project: studwork.json at the project root
local adopted, placeFile, adoptVerify = false, nil, nil
if fs.isFile("studwork.json") then
	local okM, marker = pcall(serde.decode, "json", fs.readFile("studwork.json"))
	if not okM or type(marker) ~= "table" then
		print("error: cannot read studwork.json")
		process.exit(1)
	end
	adopted = marker.adopted == true
	placeFile = if type(marker.placeFile) == "string" then marker.placeFile else nil
end
if adopted and target == "live" and placeFile == nil then
	-- contract: the exit code of tools/adopt --verify decides (anything but 0 refuses)
	print("== tools/adopt --verify .")
	local okV, verify = pcall(process.exec, "bash", { Roots.core("tools/adopt"), "--verify", "." })
	if okV then
		local out = string.gsub(verify.stdout .. verify.stderr, "%s+$", "")
		if out ~= "" then
			print(out)
		end
		adoptVerify = verify.code == 0
	else
		print("tools/adopt --verify could not run: " .. tostring(verify))
		adoptVerify = false
	end
end

local decision = PublishGate.decide({
	adopted = adopted,
	placeFile = placeFile,
	adoptVerify = adoptVerify,
	target = target,
	dryRun = dryRun,
	deploy = deploy,
	head = head,
	dirty = dirty,
	keyPresent = keyPresent,
	testEquivalent = testEquivalent,
})

for _, w in decision.warnings do
	print("warning: " .. w)
end
for _, e in decision.errors do
	print("refused: " .. e)
end
if not decision.ok then
	process.exit(1)
end
print(
	string.format(
		"gate: ok (%s %s at %s)",
		if dryRun then "dry run" else "publish",
		target,
		string.sub(head, 1, 7)
	)
)
