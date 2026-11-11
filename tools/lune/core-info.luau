--!nocheck
--[[
	tools/lune/core-info: shared helpers for tools that track which core a game ships.

	coreVersion = the framework version, `StudWork.VERSION = "x.y.z"` in
	              packages/framework/shared/init.luau (what the built place reports at runtime;
	              core-v1.3.0 step 4b-IIb, was the v1.2 Core.version).
	coreCommit  = the last commit that touched packages/framework, kits, ui or core (short hash),
	              with "-dirty" appended when those folders have uncommitted changes. packages/core
	              stays in the list until Phase 2 deletes it (the kits still read its shared files).
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local CoreInfo = {}

CoreInfo.CORE_PATHS = { "packages/framework", "packages/kits", "packages/ui", "packages/core" }
CoreInfo.VERSION_FILE = "packages/framework/shared/init.luau"

local function git(args: { string }): (boolean, string)
	local result = process.exec("git", args)
	return result.ok, string.gsub(result.stdout, "%s+$", "")
end

-- The framework version string in a framework shared/init.luau source.
function CoreInfo.parseVersion(source: string): string?
	return string.match(source, 'StudWork%.VERSION%s*=%s*"([^"]+)"')
end

function CoreInfo.version(): string
	local version = CoreInfo.parseVersion(fs.readFile(CoreInfo.VERSION_FILE))
	assert(version, "could not find StudWork.VERSION in " .. CoreInfo.VERSION_FILE)
	return version
end

function CoreInfo.commit(): string
	local args = { "log", "-1", "--format=%h", "--" }
	for _, p in CoreInfo.CORE_PATHS do
		table.insert(args, p)
	end
	local ok, hash = git(args)
	assert(ok and hash ~= "", "git log failed (is this a git checkout?)")
	local statusArgs = { "status", "--porcelain", "--" }
	for _, p in CoreInfo.CORE_PATHS do
		table.insert(statusArgs, p)
	end
	local _, status = git(statusArgs)
	if status ~= "" then
		hash ..= "-dirty"
	end
	return hash
end

-- Number of commits touching core between `from` and HEAD (nil if `from` is unknown to git).
function CoreInfo.commitsBehind(from: string): number?
	local clean = string.gsub(from, "%-dirty$", "")
	local args = { "rev-list", "--count", clean .. "..HEAD", "--" }
	for _, p in CoreInfo.CORE_PATHS do
		table.insert(args, p)
	end
	local ok, out = git(args)
	if not ok then
		return nil
	end
	return tonumber(out)
end

return CoreInfo
