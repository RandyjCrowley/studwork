--!nocheck
--[[
	tools/lune/publish-gate: CLI wrapper around PublishGate (pure) for tools/publish.

	  lune run tools/lune/publish-gate check <name> <test|live> <dryRun 0|1> <keyPresent 0|1>
	      gathers git facts (HEAD, dirty build paths, test-commit equivalence), prints warnings
	      and errors, exits 1 when the publish must be refused.
	  lune run tools/lune/publish-gate url <name> <test|live>
	  lune run tools/lune/publish-gate preview <name> <test|live> <file> <bytes>

	The API key is never passed to this script (only whether it is set).
	Build-relevant paths: games/<name> (minus deploy.json), packages, deps.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local PublishGate = require("./PublishGate")

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
local deployPath = "games/" .. name .. "/deploy.json"
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
local _, status = git({ "status", "--porcelain", "--", "games/" .. name, "packages", "deps", excludeDeploy })
local dirty = {}
for _, l in lines(status) do
	table.insert(dirty, (string.gsub(l, "^...", "")))
end

-- The recorded test commit may differ from HEAD only by the stamp files (deploy.json/GAMES.md
-- committed after the test publish): same build, so it still counts.
local testEquivalent = false
local testCommit = PublishGate.recordCommit(deploy, "test", "published")
if target == "live" and testCommit and testCommit ~= head then
	local result = process.exec(
		"git",
		{ "diff", "--quiet", testCommit, head, "--", "games/" .. name, "packages", "deps", excludeDeploy }
	)
	testEquivalent = result.code == 0
end

local decision = PublishGate.decide({
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
