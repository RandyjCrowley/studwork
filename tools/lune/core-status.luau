--!nocheck
--[[
	tools/lune/core-status: every game's recorded core (deploy.json coreVersion/coreCommit, written
	by tools/publish) against the current core, plus per target (test/live) whether the ids are
	placeholders and whether that place is in sync with HEAD (PublishGate.syncStatus), and whether
	its Rojo projects map the core v1.3.0 layout (Layout.luau: packages/framework + packages/kits,
	nothing into packages/core). Games without a readable deploy.json are listed too. Exit 0
	always; it is a report.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local process = require("@lune/process")

local CoreInfo = require("./core-info")
local Layout = require("./Layout")
local PublishGate = require("./PublishGate")
local Roots = require("./Roots")
local KITS_DIR = Roots.core(Layout.KITS_DIR)

local headResult = process.exec("git", { "rev-parse", "HEAD" })
local head = string.gsub(headResult.stdout, "%s+$", "")

local currentVersion = CoreInfo.version()
local currentCommit = CoreInfo.commit()

local kits = {}
for _, entry in fs.readDir(KITS_DIR) do
	if fs.isDir(KITS_DIR .. "/" .. entry) then
		table.insert(kits, entry)
	end
end
table.sort(kits)

-- "ok" or the number of layout issues over the game's *.project.json files (details printed below)
local layoutDetails = {}
local function layoutOf(dir: string): string
	local entry = dir
	local issues = {}
	for _, file in fs.readDir(dir) do
		if string.match(file, "%.project%.json$") then
			local ok, project = pcall(serde.decode, "json", fs.readFile(dir .. "/" .. file))
			for _, issue in
				(if ok then Layout.projectIssues(project, dir, kits, Roots.CORE) else { "not valid JSON" })
			do
				table.insert(issues, file .. ": " .. issue)
			end
		end
	end
	if #issues == 0 then
		return "ok"
	end
	layoutDetails[entry] = issues
	return string.format("%d issue(s)", #issues)
end

local rows = {}
for _, entry in Roots.gameDirs(fs) do
	local path = entry .. "/deploy.json"
	if not fs.isFile(path) then
		table.insert(rows, { entry, "-", "-", "no deploy.json", "-", "-", "-", layoutOf(entry) })
	elseif fs.isFile(path) then
		local ok, deploy = pcall(serde.decode, "json", fs.readFile(path))
		if not ok then
			table.insert(
				rows,
				{ entry, "-", "-", "deploy.json is not valid JSON", "-", "-", "-", layoutOf(entry) }
			)
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
				layoutOf(entry),
			})
		end
	end
end
table.sort(rows, function(a, b)
	return a[1] < b[1]
end)

print(
	string.format(
		"current core: StudWork %s (%s), HEAD %s",
		currentVersion,
		currentCommit,
		string.sub(head, 1, 7)
	)
)
print(string.format("framework: %s   kits: %s   ui: packages/ui", Layout.FRAMEWORK, table.concat(kits, ", ")))
local function exists(path: string): boolean
	return fs.isFile(path) or fs.isDir(path)
end
local function kitModules(): { [string]: { string } }
	local out = {}
	for _, kit in kits do
		local list = {}
		for _, m in fs.readDir(KITS_DIR .. "/" .. kit) do
			if
				fs.isDir(KITS_DIR .. "/" .. kit .. "/" .. m)
				and fs.isFile(KITS_DIR .. "/" .. kit .. "/" .. m .. "/module.luau")
			then
				table.insert(list, m)
			end
		end
		table.sort(list)
		out[kit] = list
	end
	return out
end
for _, issue in Layout.repoIssues(exists, kits, kitModules(), Roots.CORE) do
	print("layout: " .. issue)
end
print("")
local header = { "game", "coreVersion", "coreCommit", "core status", "test", "live", "last stamp", "layout" }
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
for _, r in rows do
	for _, issue in layoutDetails[r[1]] or {} do
		print(string.format("  %s: %s", r[1], issue))
	end
end
