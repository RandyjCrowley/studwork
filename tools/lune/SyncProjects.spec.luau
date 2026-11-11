--!nocheck
-- tools/sync-projects (SyncProjects.luau, core-v1.3.1 R19): the generated Modules entries.
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
end)
