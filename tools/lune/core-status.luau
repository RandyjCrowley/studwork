--!nocheck
--[[
	tools/lune/core-status: every game's recorded core (deploy.json coreVersion/coreCommit, written
	by tools/publish) against the current core, plus per target (test/live) whether the ids are
	placeholders and whether that place is in sync with HEAD (PublishGate.syncStatus). Games
	without a readable deploy.json are listed too. Exit 0 always; it is a report.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local process = require("@lune/process")

local CoreInfo = require("./core-info")
local PublishGate = require("./PublishGate")

local headResult = process.exec("git", { "rev-parse", "HEAD" })
local head = string.gsub(headResult.stdout, "%s+$", "")

local currentVersion = CoreInfo.version()
local currentCommit = CoreInfo.commit()

local rows = {}
for _, entry in fs.readDir("games") do
	local path = "games/" .. entry .. "/deploy.json"
	if fs.isDir("games/" .. entry) and not fs.isFile(path) then
		table.insert(rows, { entry, "-", "-", "no deploy.json", "-", "-", "-" })
	elseif fs.isFile(path) then
		local ok, deploy = pcall(serde.decode, "json", fs.readFile(path))
		if not ok then
			table.insert(rows, { entry, "-", "-", "deploy.json is not valid JSON", "-", "-", "-" })
		else
			local version = deploy.coreVersion
			local commit = deploy.coreCommit
			local status
			if version == nil or commit == nil then
				status = "never published (no core stamp)"
			elseif commit == currentCommit then
				status = "current"
			else
				local behind = CoreInfo.commitsBehind(commit)
				status = if behind == nil
					then "unknown commit " .. commit
					elseif behind == 0 then "current (stamped from a dirty tree)"
					else string.format("behind: %d core commit(s)", behind)
				if version ~= currentVersion then
					status ..= string.format(", version %s -> %s", version, currentVersion)
				end
			end
			local how = if type(deploy.coreStamp) == "table"
				then string.format("%s @ %s", tostring(deploy.coreStamp.how), tostring(deploy.coreStamp.at))
				else "-"
			table.insert(rows, {
				entry,
				version or "-",
				commit or "-",
				status,
				PublishGate.syncStatus(deploy, "test", head),
				PublishGate.syncStatus(deploy, "live", head),
				how,
			})
		end
	end
end
table.sort(rows, function(a, b)
	return a[1] < b[1]
end)

print(
	string.format("current core: %s (%s), HEAD %s\n", currentVersion, currentCommit, string.sub(head, 1, 7))
)
local header = { "game", "coreVersion", "coreCommit", "core status", "test", "live", "last stamp" }
local widths = {}
for c, h in header do
	widths[c] = #h
	for _, r in rows do
		widths[c] = math.max(widths[c], #r[c])
	end
end
local function line(cells)
	local out = {}
	for c, cell in cells do
		table.insert(out, cell .. string.rep(" ", widths[c] - #cell))
	end
	print(table.concat(out, "  "))
end
line(header)
for _, r in rows do
	line(r)
end
