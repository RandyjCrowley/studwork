--!nocheck
-- tools/adopt --audit / --verify (v1.6.0, docs/framework/adopting.md §1) over the synthetic Rojo
-- projects in tools/lune/testdata/adopt/ (read-only) and throwaway projects in a temp folder.
local Scan = require("tools/lune/AdoptScan.luau")
local Audit = require("tools/lune/AdoptAudit.luau")
local lune = (getmetatable(getfenv(1)) :: any).__index.require
local fs = lune("@lune/fs")
local process = lune("@lune/process")
local roblox = lune("@lune/roblox")
local serde = lune("@lune/serde")

local env = {
	fs = fs,
	process = process,
	roblox = roblox,
	serde = serde,
	Scan = Scan,
	Audit = Audit,
	version = "1.6.0",
}
local DATA = Audit.normalize(process.cwd .. "/tools/lune/testdata/adopt")

local function tmpRoot(): string
	local base = process.env.TMPDIR or (process.cwd .. "/.cache")
	local dir = Audit.normalize(base .. "/studwork-adopt-audit-spec-" .. tostring(math.random(1, 1e9)))
	fs.writeDir(dir)
	return dir
end

local function write(path: string, text: string)
	fs.writeDir(Audit.dirname(path))
	fs.writeFile(path, text)
end

local function audit(...)
	local paths = {}
	for _, p in { ... } do
		table.insert(paths, DATA .. "/" .. p)
	end
	local report, err = Audit.run(env, paths, { write = false })
	assert(report, err)
	return report
end

local function riskKinds(report, level)
	local out = {}
	for _, r in report.risks do
		if level == nil or r.level == level then
			out[string.match(r.id, "^([^:]+)")] = true
		end
	end
	return out
end

local function planIds(report)
	local out = {}
	for _, s in report.plan do
		table.insert(out, s.id)
	end
	return out
end

describe("AdoptAudit paths", function()
	it("normalizes and relativizes", function()
		expect(Audit.normalize("/a/b/../c/./d")).toBe("/a/c/d")
		expect(Audit.relative("/a/b", "/a/b/c/d")).toBe("c/d")
		expect(Audit.relative("/a/b", "/a/x")).toBe("../x")
		expect(Audit.relative("/a/b", "/a/b")).toBe(".")
	end)
end)

describe("AdoptAudit: raw DataStore project", function()
	local report = audit("raw-datastore")
	it("collects every mapped script with class and side, paths relative", function()
		local byPath = {}
		for _, s in report.scripts do
			byPath[s.path] = s
		end
		expect(byPath["src/server/Shop.server.luau"].class).toBe("Script")
		expect(byPath["src/server/Shop.server.luau"].side).toBe("server")
		expect(byPath["src/client/Buttons.client.luau"].side).toBe("client")
		expect(byPath["src/shared/Config.luau"].class).toBe("ModuleScript")
		expect(byPath["src/shared/Config.luau"].side).toBe("shared")
		expect(#report.scripts).toBe(5)
	end)
	it("rates the missing history check, duplicated save logic and a random product critical", function()
		local crit = riskKinds(report, "critical")
		expect(crit.receipt_no_history).toBe(true)
		expect(crit.duplicate_writer).toBe(true)
		expect(crit.product_random).toBe(true)
		local high = riskKinds(report, "high")
		expect(high.remote_trusts_client).toBe(true)
		expect(high.set_without_lock).toBe(true)
		expect(riskKinds(report, "medium").leaderstats).toBe(true)
		expect(riskKinds(report, "low").unused_remote).toBe(true)
	end)
	it(
		"lists the store with its key patterns, products with sold fields, remotes from the project file",
		function()
			expect(#report.datastores).toBe(1)
			expect(report.datastores[1].name).toBe("PlayerData")
			expect(report.datastores[1].keyPatterns).toEqual({ "Player_{userId}" })
			expect(report.purchases.products[1].id).toBe(1000001)
			expect(report.purchases.products[1].sold).toEqual({ "Gems" })
			expect(report.purchases.products[2].random).toBe(true)
			expect(report.remotes[1].name).toBe("BuyItem")
			expect(report.remotes[1].path).toBe("ReplicatedStorage.Remotes.BuyItem")
			expect(#report.remotes[1].handlers).toBe(1)
			expect(#report.remotes[1].fires).toBe(1)
		end
	)
	it("builds the plan in the fixed order, leaving out steps with nothing to do", function()
		expect(planIds(report)).toEqual({
			"init",
			"save-map",
			"legacy-import",
			"purchases",
			"remotes",
			"leaderstats",
			"systems",
			"shrink-legacy",
			"verify",
			"cutover",
		})
		for i, s in report.plan do
			expect(s.n).toBe(i)
			expect(type(s["do"])).toBe("string")
			expect(type(s.check)).toBe("string")
		end
		expect(report.plan[4]["do"]).toContain("Fix first")
		expect(report.plan[3]["do"]).toContain('name = "PlayerData", scope = "v1", key = "Player_{userId}"')
	end)
	it("encodes stable JSON with the §1 keys and no absolute path", function()
		local a = Audit.encodeJson(report)
		local b = Audit.encodeJson(audit("raw-datastore"))
		expect(a).toBe(b)
		local decoded = serde.decode("json", a)
		expect(decoded.reportVersion).toBe(1)
		expect(decoded.tool).toBe("studwork-adopt")
		for _, k in
			{
				"projects",
				"scripts",
				"notExtracted",
				"datastores",
				"libraries",
				"sharedStores",
				"purchases",
				"remotes",
				"leaderstats",
				"ui",
				"globals",
				"risks",
				"plan",
			}
		do
			expect(decoded[k] ~= nil).toBe(true)
		end
		expect(string.find(a, '"notExtracted": []', 1, true) ~= nil).toBe(true)
		expect(string.find(a, '"placeFile": null', 1, true) ~= nil).toBe(true)
		expect(string.find(a, process.cwd, 1, true)).toBeNil()
		expect(string.find(Audit.markdown(report), process.cwd, 1, true)).toBeNil()
	end)
end)

describe("AdoptAudit: save libraries", function()
	it("reads a ProfileService project with a history check as no critical risk", function()
		local report = audit("profileservice")
		expect(report.libraries[1].name).toBe("ProfileService")
		expect(report.libraries[1].keyPattern).toBe("Player_{userId}")
		expect(report.purchases.processReceipt[1].historyCheck).toBe(true)
		expect(riskKinds(report, "critical")).toEqual({})
		expect(report.plan[3]["do"]).toContain('kind = "profileservice", name = "PlayerSaves"')
	end)
	it("reads DataStore2 Combine as one combined source", function()
		local report = audit("datastore2")
		local combined = nil
		for _, l in report.libraries do
			if #l.combined > 0 then
				combined = l
			end
		end
		expect(combined.store).toBe("DATA")
		expect(combined.combined).toEqual({ "coins", "inventory" })
		expect(report.plan[3]["do"]).toContain(
			'kind = "datastore2", name = "DATA", combined = { "coins", "inventory" }'
		)
		expect(string.find(report.plan[3]["do"], 'name = "coins" }', 1, true)).toBeNil()
	end)
end)

describe("AdoptAudit: several places of one universe", function()
	it("lists shared stores and rates a store another place writes critical", function()
		local report = audit("raw-datastore", "lobby")
		expect(report.projects[2].root).toBe("../lobby")
		expect(report.sharedStores).toEqual({ { name = "PlayerData", projects = { ".", "../lobby" } } })
		expect(riskKinds(report, "critical").shared_store).toBe(true)
		local found = false
		for _, s in report.scripts do
			if s.path == "../lobby/src/server/Lobby.server.luau" then
				found = s.project == "../lobby"
			end
		end
		expect(found).toBe(true)
	end)
end)

describe("AdoptAudit: errors and writing", function()
	it("fails on a folder without a project file", function()
		local report, err = Audit.run(env, { DATA }, { write = true })
		expect(report).toBeNil()
		expect(err).toContain("no *.project.json")
	end)
	it("writes both report files into the first project's root only", function()
		local root = tmpRoot()
		write(
			root .. "/default.project.json",
			'{ "name": "x", "tree": { "$className": "DataModel", "ServerScriptService": { "$path": "src" } } }'
		)
		write(root .. "/src/Main.server.luau", "print(1)\n")
		local report = Audit.run(env, { root }, { write = true })
		expect(report ~= nil).toBe(true)
		expect(fs.isFile(root .. "/studwork-adopt-report.json")).toBe(true)
		expect(fs.isFile(root .. "/studwork-adopt-report.md")).toBe(true)
		local entries = fs.readDir(root)
		table.sort(entries)
		expect(entries).toEqual({
			"default.project.json",
			"src",
			"studwork-adopt-report.json",
			"studwork-adopt-report.md",
		})
		fs.removeDir(root)
	end)
	it("labels a $path outside the root as external and skips studwork/ in an adopted project", function()
		local root = tmpRoot()
		write(
			root .. "/game/default.project.json",
			'{ "name": "x", "tree": { "$className": "DataModel", "ServerScriptService": { "Main": { "$path": "src" }, "Shared": { "$path": "../shared" }, "Framework": { "$path": "studwork/packages" } } } }'
		)
		write(root .. "/game/studwork.json", '{ "layout": "single-game", "adopted": true }')
		write(root .. "/game/src/Main.server.luau", "print(1)\n")
		write(
			root .. "/game/studwork/packages/Shop.luau",
			'game:GetService("MarketplaceService").ProcessReceipt = nil\n'
		)
		write(root .. "/shared/Util.luau", "return {}\n")
		local report = Audit.run(env, { root .. "/game" }, { write = false })
		local paths = {}
		for _, s in report.scripts do
			table.insert(paths, s.path)
		end
		table.sort(paths)
		expect(paths).toEqual({ "external:../shared/Util.luau", "src/Main.server.luau" })
		expect(#report.purchases.processReceipt).toBe(0)
		fs.removeDir(root)
	end)
end)

describe("AdoptAudit.verifyIssues", function()
	local function cleanProject(): string
		local root = tmpRoot()
		write(
			root .. "/default.project.json",
			'{ "name": "x", "tree": { "$className": "DataModel", "ServerScriptService": { "$path": "src" } } }'
		)
		write(root .. "/src/Main.server.luau", "print(1)\n")
		write(
			root .. "/studwork-legacy.json",
			'{ "files": [ { "path": "src/Main.server.luau", "checks": ["numbers"], "reason": "old UI numbers" } ] }'
		)
		return root
	end
	it("fails while critical risks remain", function()
		local issues = Audit.verifyIssues(env, DATA .. "/raw-datastore")
		expect(#issues > 0).toBe(true)
		expect(issues[1]).toContain("critical:")
	end)
	it("passes a clean project", function()
		local root = cleanProject()
		expect(Audit.verifyIssues(env, root)).toEqual({})
		fs.removeDir(root)
	end)
	it("fails while studwork-legacy.json lists the purchases check", function()
		local root = cleanProject()
		write(
			root .. "/studwork-legacy.json",
			'{ "files": [ { "path": "src/Main.server.luau", "checks": ["numbers", "purchases"], "reason": "old" } ] }'
		)
		local issues = Audit.verifyIssues(env, root)
		expect(#issues).toBe(1)
		expect(issues[1]).toContain("purchases")
		fs.removeDir(root)
	end)
	it("fails while an onLegacyProduct call is left, ignoring comments and studwork/", function()
		local root = cleanProject()
		write(
			root .. "/modules/g/server/init.luau",
			'-- ctx.shop.onLegacyProduct("A", f) (commented out)\nreturn 1\n'
		)
		write(root .. "/studwork/packages/Shop.luau", 'shop.onLegacyProduct("X", f)\n')
		expect(Audit.verifyIssues(env, root)).toEqual({})
		write(
			root .. "/modules/g/server/init.luau",
			'ctx.shop.onLegacyProduct("CoinPack", function() end, { writesLegacyData = false })\n'
		)
		local issues = Audit.verifyIssues(env, root)
		expect(#issues).toBe(1)
		expect(issues[1]).toContain("modules/g/server/init.luau:1")
		fs.removeDir(root)
	end)
	it("fails closed when the listed place file is missing", function()
		local root = cleanProject()
		write(
			root .. "/studwork.json",
			'{ "layout": "single-game", "adopted": true, "placeFile": "game.rbxl" }'
		)
		local issues = Audit.verifyIssues(env, root)
		expect(#issues).toBe(1)
		expect(issues[1]).toContain("place file missing")
		fs.removeDir(root)
	end)
end)
