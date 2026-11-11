--!strict
--[[
	tools/lune/DeployStamp (StudWork v1.5.0): the pure parts of tools/lune/deploy-stamp (zero
	requires). Specs: DeployStamp.spec.luau.

	deployPath(gameDir) -> string        "<gameDir>/deploy.json"; "deploy.json" for a single-game
	                                     project's root game (gameDir ".")
	stamp(deploy, info, how, now, opts?) -> deploy
	    info = { version, commit, sha?, tag? } (core-info.luau); opts = { target?, commit?,
	    dryRun?, version? } (tools/publish). Writes coreVersion/coreCommit/coreSha/coreTag/coreStamp
	    and, with a target, <target>.dryRun = { commit, at } or <target>.published = { commit, at,
	    versionNumber }.
	gamesMd(text?, name, cell) -> string?
	    the GAMES.md text with the game's "Core" cell set; nil when there is no GAMES.md (a
	    single-game project, or the core repo): nothing to write
]]

local DeployStamp = {}

function DeployStamp.deployPath(gameDir: string): string
	if gameDir == "." or gameDir == "" then
		return "deploy.json"
	end
	return gameDir .. "/deploy.json"
end

export type Info = { version: string, commit: string, sha: string?, tag: string? }
export type Opts = { target: string?, commit: string?, dryRun: boolean?, version: string? }

function DeployStamp.stamp(deploy: any, info: Info, how: string, now: string, opts: Opts?): any
	local o: Opts = opts or {}
	deploy.coreVersion = info.version
	deploy.coreCommit = info.commit
	-- v1.4.0: the exact core checkout (full sha of the core's HEAD: a project's pinned submodule
	-- commit) and its tag, when HEAD is exactly a tag
	deploy.coreSha = info.sha
	deploy.coreTag = info.tag
	deploy.coreStamp = { how = how, at = now }
	local target = o.target
	if target then
		if type(deploy[target]) ~= "table" then
			deploy[target] = { universeId = 0, placeId = 0 }
		end
		if o.dryRun then
			deploy[target].dryRun = { commit = o.commit, at = now }
		else
			deploy[target].published = { commit = o.commit, at = now, versionNumber = tonumber(o.version) }
		end
	end
	return deploy
end

function DeployStamp.gamesMd(text: string?, name: string, cell: string): string?
	if text == nil then
		return nil
	end
	local lines = string.split(text, "\n")
	local coreCol: number? = nil
	for i, line in lines do
		local cells = string.split(line, "|")
		if coreCol == nil and string.find(line, "| Game |", 1, true) then
			for c, value in cells do
				if string.match(value, "^%s*Core%s*$") then
					coreCol = c
				end
			end
		elseif coreCol and string.match(cells[2] or "", "^%s*(.-)%s*$") == name then
			cells[coreCol :: number] = " " .. cell .. " "
			lines[i] = table.concat(cells, "|")
		end
	end
	return table.concat(lines, "\n")
end

return DeployStamp
