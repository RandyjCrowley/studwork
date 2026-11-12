--!nocheck
-- tools/lune/NewProject (StudWork v1.5.0): tools/new-project's argument handling and the
-- single-game skeleton (templates/single-game).
local NewProject = require("tools/lune/NewProject.luau")
local NewGame = require("tools/lune/NewGame.luau")
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
		local vars = { name = "my-game", tag = "v1.5.0", port = "34872", modules = "Items" }
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
