--!nocheck
--[[
	tools/lune/core-info: shared helpers for tools that track which core a game ships.

	coreVersion = the framework version, `StudWork.VERSION = "x.y.z"` in
	              packages/framework/shared/init.luau (what the built place reports at runtime;
	              v1.3.0, was the v1.2 Core.version).
	coreCommit  = the last commit that touched packages/framework, kits or ui (short hash), with
	              "-dirty" appended when those folders have uncommitted changes.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Roots = require("./Roots")

local CoreInfo = {}

CoreInfo.CORE_PATHS = { "packages/framework", "packages/kits", "packages/ui" }
CoreInfo.VERSION_FILE = Roots.core("packages/framework/shared/init.luau")

-- git in the core's checkout (the core repo itself, or a games repo's roblox-core/ submodule);
-- CORE_PATHS are relative to it
local function git(args: { string }): (boolean, string)
	local full = { "-C", Roots.CORE }
	for _, a in args do
		table.insert(full, a)
	end
	local result = process.exec("git", full)
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

-- The core checkout's full HEAD commit sha (nil outside git).
function CoreInfo.headSha(): string?
	local ok, sha = git({ "rev-parse", "HEAD" })
	return if ok and sha ~= "" then sha else nil
end

-- The tag at the core's HEAD (vX.Y.Z), or nil when HEAD is not exactly a tag.
function CoreInfo.tag(): string?
	local ok, tag = git({ "describe", "--tags", "--exact-match", "HEAD" })
	return if ok and tag ~= "" then tag else nil
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
