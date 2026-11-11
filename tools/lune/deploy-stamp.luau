--!nocheck
--[[
	tools/lune/deploy-stamp <name> <how> (optional: --target test|live --commit <hash>
	                                     --dry-run --version <n>)
	Record the core a game was built with. Called by tools/publish on every publish, dry runs
	included (`how` says which, e.g. "publish --test --dry-run"). Writes games/<name>/deploy.json:
	  coreVersion  StudWork.VERSION of the build ("1.3.0"; core-info.luau)
	  coreCommit   last commit touching packages/{core,framework,kits,ui} (+ "-dirty")
	  coreSha      full sha of the core checkout's HEAD (v1.4.0; in a games repo: the submodule's
	               pinned commit)
	  coreTag      the tag at that commit (vX.Y.Z) or absent
	  coreStamp    { how, at (UTC ISO time) }
	and the game's "Core" cell in GAMES.md ("1.1.0 (abc1234)") when the project has one (a
	single-game project, v1.5.0, has none: deploy.json at its root is the only record).
	With --target it also records what went to that place (read by the test-before-live gate,
	tools/lune/PublishGate.luau, and tools/core-status):
	  <target>.published = { commit, at, versionNumber }   real publish
	  <target>.dryRun    = { commit, at }                  --dry-run
]]

local DateTime = require("@lune/datetime")
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local CoreInfo = require("./core-info")
local DeployStamp = require("./DeployStamp")
local Roots = require("./Roots")

local name, how = process.args[1], process.args[2] or "manual"
local opts = { dryRun = false }
do
	local i = 3
	while i <= #process.args do
		local a = process.args[i]
		if a == "--dry-run" then
			opts.dryRun = true
		elseif a == "--target" or a == "--commit" or a == "--version" then
			opts[string.sub(a, 3)] = process.args[i + 1]
			i += 1
		else
			print("error: unknown option " .. tostring(a))
			process.exit(1)
		end
		i += 1
	end
end
if opts.target ~= nil and (opts.target ~= "test" and opts.target ~= "live" or opts.commit == nil) then
	print("error: --target must be test|live and needs --commit")
	process.exit(1)
end
if name == nil then
	print("usage: deploy-stamp <name> <how>")
	process.exit(1)
end
local gameDir = Roots.findGame(fs, name) or ("games/" .. name)
local deployPath = DeployStamp.deployPath(gameDir)
if not fs.isFile(deployPath) then
	print("error: missing " .. deployPath)
	process.exit(1)
end

local version = CoreInfo.version()
local commit = CoreInfo.commit()
local sha = CoreInfo.headSha()
local tag = CoreInfo.tag()

local deploy = serde.decode("json", fs.readFile(deployPath))
DeployStamp.stamp(
	deploy,
	{ version = version, commit = commit, sha = sha, tag = tag },
	how,
	DateTime.now():toIsoDate(),
	opts
)
fs.writeFile(deployPath, serde.encode("json", deploy, true) .. "\n")

-- GAMES.md: set the "Core" cell of this game's row (none in a single-game project: skipped)
local GAMES = "GAMES.md"
local games = DeployStamp.gamesMd(
	if fs.isFile(GAMES) then fs.readFile(GAMES) else nil,
	name,
	version .. " (" .. commit .. ")"
)
if games ~= nil then
	fs.writeFile(GAMES, games)
end

print(
	string.format(
		"stamped %s: coreVersion %s, coreCommit %s, coreSha %s, coreTag %s (%s)",
		name,
		version,
		commit,
		tostring(sha),
		tostring(tag),
		how
	)
)
