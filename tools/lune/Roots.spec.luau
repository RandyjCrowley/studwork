--!nocheck
-- tools/lune/Roots (StudWork v1.4.0): the core folder vs the project root, and what counts as a
-- game folder. Pure parts, with a fake fs.
local Roots = require("tools/lune/Roots.luau")

local function fakeFs(files: { string })
	local isFile, isDir = {}, {}
	local children: { [string]: { [string]: boolean } } = {}
	for _, f in files do
		isFile[f] = true
		local path = f
		while true do
			local parent, name = string.match(path, "^(.*)/([^/]+)$")
			if parent == nil then
				children["."] = children["."] or {}
				children["."][path] = true
				break
			end
			isDir[parent] = true
			children[parent] = children[parent] or {}
			children[parent][name] = true
			path = parent
		end
	end
	return {
		isFile = function(p)
			return isFile[p] == true
		end,
		isDir = function(p)
			return isDir[p] == true
		end,
		readDir = function(p)
			local out = {}
			for name in children[p] or {} do
				table.insert(out, name)
			end
			table.sort(out)
			return out
		end,
	}
end

describe("Roots", function()
	it("prefixes core paths with the core folder (none in the core repo)", function()
		expect(Roots.prefix(nil, "packages/ui")).toBe("packages/ui")
		expect(Roots.prefix(".", "packages/ui")).toBe("packages/ui")
		expect(Roots.prefix("", "packages/ui")).toBe("packages/ui")
		expect(Roots.prefix("roblox-core", "packages/ui")).toBe("roblox-core/packages/ui")
		expect(Roots.prefix("roblox-core/", "deps/Packages")).toBe("roblox-core/deps/Packages")
		expect(Roots.prefix("./vendor/roblox-core", "tools")).toBe("vendor/roblox-core/tools")
	end)

	it("in the core repo (the spec's own mode) the core is '.'", function()
		expect(Roots.CORE).toBe(".")
		expect(Roots.external).toBe(false)
		expect(Roots.core("packages/framework")).toBe("packages/framework")
	end)

	it(
		"a game is a folder with default.project.json and src/ under games/, examples/, examples/overrides/",
		function()
			local fs = fakeFs({
				"examples/sandbox/default.project.json",
				"examples/sandbox/src/server/Main.server.luau",
				"examples/overrides/ov-a/default.project.json",
				"examples/overrides/ov-a/src/shared/Config/init.luau",
				"examples/modules/board/module.luau",
				"examples/modules/board/tests/fixture-game/default.project.json",
				"games/my-game/default.project.json",
				"games/my-game/src/client/Main.client.luau",
				"games/no-src/default.project.json",
			})
			expect(Roots.gameDirs(fs)).toEqual({
				"examples/overrides/ov-a",
				"examples/sandbox",
				"games/my-game",
			})
			expect(Roots.findGame(fs, "sandbox")).toBe("examples/sandbox")
			expect(Roots.findGame(fs, "ov-a")).toBe("examples/overrides/ov-a")
			expect(Roots.findGame(fs, "my-game")).toBe("games/my-game")
			expect(Roots.findGame(fs, "games/my-game/")).toBe("games/my-game")
			expect(Roots.findGame(fs, "no-src")).toBeNil()
			expect(Roots.findGame(fs, "board")).toBeNil()
		end
	)

	-- v1.5.0: the single-game project layout (docs/framework/single-game-project.md)
	it("decides the layout: core, games repo, or single-game by the studwork.json marker", function()
		local marker = fakeFs({ "studwork.json", "default.project.json", "src/server/Main.server.luau" })
		marker.readFile = function(p)
			assert(p == "studwork.json", "unexpected read " .. p)
			return '{\n  "layout": "single-game"\n}\n'
		end
		local plain = fakeFs({ "games/x/default.project.json", "games/x/src/a.luau" })
		expect(Roots.layoutOf(".", nil, marker)).toBe("core")
		expect(Roots.layoutOf(nil, "single-game", marker)).toBe("core")
		expect(Roots.layoutOf("studwork", nil, marker)).toBe("single-game")
		expect(Roots.layoutOf("roblox-core", nil, plain)).toBe("games-repo")
		-- tools/_common.sh's decision (STUDWORK_LAYOUT) wins over the file system
		expect(Roots.layoutOf("roblox-core", "single-game", plain)).toBe("single-game")
		expect(Roots.layoutOf("studwork", "games-repo", marker)).toBe("games-repo")
		expect(Roots.isSingleMarker('{"layout":"single-game"}')).toBe(true)
		expect(Roots.isSingleMarker('{"layout": "games-repo"}')).toBe(false)
		expect(Roots.isSingleMarker(nil)).toBe(false)
		expect(Roots.LAYOUT).toBe("core") -- the spec's own mode
		expect(Roots.single).toBe(false)
	end)

	it("in a single-game project the root is the one game", function()
		local fs = fakeFs({
			"studwork.json",
			"deploy.json",
			"default.project.json",
			"src/server/Main.server.luau",
			"modules/my-game/module.luau",
			"studwork/examples/sandbox/default.project.json",
			"studwork/examples/sandbox/src/a.luau",
			"games/stray/default.project.json",
			"games/stray/src/a.luau",
		})
		fs.readFile = function(p)
			assert(p == "deploy.json", "unexpected read " .. p)
			return '{\n  "name": "my-game",\n  "servePort": 34872\n}\n'
		end
		expect(Roots.parentsFor("single-game")).toEqual({})
		expect(Roots.parentsFor("games-repo")).toEqual({ "games" })
		expect(Roots.parentsFor("core")).toEqual({ "games", "examples", "examples/overrides" })
		expect(Roots.gameDirs(fs, "single-game")).toEqual({ "." })
		expect(Roots.rootName(fs)).toBe("my-game")
		expect(Roots.findGame(fs, nil, "single-game")).toBe(".")
		expect(Roots.findGame(fs, "", "single-game")).toBe(".")
		expect(Roots.findGame(fs, ".", "single-game")).toBe(".")
		expect(Roots.findGame(fs, "my-game", "single-game")).toBe(".")
		expect(Roots.findGame(fs, "stray", "single-game")).toBeNil()
		expect(Roots.findGame(fs, "sandbox", "single-game")).toBeNil()
		-- the same tree read as a games repo still finds games/<g> only
		expect(Roots.gameDirs(fs, "games-repo")).toEqual({ "games/stray" })
		local empty = fakeFs({ "studwork.json", "README.md" })
		expect(Roots.gameDirs(empty, "single-game")).toEqual({})
		expect(Roots.findGame(empty, nil, "single-game")).toBeNil()
	end)
end)
