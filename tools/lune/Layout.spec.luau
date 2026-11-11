--!nocheck
-- tools/ is outside the harness index (packages, games, templates), so load by file path.
local Layout = require("tools/lune/Layout.luau")

local KITS = { "base", "collection", "economy", "engagement", "social" }

local function project(overrides: any?): any
	local rs = {
		Packages = { ["$path"] = "../../deps/Packages" },
		FrameworkClient = { ["$path"] = "../../packages/framework/client" },
		Framework = { ["$path"] = "../../packages/framework/shared" },
		Kits = {
			["$className"] = "Folder",
			Collection = { ["$path"] = "../../packages/kits/collection/shared" },
			Economy = { ["$path"] = "../../packages/kits/economy/shared" },
		},
	}
	local sss = {
		Framework = { ["$path"] = "../../packages/framework/server" },
		Kits = {
			["$className"] = "Folder",
			Collection = { ["$path"] = "../../packages/kits/collection/server" },
			Economy = { ["$path"] = "../../packages/kits/economy/server" },
		},
	}
	if overrides then
		overrides(rs, sss)
	end
	return {
		name = "g",
		tree = { ["$className"] = "DataModel", ReplicatedStorage = rs, ServerScriptService = sss },
	}
end

describe("Layout.normalize", function()
	it("collapses .. and . segments", function()
		expect(Layout.normalize("games/g/../../packages/framework/shared")).toBe("packages/framework/shared")
		expect(Layout.normalize("./a/./b/")).toBe("a/b")
		expect(Layout.normalize("games/g/tests/x/../../../../packages/ui")).toBe("packages/ui")
	end)
end)

describe("Layout.repoIssues", function()
	local function fs(paths: { string })
		local set = {}
		for _, p in paths do
			set[p] = true
		end
		return function(p)
			return set[p] == true
		end
	end
	local GOOD = {
		"packages/framework/shared",
		"packages/framework/server",
		"packages/framework/client",
		"packages/framework/shared/init.luau",
		"packages/kits/economy/shared",
		"packages/kits/economy/server",
	}

	it("is clean for the v1.3 layout", function()
		expect(Layout.repoIssues(fs(GOOD), { "economy" })).toEqual({})
	end)

	it("reports a leftover packages/core, a missing framework part and a half kit", function()
		local paths = table.clone(GOOD)
		table.insert(paths, "packages/core")
		table.insert(paths, "packages/kits/social/shared")
		table.remove(paths, 3) -- packages/framework/client
		local issues = Layout.repoIssues(fs(paths), { "economy", "social" })
		expect(issues).toEqual({
			"packages/framework/client is missing",
			"packages/kits/social/server is missing",
			"packages/core still exists (removed in core v1.3.0; nothing may use it)",
		})
	end)

	it("reports no kits at all", function()
		expect(Layout.repoIssues(fs(GOOD), {})).toEqual({ "no kits under packages/kits" })
	end)
end)

describe("Layout.projectIssues", function()
	it("is clean for a generated game's mapping", function()
		expect(Layout.projectIssues(project(), "games/g", KITS)).toEqual({})
		expect(Layout.projectKits(project())).toEqual({ "Collection", "Economy" })
	end)

	it("resolves $paths relative to the project's folder (examples fixture depth)", function()
		local p = project(function(rs, sss)
			rs.Framework["$path"] = "../../../../../packages/framework/shared"
			rs.FrameworkClient["$path"] = "../../../../../packages/framework/client"
			sss.Framework["$path"] = "../../../../../packages/framework/server"
			rs.Kits = nil
			sss.Kits = nil
		end)
		expect(Layout.projectIssues(p, "examples/modules/x/tests/fixture-game", KITS)).toEqual({})
	end)

	it("flags the v1.2 layout: packages/core mappings and a kit served from the wrong folder", function()
		local p = project(function(rs, sss)
			rs.Core = { ["$path"] = "../../packages/core/shared" }
			sss.Framework = nil
			sss.Kits.Economy["$path"] = "../../packages/kits/compat"
			rs.Kits.Quests = { ["$path"] = "../../packages/kits/quests/shared" }
		end)
		local issues = Layout.projectIssues(p, "games/g", KITS)
		table.sort(issues)
		expect(issues).toEqual({
			"ReplicatedStorage.Core maps packages/core/shared (removed in core v1.3.0)",
			"ReplicatedStorage.Kits.Quests: no kit 'quests' under packages/kits",
			"ServerScriptService.Framework is not mapped (want packages/framework/server)",
			"ServerScriptService.Kits.Economy maps packages/kits/compat (removed in core v1.3.0)",
			"ServerScriptService.Kits.Economy maps packages/kits/compat (want packages/kits/economy/server)",
		})
	end)

	it("handles a project without a tree", function()
		expect(Layout.projectIssues({ name = "x" }, "games/x", KITS)).toEqual({ "no tree" })
	end)
end)
