--!nocheck
--[[
	tools/lune/new-project (StudWork v1.5.0): the Lune side of tools/new-project
	(docs/framework/single-game-project.md). Pure parts: NewProject.luau.

	  lune run tools/lune/new-project parse <args...>
	      validates the arguments (NewProject.parseArgs, game name rule NewGame.validName, --modules
	      against the kit module definitions) and prints them as `key<TAB>value` lines for the bash
	      side; exit 1 with the error on bad arguments.
	  lune run tools/lune/new-project skeleton <projectDir> <templateDir> <name> <tag> <modules text>
	      <projectDir> = the NEW project's absolute folder, <templateDir> relative to it: copies templates/single-game (from the
	      project's studwork/ submodule) into it (NewProject.skeletonPlan: gitignore -> .gitignore,
	      env.example -> .env.example, *.tmpl rendered with {{name}} {{tag}} {{port}} {{modules}} {{console}};
	      the port comes from the scaffolded deploy.json). Never writes an absolute path.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local NewProject = require("./NewProject")
local NewGame = require("./NewGame")

local args = table.clone(process.args)
local cmd = table.remove(args, 1)

if cmd == "help" then
	print(NewProject.HELP)
	process.exit(0)
elseif cmd == "parse" then
	local opts, err = NewProject.parseArgs(args, NewGame.validName)
	if opts == nil then
		print("error: " .. tostring(err))
		process.exit(1)
	end
	if opts.modules then
		local KitModules = require("./KitModules")
		local order, _, errors = NewGame.resolveModules(KitModules.load(fs), opts.modules)
		if order == nil then
			print("error: --modules:")
			for _, e in errors do
				print("  - " .. e)
			end
			process.exit(1)
		end
	end
	local function out(key: string, value: string?)
		if value ~= nil then
			-- one line per value; tabs/newlines can't be passed through
			assert(not string.find(value, "[\t\n]"), key .. " contains a tab or newline")
			print(key .. "\t" .. value)
		end
	end
	out("path", opts.path)
	out("name", opts.name)
	out("modules", if opts.modules then table.concat(opts.modules, ",") else nil)
	out("url", opts.url)
	out("tag", opts.tag)
	out("install", if opts.install then "1" else "0")
	out("authorName", opts.authorName)
	out("authorEmail", opts.authorEmail)
	process.exit(0)
elseif cmd == "skeleton" then
	local projectDir, templateRel, name, tag, modulesText = args[1], args[2], args[3], args[4], args[5]
	if projectDir == nil or templateRel == nil or name == nil or tag == nil then
		print("usage: new-project skeleton <projectDir> <templateDir> <name> <tag> <modules text>")
		process.exit(2)
	end
	-- every path is under the NEW project (absolute <projectDir>); nothing is relative to the
	-- working directory, which is the StudWork checkout running the tool
	if string.sub(projectDir, 1, 1) ~= "/" or not fs.isFile(projectDir .. "/studwork.json") then
		print("error: skeleton needs the new project's absolute folder (with studwork.json): " .. projectDir)
		process.exit(2)
	end
	if string.find(templateRel, "..", 1, true) or string.sub(templateRel, 1, 1) == "/" then
		print("error: the template folder must be inside the project: " .. templateRel)
		process.exit(2)
	end
	local function inProject(rel: string): string
		return projectDir .. "/" .. rel
	end
	local templateDir = inProject(templateRel)
	if not fs.isDir(templateDir) then
		print(
			"error: "
				.. templateRel
				.. " is missing (this StudWork tag predates single-game projects, v1.5.0)"
		)
		process.exit(1)
	end
	local port = "34872"
	if fs.isFile(inProject("deploy.json")) then
		local ok, deploy = pcall(serde.decode, "json", fs.readFile(inProject("deploy.json")))
		if ok and type(deploy) == "table" and type(deploy.servePort) == "number" then
			port = tostring(deploy.servePort)
		end
	end
	local vars = {
		name = name,
		tag = tag,
		port = port,
		modules = modulesText or "template default (all)",
		-- the game module's console prefix: its lower-case name (module-api.md §5 ctx.console)
		console = string.lower(NewGame.moduleName(name)),
	}
	local function copy(src: string, dst: string)
		if fs.isDir(src) then
			if not fs.isDir(dst) then
				fs.writeDir(dst)
			end
			for _, entry in fs.readDir(src) do
				if entry ~= ".DS_Store" then
					copy(src .. "/" .. entry, dst .. "/" .. entry)
				end
			end
		else
			fs.writeFile(dst, fs.readFile(src))
		end
	end
	for _, step in NewProject.skeletonPlan(fs.readDir(templateDir)) do
		local src = templateDir .. "/" .. step.from
		if step.render then
			local text, err = NewProject.render(fs.readFile(src), vars)
			if text == nil then
				print("error: " .. templateRel .. "/" .. step.from .. ": " .. tostring(err))
				process.exit(1)
			end
			fs.writeFile(inProject(step.to), text)
		else
			copy(src, inProject(step.to))
		end
		print("wrote " .. step.to)
	end
	process.exit(0)
end

print("usage: new-project parse|skeleton ...")
process.exit(2)
