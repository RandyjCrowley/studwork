--!nocheck
-- tools/lune/NewProject (StudWork v1.5.0): tools/new-project's argument handling and the
-- single-game skeleton (templates/single-game).
local NewProject = require("tools/lune/NewProject.luau")
local NewGame = require("tools/lune/NewGame.luau")
local KitModules = require("tools/lune/KitModules.luau")
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")

local function parse(args)
	return NewProject.parseArgs(args, NewGame.validName)
end

describe("NewProject.parseArgs", function()
	it("defaults: name from the folder, the public StudWork url, install on, tag from the caller", function()
		local opts = parse({ "../work/my-game/" })
		expect(opts.path).toBe("../work/my-game/")
		expect(opts.name).toBe("my-game")
		expect(opts.url).toBe("https://github.com/RandyjCrowley/studwork.git")
		expect(opts.url).toBe(NewProject.DEFAULT_URL)
		expect(opts.tag).toBeNil()
		expect(opts.install).toBe(true)
		expect(opts.modules).toBeNil()
		expect(opts.authorName).toBeNil()
		expect(opts.authorEmail).toBeNil()
	end)

	it("reads every option (separate and --opt=value forms)", function()
		local opts = parse({
			"proj",
			"--name",
			"coin-runner",
			"--modules",
			"Items, Rarity,Inventory",
			"--url=../studwork",
			"--tag",
			"v1.5.0",
			"--no-install",
			"--author-name",
			"Some One",
			"--author-email=someone@example.invalid",
		})
		expect(opts.name).toBe("coin-runner")
		expect(opts.modules).toEqual({ "Items", "Rarity", "Inventory" })
		expect(opts.url).toBe("../studwork")
		expect(opts.tag).toBe("v1.5.0")
		expect(opts.install).toBe(false)
		expect(opts.authorName).toBe("Some One")
		expect(opts.authorEmail).toBe("someone@example.invalid")
	end)

	it("--help and -h are recognised anywhere, and the help lists every option", function()
		expect(NewProject.wantsHelp({ "--help" })).toBe(true)
		expect(NewProject.wantsHelp({ "proj", "-h" })).toBe(true)
		expect(NewProject.wantsHelp({ "proj", "--name", "x" })).toBe(false)
		for _, option in
			{ "--name", "--modules", "--url", "--tag", "--no-install", "--author-name", "--author-email" }
		do
			expect(string.find(NewProject.HELP, option, 1, true)).never.toBeNil()
		end
	end)

	it("refuses bad input with a clear message", function()
		local _, err = parse({})
		expect(string.find(err, "usage: tools/new-project", 1, true)).never.toBeNil()
		_, err = parse({ "My Game" })
		expect(string.find(err, "defaults to the folder name", 1, true)).never.toBeNil()
		_, err = parse({ "proj", "--name", "Bad_Name" })
		expect(string.find(err, "bad game name 'Bad_Name'", 1, true)).never.toBeNil()
		_, err = parse({ "proj", "--tag", "1.5.0" })
		expect(string.find(err, "vX.Y.Z", 1, true)).never.toBeNil()
		_, err = parse({ "proj", "--modules" })
		expect(string.find(err, "--modules needs a value", 1, true)).never.toBeNil()
		_, err = parse({ "proj", "--frobnicate" })
		expect(string.find(err, "unknown option --frobnicate", 1, true)).never.toBeNil()
		_, err = parse({ "proj", "other" })
		expect(string.find(err, "unexpected argument other", 1, true)).never.toBeNil()
		_, err = parse({ "proj", "--url", "a", "--url", "b" })
		expect(string.find(err, "given twice", 1, true)).never.toBeNil()
		_, err = parse({ "proj", "--author-email", "nope" })
		expect(string.find(err, "email", 1, true)).never.toBeNil()
	end)

	it("tells local paths (file transport) from remote urls", function()
		expect(NewProject.isLocalUrl("../studwork")).toBe(true)
		expect(NewProject.isLocalUrl("/tmp/studwork")).toBe(true)
		expect(NewProject.isLocalUrl("file:///tmp/studwork")).toBe(true)
		expect(NewProject.isLocalUrl("https://github.com/RandyjCrowley/studwork.git")).toBe(false)
		expect(NewProject.isLocalUrl("git@github.com:RandyjCrowley/studwork.git")).toBe(false)
		expect(NewProject.isLocalUrl("ssh://git@example.invalid/studwork.git")).toBe(false)
	end)
end)

describe("NewProject skeleton", function()
	it("renders placeholders and refuses unknown ones", function()
		expect(NewProject.render("# {{name}} on {{tag}}", { name = "g", tag = "v1.5.0" })).toBe(
			"# g on v1.5.0"
		)
		local out, err = NewProject.render("{{name}} {{nope}}", { name = "g" })
		expect(out).toBeNil()
		expect(err).toBe("unknown placeholder {{nope}}")
	end)

	it("plans the copy: README skipped, dotfiles renamed, .tmpl rendered", function()
		local plan = NewProject.skeletonPlan({
			"tools",
			"README.md",
			"gitignore",
			"env.example",
			"CLAUDE.md.tmpl",
			".githooks",
			"studwork.json",
		})
		local byFrom = {}
		for _, step in plan do
			byFrom[step.from] = step
		end
		expect(byFrom["README.md"]).toBeNil()
		expect(byFrom.gitignore.to).toBe(".gitignore")
		expect(byFrom["env.example"].to).toBe(".env.example")
		expect(byFrom["CLAUDE.md.tmpl"].to).toBe("CLAUDE.md")
		expect(byFrom["CLAUDE.md.tmpl"].render).toBe(true)
		expect(byFrom.tools.to).toBe("tools")
		expect(byFrom[".githooks"].render).toBe(false)
	end)

	it("finds absolute paths in text", function()
		local hits = NewProject.absolutePaths("a\nsee /home/me/x\nb", { "/home/me" })
		expect(hits).toEqual({ "2: see /home/me/x" })
		expect(NewProject.absolutePaths("studwork/packages", { "/home/me", "" })).toEqual({})
	end)

	it("templates/single-game has the marker, every wrapper, the hook and renders cleanly", function()
		local dir = "templates/single-game"
		expect(fs.readFile(dir .. "/studwork.json")).toContain('"layout": "single-game"')
		for _, w in
			{
				"_studwork",
				"dev",
				"lint",
				"format",
				"typecheck",
				"test",
				"build",
				"publish",
				"install",
				"doctor",
				"framework-status",
				"net",
				"sync-projects",
				"make-module",
				"make-screen",
				"make-migration",
				"new-game",
			}
		do
			expect(fs.isFile(dir .. "/tools/" .. w)).toBe(true)
		end
		expect(fs.readFile(dir .. "/tools/_studwork")).toContain('CORE="$ROOT/studwork"')
		expect(fs.readFile(dir .. "/tools/framework-status")).toContain('_studwork" core-status')
		expect(fs.readFile(dir .. "/.githooks/pre-commit")).toContain("step lint tools/lint")
		-- (v1.6.1) the CI template: full history, lint with --anchor-remote
		local ci = fs.readFile(dir .. "/.github/workflows/ci.yml")
		expect(ci).toContain("run: tools/lint --anchor-remote")
		expect(ci).toContain("fetch-depth: 0")
		expect(ci).toContain("submodules: recursive")
		-- setup-rokit installs tools itself: the manifest belongs to the submodule, not the game.
		expect(ci).toContain("path: studwork")
		local vars =
			{ name = "my-game", tag = "v1.5.0", port = "34872", modules = "Items", console = "mygame" }
		-- Privacy: only generic machine-path patterns live in this repo. Names that must never appear
		-- in a template (your own projects, hosts, people) come from outside the repo: the env var
		-- STUDWORK_PRIVATE_NAMES (comma-separated) and/or the git-ignored file .private-names at the
		-- repo root (one per line, # comments). With neither, that part is skipped.
		local private = {}
		local function addNames(text: string, sep: string)
			for _, raw in string.split(text, sep) do
				local name = string.gsub(string.gsub(raw, "#.*$", ""), "^%s*(.-)%s*$", "%1")
				if name ~= "" then
					table.insert(private, name)
				end
			end
		end
		local okProcess, process = pcall((getmetatable(getfenv(1)) :: any).__index.require, "@lune/process")
		if okProcess and type(process) == "table" and process.env.STUDWORK_PRIVATE_NAMES then
			addNames(process.env.STUDWORK_PRIVATE_NAMES, ",")
		end
		if fs.isFile(".private-names") then
			addNames(fs.readFile(".private-names"), "\n")
		end
		-- every file the skeleton copies into a new project (recursively: tools/, .githooks/, ...);
		-- *.tmpl files are checked as rendered
		local checked = 0
		local function scan(folder: string)
			for _, entry in fs.readDir(folder) do
				local path = folder .. "/" .. entry
				if fs.isDir(path) then
					scan(path)
				else
					local text = fs.readFile(path)
					if string.match(entry, "%.tmpl$") then
						local rendered, err = NewProject.render(text, vars)
						expect(err).toBeNil()
						text = rendered
						expect(string.find(text, "{{", 1, true)).toBeNil()
					end
					expect(NewProject.absolutePaths(text, { "/Users/", "/home/", ".local" })).toEqual({})
					for _, name in private do
						expect(string.find(string.lower(text), string.lower(name), 1, true)).toBeNil()
					end
					checked += 1
				end
			end
		end
		scan(dir)
		expect(checked > 10).toBe(true) -- the wrappers, hook, marker and docs were all reached
		local claude = fs.readFile(dir .. "/CLAUDE.md.tmpl")
		expect(claude).toContain("Never edit `studwork/`")
		expect(claude).toContain("FRAMEWORK_REQUESTS.md")
		expect(string.find(claude, "roblox-core/", 1, true)).toBeNil()
		expect(string.find(claude, "games/<name>", 1, true)).toBeNil()
	end)
end)

-- (v1.7.1) tools/new-project --modules runs studwork/tools/new-game with the same list: a kit the
-- user names goes in the game module's dependsOn, also the ones the template keeps optional.
describe("new-project --modules: named kits in the game module's dependsOn", function()
	local function block(src: string, field: string): string
		return string.match(src, "\n\t" .. field .. " = (%b{})") or ""
	end

	it("the template's optional kits move to dependsOn when named; nothing named stays", function()
		local template = fs.readFile("templates/new-game/modules/sandbox/module.luau")
		expect(block(template, "optional")).toContain('WaitForChild("Leaderboards")')
		local named = { "Items", "Rarity", "Inventory", "Economy", "Leaderboards", "Badges" }
		local order, _, errors = NewGame.resolveModules(
			KitModules.load(fs, require("tools/lune/ModuleDiscovery.luau"), "."),
			named
		)
		assert(order, errors and table.concat(errors, "; "))
		local out = assert(NewGame.trimDependsOn(template, order, named))
		local depends, optional = block(out, "dependsOn"), block(out, "optional")
		for _, kit in named do
			expect(depends).toContain('WaitForChild("' .. kit .. '")')
			expect(string.find(optional, '"' .. kit .. '"', 1, true)).toBeNil()
		end
		-- a named kit the template doesn't refer to (Items) gets a ref in the block's style, once
		expect(string.find(template, 'WaitForChild("Items")', 1, true)).toBeNil()
		local _, items =
			string.gsub(out, 'require%(KitDefs:WaitForChild%("Items"%):WaitForChild%("module"%)%),', "")
		expect(items).toBe(1)
		-- the promoted line is the template's own (same ref form), once
		local _, count = string.gsub(
			out,
			'require%(KitDefs:WaitForChild%("Leaderboards"%):WaitForChild%("module"%)%),',
			""
		)
		expect(count).toBe(1)
		expect(optional).toBe("{}")
		for _, kit in { "Notifications", "TextFilter", "Mail", "Streak" } do
			expect(string.find(out, '"' .. kit .. '"', 1, true)).toBeNil()
		end
	end)

	it("a kit in the list but not named (added as a dependency) keeps the template's optional", function()
		local template = fs.readFile("templates/new-game/modules/sandbox/module.luau")
		local out = assert(
			NewGame.trimDependsOn(template, { "Items", "Leaderboards", "Badges" }, { "Items", "Badges" })
		)
		expect(block(out, "dependsOn")).toContain('WaitForChild("Badges")')
		expect(block(out, "optional")).toContain('WaitForChild("Leaderboards")')
		expect(string.find(block(out, "optional"), '"Badges"', 1, true)).toBeNil()
		-- no named list (new-game without --modules, or an old caller): v1.7.0 behaviour
		local old = assert(NewGame.trimDependsOn(template, { "Items", "Leaderboards" }))
		expect(block(old, "optional")).toContain('WaitForChild("Leaderboards")')
		expect(string.find(block(old, "dependsOn"), '"Leaderboards"', 1, true)).toBeNil()
	end)
end)
