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
end)
