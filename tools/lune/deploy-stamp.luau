--!nocheck
--[[
	tools/lune/deploy-stamp <name> <how>: record the core a game was built with.
	Called by tools/publish on every publish, dry runs included (`how` says which, e.g.
	"publish --test --dry-run"). Writes games/<name>/deploy.json:
	  coreVersion  Core.version of the build ("1.1.0")
	  coreCommit   last commit touching packages/core or packages/ui (+ "-dirty")
	  coreStamp    { how, at (UTC ISO time) }
	and the game's "Core" cell in GAMES.md ("1.1.0 (abc1234)").
]]

local DateTime = require("@lune/datetime")
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local CoreInfo = require("./core-info")

local name, how = process.args[1], process.args[2] or "manual"
if name == nil then
	print("usage: deploy-stamp <name> <how>")
	process.exit(1)
end
local deployPath = "games/" .. name .. "/deploy.json"
if not fs.isFile(deployPath) then
	print("error: missing " .. deployPath)
	process.exit(1)
end

local version = CoreInfo.version()
local commit = CoreInfo.commit()

local deploy = serde.decode("json", fs.readFile(deployPath))
deploy.coreVersion = version
deploy.coreCommit = commit
deploy.coreStamp = { how = how, at = DateTime.now():toIsoDate() }
fs.writeFile(deployPath, serde.encode("json", deploy, true) .. "\n")

-- GAMES.md: set the "Core" cell of this game's row.
local GAMES = "GAMES.md"
if fs.isFile(GAMES) then
	local lines = string.split(fs.readFile(GAMES), "\n")
	local coreCol: number? = nil
	for i, line in lines do
		local cells = string.split(line, "|")
		if coreCol == nil and string.find(line, "| Game |", 1, true) then
			for c, cell in cells do
				if string.match(cell, "^%s*Core%s*$") then
					coreCol = c
				end
			end
		elseif coreCol and string.match(cells[2] or "", "^%s*(.-)%s*$") == name then
			cells[coreCol] = " " .. version .. " (" .. commit .. ") "
			lines[i] = table.concat(cells, "|")
		end
	end
	fs.writeFile(GAMES, table.concat(lines, "\n"))
end

print(string.format("stamped %s: coreVersion %s, coreCommit %s (%s)", name, version, commit, how))
