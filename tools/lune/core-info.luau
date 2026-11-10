--!nocheck
--[[
	tools/lune/core-info: shared helpers for tools that track which core a game ships.

	coreVersion = the `Core.version = "x.y.z"` string in packages/core/shared/init.luau (what the
	              built place actually reports at runtime).
	coreCommit  = the last commit that touched packages/core or packages/ui (short hash), with
	              "-dirty" appended when those folders have uncommitted changes.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local CoreInfo = {}

CoreInfo.CORE_PATHS = { "packages/core", "packages/ui" }

local function git(args: { string }): (boolean, string)
	local result = process.exec("git", args)
	return result.ok, string.gsub(result.stdout, "%s+$", "")
end

function CoreInfo.version(): string
	local source = fs.readFile("packages/core/shared/init.luau")
	local version = string.match(source, 'Core%.version%s*=%s*"([^"]+)"')
	assert(version, "could not find Core.version in packages/core/shared/init.luau")
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
