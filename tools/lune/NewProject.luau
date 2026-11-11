--!strict
--[[
	tools/lune/NewProject (StudWork v1.5.0, docs/framework/single-game-project.md): pure helpers of
	tools/new-project (zero requires; the game-name rule, NewGame.validName, is passed in). Specs:
	NewProject.spec.luau.

	parseArgs(args, validName) -> (opts?, error?)
	    tools/new-project <path> [--name <gameId>] [--modules A,B,...] [--url <studwork-url>]
	                      [--tag vX.Y.Z] [--no-install] [--author-name <n>] [--author-email <e>]
	    opts = { path, name (default: the path's last folder), modules: { string }?, url (default
	    DEFAULT_URL), tag: string? (nil: the caller uses v<StudWork.VERSION>), install: boolean,
	    authorName: string?, authorEmail: string? }
	baseName(path) -> string               "../games/my-game/" -> "my-game"
	isLocalUrl(url) -> boolean             a path or file:// url (git needs protocol.file.allow)
	validTag(tag) -> boolean               vX.Y.Z
	render(text, vars) -> (text?, error?)  replaces {{key}}; an unknown {{key}} is an error
	skeletonPlan(entries) -> { { from, to, render } }
	    how templates/single-game's top-level entries land in the project: README.md (the
	    skeleton's own description) is skipped, gitignore -> .gitignore, env.example ->
	    .env.example, <name>.tmpl -> <name> (rendered), everything else as is
	absolutePaths(text, roots) -> { string }   lines of `text` that contain one of `roots`
	    (absolute folders such as the project's own path or $HOME): committed files must not
]]

local NewProject = {}

NewProject.DEFAULT_URL = "https://github.com/RandyjCrowley/studwork.git"
NewProject.USAGE = "usage: tools/new-project <path> [--name <gameId>] [--modules A,B,C] [--url <studwork-url>]"
	.. " [--tag vX.Y.Z] [--no-install] [--author-name <name>] [--author-email <email>]"

export type Opts = {
	path: string,
	name: string,
	modules: { string }?,
	url: string,
	tag: string?,
	install: boolean,
	authorName: string?,
	authorEmail: string?,
}

function NewProject.baseName(path: string): string
	local trimmed = string.gsub(path, "/+$", "")
	return string.match(trimmed, "([^/]+)$") or trimmed
end

function NewProject.isLocalUrl(url: string): boolean
	if string.sub(url, 1, 7) == "file://" then
		return true
	end
	if string.match(url, "^%a[%w+.%-]*://") then
		return false
	end
	-- scp-like git@host:owner/repo
	if string.match(url, "^[^/]+@[^/]+:") then
		return false
	end
	return true
end

function NewProject.validTag(tag: string): boolean
	return string.match(tag, "^v%d+%.%d+%.%d+$") ~= nil
end

local VALUE_OPTIONS = {
	["--name"] = "name",
	["--modules"] = "modules",
	["--url"] = "url",
	["--tag"] = "tag",
	["--author-name"] = "authorName",
	["--author-email"] = "authorEmail",
}

function NewProject.parseArgs(args: { string }, validName: (string) -> boolean): (Opts?, string?)
	local values: { [string]: string } = {}
	local path: string? = nil
	local install = true
	local i = 1
	while i <= #args do
		local a = args[i]
		local key, inline = string.match(a, "^(%-%-[%w%-]+)=(.*)$")
		local option = key or a
		if option == "--no-install" and key == nil then
			install = false
		elseif VALUE_OPTIONS[option] then
			local value = inline
			if value == nil then
				value = args[i + 1]
				i += 1
			end
			if value == nil or value == "" or string.sub(value, 1, 2) == "--" then
				return nil, option .. " needs a value\n" .. NewProject.USAGE
			end
			if values[VALUE_OPTIONS[option]] ~= nil then
				return nil, option .. " given twice"
			end
			values[VALUE_OPTIONS[option]] = value
		elseif string.sub(a, 1, 2) == "--" then
			return nil, "unknown option " .. a .. "\n" .. NewProject.USAGE
		elseif path == nil then
			path = a
		else
			return nil, "unexpected argument " .. a .. "\n" .. NewProject.USAGE
		end
		i += 1
	end
	if path == nil or path == "" then
		return nil, NewProject.USAGE
	end
	local name = values.name or NewProject.baseName(path :: string)
	if not validName(name) then
		return nil,
			"bad game name '"
				.. name
				.. "': lowercase letters, digits, dashes; 2-32 chars, starts with a letter"
				.. (if values.name then "" else " (it defaults to the folder name; pass --name <gameId>)")
	end
	local modules: { string }? = nil
	if values.modules then
		local list = {}
		for part in string.gmatch(values.modules, "[^,]+") do
			local trimmed = string.match(part, "^%s*(.-)%s*$") :: string
			if trimmed ~= "" then
				table.insert(list, trimmed)
			end
		end
		modules = list
	end
	if values.tag and not NewProject.validTag(values.tag) then
		return nil, "--tag must be a release tag vX.Y.Z (got " .. values.tag .. ")"
	end
	if values.authorEmail and not string.match(values.authorEmail, "^[^%s@]+@[^%s@]+$") then
		return nil, "--author-email doesn't look like an email address"
	end
	return {
		path = path :: string,
		name = name,
		modules = modules,
		url = values.url or NewProject.DEFAULT_URL,
		tag = values.tag,
		install = install,
		authorName = values.authorName,
		authorEmail = values.authorEmail,
	},
		nil
end

function NewProject.render(text: string, vars: { [string]: string }): (string?, string?)
	local missing: string? = nil
	local out = string.gsub(text, "{{([%w_]+)}}", function(key: string): string?
		local v = vars[key]
		if v == nil then
			missing = missing or key
			return nil
		end
		return v
	end)
	if missing then
		return nil, "unknown placeholder {{" .. missing .. "}}"
	end
	return out, nil
end

export type Step = { from: string, to: string, render: boolean }

function NewProject.skeletonPlan(entries: { string }): { Step }
	local plan: { Step } = {}
	local sorted = table.clone(entries)
	table.sort(sorted)
	for _, entry in sorted do
		if entry == "README.md" or entry == ".DS_Store" then
			continue
		elseif entry == "gitignore" then
			table.insert(plan, { from = entry, to = ".gitignore", render = false })
		elseif entry == "env.example" then
			table.insert(plan, { from = entry, to = ".env.example", render = false })
		elseif string.match(entry, "%.tmpl$") then
			table.insert(plan, { from = entry, to = string.sub(entry, 1, #entry - 5), render = true })
		else
			table.insert(plan, { from = entry, to = entry, render = false })
		end
	end
	return plan
end

function NewProject.absolutePaths(text: string, roots: { string }): { string }
	local out = {}
	local lineNo = 0
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		lineNo += 1
		for _, root in roots do
			if root ~= "" and root ~= "/" and string.find(line, root, 1, true) then
				table.insert(out, `{lineNo}: {line}`)
				break
			end
		end
	end
	return out
end

return NewProject
