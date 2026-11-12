--!nocheck
-- tools/sync-projects (SyncProjects.luau, v1.3.1 R19): the generated Modules entries.
local SyncProjects = require("tools/lune/SyncProjects.luau")

local ENTRIES = {
	{
		name = "Economy",
		kit = "economy",
		dir = "packages/kits/economy/Economy",
		module = "packages/kits/economy/Economy/module.luau",
		client = "packages/kits/economy/Economy/client",
		server = "packages/kits/economy/Economy/server",
	},
	{
		name = "Items",
		kit = "collection",
		dir = "packages/kits/collection/Items",
		module = "packages/kits/collection/Items/module.luau",
		server = "packages/kits/collection/Items/server",
	},
	{
		name = "Board",
		dir = "examples/modules/board",
		module = "examples/modules/board/module.luau",
		server = "examples/modules/board/server",
	},
}

local OLD = [[
{
  "name": "g",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Kits": { "$className": "Folder", "Economy": { "$path": "../../packages/kits/economy/shared" } },
      "GameModule": { "$className": "Folder", "module": { "$path": "modules/g/module.luau" } }
    },
    "ServerScriptService": {
      "Kits": { "$className": "Folder" },
      "Modules": { "$className": "Folder", "MyGame": { "$path": "modules/g/server" } }
    }
  }
}
]]

describe("SyncProjects", function()
	it("round-trips ordered JSON", function()
		local text = '{\n  "b": 1,\n  "a": [\n    "x",\n    true\n  ],\n  "c": {}\n}\n'
		expect(SyncProjects.encode(SyncProjects.decode(text))).toBe(text)
	end)

	it("drops Kits, keeps the project's own entries and generates every kit module", function()
		local out, changes = SyncProjects.sync("games/g/default.project.json", OLD, ENTRIES)
		local p = SyncProjects.decode(out)
		local rs = p.vals.tree.vals.ReplicatedStorage
		local sss = p.vals.tree.vals.ServerScriptService
		expect(rs.vals.Kits).toBeNil()
		expect(sss.vals.Kits).toBeNil()
		expect(#changes >= 2).toBe(true)
		local econ = rs.vals.Modules.vals.Economy
		expect(econ.vals.module.vals["$path"]).toBe("../../packages/kits/economy/Economy/module.luau")
		expect(econ.vals.client.vals["$path"]).toBe("../../packages/kits/economy/Economy/client")
		expect(rs.vals.Modules.vals.Items.vals.client).toBeNil() -- only the parts that exist
		expect(sss.vals.Modules.vals.Economy.vals["$path"]).toBe("../../packages/kits/economy/Economy/server")
		expect(sss.vals.Modules.vals.MyGame.vals["$path"]).toBe("modules/g/server")
		expect(sss.vals.Modules.keys[2]).toBe("MyGame") -- own entries first, in their order
		expect(rs.vals.Modules.vals.Board).toBeNil() -- an example only inside its own folder
		-- idempotent: a synced project has no drift
		local again = SyncProjects.sync("games/g/default.project.json", out, ENTRIES)
		expect(again).toBe(out)
	end)

	it("maps an example module in its own fixture projects, with the right depth", function()
		local out =
			SyncProjects.sync("examples/modules/board/tests/fixture-game/default.project.json", OLD, ENTRIES)
		local p = SyncProjects.decode(out)
		local board = p.vals.tree.vals.ReplicatedStorage.vals.Modules.vals.Board
		expect(board.vals.module.vals["$path"]).toBe("../../../../../examples/modules/board/module.luau")
	end)

	it("(v1.4.0) maps an example module in a project that opts in by mapping it", function()
		local optIn = string.gsub(
			OLD,
			'"GameModule": {',
			'"Modules": { "$className": "Folder", "Board": { "$className": "Folder" } },\n      "GameModule": {',
			1
		)
		local out = SyncProjects.sync("examples/overrides/ov-f/default.project.json", optIn, ENTRIES)
		local p = SyncProjects.decode(out)
		local board = p.vals.tree.vals.ReplicatedStorage.vals.Modules.vals.Board
		expect(board.vals.module.vals["$path"]).toBe("../../../examples/modules/board/module.luau")
		local sss = p.vals.tree.vals.ServerScriptService.vals.Modules
		expect(sss.vals.Board.vals["$path"]).toBe("../../../examples/modules/board/server")
		expect(SyncProjects.sync("examples/overrides/ov-f/default.project.json", out, ENTRIES)).toBe(out)
	end)

	it("(v1.4.0) games repo: core paths carry the submodule folder", function()
		local prefixed = {}
		for _, e in ENTRIES do
			local c = table.clone(e)
			for _, k in { "dir", "module", "client", "server", "shared" } do
				if c[k] then
					c[k] = "roblox-core/" .. c[k]
				end
			end
			table.insert(prefixed, c)
		end
		local out = SyncProjects.sync("games/g/default.project.json", OLD, prefixed)
		local econ = SyncProjects.decode(out).vals.tree.vals.ReplicatedStorage.vals.Modules.vals.Economy
		expect(econ.vals.module.vals["$path"]).toBe(
			"../../roblox-core/packages/kits/economy/Economy/module.luau"
		)
	end)

	it("(v1.5.0) maps a single-game project's root project into studwork/", function()
		expect(SyncProjects.relative(".", "studwork/packages/ui")).toBe("studwork/packages/ui")
		expect(SyncProjects.relative("./", "studwork/deps/Packages")).toBe("studwork/deps/Packages")
		expect(SyncProjects.relative("games/x", "roblox-core/packages/ui")).toBe(
			"../../roblox-core/packages/ui"
		)
		local text = SyncProjects.encode(SyncProjects.toOrdered({
			name = "my-game",
			tree = { ReplicatedStorage = { Modules = { ["$className"] = "Folder" } } },
		}))
		local entries = {
			{
				name = "Economy",
				dir = "studwork/packages/kits/economy/Economy",
				kit = "economy",
				module = "studwork/packages/kits/economy/Economy/module.luau",
				server = "studwork/packages/kits/economy/Economy/server",
			},
		}
		local out = SyncProjects.decode((SyncProjects.sync("default.project.json", text, entries)))
		local econ = out.vals.tree.vals.ReplicatedStorage.vals.Modules.vals.Economy
		expect(econ.vals.module.vals["$path"]).toBe("studwork/packages/kits/economy/Economy/module.luau")
		local server = out.vals.tree.vals.ServerScriptService.vals.Modules.vals.Economy
		expect(server.vals["$path"]).toBe("studwork/packages/kits/economy/Economy/server")
	end)
	-- (v1.7.0, docs/framework/kits/environments.md) Environments.luau from deploy.json
	local function deploy(test, live)
		local function side(ids)
			return `\{ "universeId": {ids[1]}, "placeId": {ids[2]} \}`
		end
		return `\{ "name": "g", "servePort": 34900, "test": {side(test)}, "live": {side(live)} \}`
	end

	it("(v1.7.0) writes the test and live ids from deploy.json", function()
		local out, errors = SyncProjects.environments(deploy({ 111, 222 }, { 333, 444 }))
		expect(#errors).toBe(0)
		expect(out).toBe(
			SyncProjects.ENV_HEADER
				.. "\nreturn {\n"
				.. "\ttest = { placeIds = { 222 }, universeIds = { 111 } },\n"
				.. "\tlive = { placeIds = { 444 }, universeIds = { 333 } },\n"
				.. "}\n"
		)
		local luau = (getmetatable(getfenv(1)) :: any).__index.require("@lune/luau")
		local env = luau.load(out :: string)()
		expect(env.test.placeIds[1]).toBe(222)
		expect(env.live.universeIds[1]).toBe(333)
	end)

	it("(v1.7.0) leaves placeholder ids out and writes return {} when every id is one", function()
		local out = SyncProjects.environments(deploy({ 0, 0 }, { 0, 0 }))
		expect(out).toBe(SyncProjects.ENV_HEADER .. "\nreturn {}\n")
		local partial = SyncProjects.environments(deploy({ 0, -5 }, { 333, 1.5 }))
		expect(partial).toBe(
			SyncProjects.ENV_HEADER .. "\nreturn {\n\tlive = { universeIds = { 333 } },\n}\n"
		)
		local strings = SyncProjects.environments(deploy({ '"111"', 0 }, { 0, '"x"' }))
		expect(strings).toBe(SyncProjects.ENV_HEADER .. "\nreturn {}\n")
	end)

	it("(v1.7.0) writes the test universe id only when it differs from the live one", function()
		local out = SyncProjects.environments(deploy({ 333, 222 }, { 333, 444 }))
		expect(out).toBe(
			SyncProjects.ENV_HEADER
				.. "\nreturn {\n"
				.. "\ttest = { placeIds = { 222 } },\n"
				.. "\tlive = { placeIds = { 444 }, universeIds = { 333 } },\n"
				.. "}\n"
		)
	end)

	it("(v1.7.0) fails when the test and live place ids are equal", function()
		local out, errors =
			SyncProjects.environments(deploy({ 111, 444 }, { 333, 444 }), "games/g/deploy.json")
		expect(out).toBeNil()
		expect(#errors).toBe(1)
		expect(
			string.find(errors[1], "games/g/deploy.json: test.placeId and live.placeId are both 444", 1, true)
		).never.toBeNil()
		local _, bad = SyncProjects.environments("{ not json")
		expect(#bad).toBe(1)
	end)

	it("(v1.7.0) maps src/shared/Localization into LocalizationService, idempotently", function()
		local out, changes =
			SyncProjects.sync("games/g/default.project.json", OLD, ENTRIES, { localization = true })
		local tree = SyncProjects.decode(out).vals.tree
		expect(tree.vals.LocalizationService.vals["$path"]).toBe("src/shared/Localization")
		expect(table.find(changes, "LocalizationService mapped to src/shared/Localization")).never.toBeNil()
		expect((SyncProjects.sync("games/g/default.project.json", out, ENTRIES, { localization = true }))).toBe(
			out
		)
		-- the folder is gone: the generated mapping goes too
		local gone = SyncProjects.sync("games/g/default.project.json", out, ENTRIES, { localization = false })
		expect(SyncProjects.decode(gone).vals.tree.vals.LocalizationService).toBeNil()
		-- a hand-written LocalizationService node (other path) is the project's own: kept
		local own = string.gsub(
			OLD,
			'"ServerScriptService": {',
			'"LocalizationService": { "Tables": { "$path": "loc" } },\n    "ServerScriptService": {',
			1
		)
		local kept = SyncProjects.sync("games/g/default.project.json", own, ENTRIES, { localization = false })
		expect(SyncProjects.decode(kept).vals.tree.vals.LocalizationService.vals.Tables).never.toBeNil()
		-- a caller that doesn't say (new-game copying the template's project) leaves the node alone
		local untouched = SyncProjects.sync("games/g/default.project.json", out, ENTRIES)
		expect(SyncProjects.decode(untouched).vals.tree.vals.LocalizationService.vals["$path"]).toBe(
			"src/shared/Localization"
		)
	end)

	it(
		"(v1.7.0) tools/sync-projects writes Environments.luau, and --check fails on drift and equal ids",
		function()
			local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
			local fs = luneRequire("@lune/fs")
			local process = luneRequire("@lune/process")
			local base = string.gsub(process.env.GUARD_TEST_TMP or process.env.TMPDIR or "/tmp", "/+$", "")
			local dir = `{base}/studwork-sync-env-{os.time()}-{math.random(1, 1e6)}`
			local real = string.gsub(process.exec("pwd", { "-P" }).stdout, "%s+$", "")
			fs.writeDir(dir .. "/games/g/src/shared/Config")
			local ln = process.exec("ln", { "-s", real, dir .. "/roblox-core" })
			expect(ln.ok).toBe(true)
			fs.writeFile(dir .. "/rokit.toml", fs.readFile("rokit.toml")) -- the tool versions, as a games repo has
			local function run(...)
				return process.exec("lune", { "run", "roblox-core/tools/lune/sync-projects.luau", ... }, {
					cwd = dir,
					env = { STUDWORK_CORE_DIR = "roblox-core", STUDWORK_LAYOUT = "games-repo" },
				})
			end
			local target = dir .. "/games/g/src/shared/Config/Environments.luau"
			local ok, err = pcall(function()
				fs.writeFile(dir .. "/games/g/deploy.json", deploy({ 111, 222 }, { 333, 444 }))
				local check = run("--check")
				expect(check.ok).toBe(false)
				expect(string.find(check.stdout, "Environments.luau: drifts from deploy.json", 1, true)).never.toBeNil()
				local write = run()
				expect(write.ok).toBe(true)
				expect(fs.readFile(target)).toBe(
					(SyncProjects.environments(deploy({ 111, 222 }, { 333, 444 })))
				)
				expect(run("--check").ok).toBe(true)
				fs.writeFile(dir .. "/games/g/deploy.json", deploy({ 111, 444 }, { 333, 444 }))
				local equal = run("--check")
				expect(equal.ok).toBe(false)
				expect(string.find(equal.stdout, "test.placeId and live.placeId are both 444", 1, true)).never.toBeNil()
				expect(run().ok).toBe(false) -- writing refuses too, and leaves the old file
				expect(fs.readFile(target)).toBe(
					(SyncProjects.environments(deploy({ 111, 222 }, { 333, 444 })))
				)
			end)
			pcall(fs.removeFile, dir .. "/roblox-core") -- the symlink first: removeDir must not follow it
			pcall(fs.removeDir, dir)
			if not ok then
				error(err, 0)
			end
		end
	)
end)
