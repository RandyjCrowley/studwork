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

describe("AdoptAudit: dogfood findings (v1.6.0)", function()
	it("resolves a product id from a constants module and skips a vendored library's own calls", function()
		local root = tmpRoot()
		write(
			root .. "/default.project.json",
			'{ "name": "x", "tree": { "$className": "DataModel", "ServerScriptService": { "$path": "src" }, "ServerStorage": { "Lib": { "$path": "lib" } } } }'
		)
		write(root .. "/src/Ids.luau", "return { GemPack = 4444, VIP = 2222 }\n")
		write(
			root .. "/src/Shop.server.luau",
			[[local MarketplaceService = game:GetService("MarketplaceService")
local Ids = require(script.Parent.Ids)
local Sessions = {}
MarketplaceService.ProcessReceipt = function(receipt)
	local data = Sessions[receipt.PlayerId]
	if data.Purchases[receipt.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if receipt.ProductId == Ids.GemPack then
		data.gems += 100
	end
	data.Purchases[receipt.PurchaseId] = true
	return Enum.ProductPurchaseDecision.PurchaseGranted
end
]]
		)
		write(
			root .. "/lib/ProfileService.luau",
			[[local DataStoreService = game:GetService("DataStoreService")
local P = {}
function P.GetProfileStore(name, template)
	local store = DataStoreService:GetDataStore(name)
	return { load = function(key) return store:UpdateAsync(key, function(v) return v end) end }
end
return P
]]
		)
		local report = Audit.run(env, { root }, { write = false })
		expect(report.purchases.products[1].id).toBe(4444)
		expect(table.find(report.purchases.products[1].sold, "gems")).never.toBeNil()
		expect(riskKinds(report, "critical")).toEqual({})
		expect(riskKinds(report).library_implementation).toBe(true)
		fs.removeDir(root)
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

describe("AdoptAudit: dogfood round 2 (v1.6.0)", function()
	it("lists only the DataStore2 master key; combined keys aren't stores of their own", function()
		local report = audit("datastore2")
		local stores = {}
		for _, l in report.libraries do
			table.insert(stores, l.store)
		end
		expect(stores).toEqual({ "DATA" })
		local saveMap = nil
		for _, step in report.plan do
			if string.find(step["do"], "Old stores:", 1, true) then
				saveMap = step["do"]
			end
		end
		expect(saveMap).toContain("Old stores: DATA (DataStore2).")
		expect(string.find(saveMap, "coins (DataStore2)", 1, true)).toBeNil()
	end)

	it("skips Blink-generated Net.luau and Generated*.luau files", function()
		local root = tmpRoot()
		write(
			root .. "/default.project.json",
			'{ "name": "x", "tree": { "$className": "DataModel", "ServerScriptService": { "Mod": { "$path": "modules/my-game/server" } }, "ReplicatedStorage": { "Mod": { "$path": "modules/my-game/client" }, "Gen": { "$path": "src/GeneratedRemotes.luau" } } } }'
		)
		write(
			root .. "/modules/my-game/net.blink",
			"event Buy { from: Client, type: Reliable, call: SingleSync }\n"
		)
		write(root .. "/modules/my-game/server/init.luau", "return {}\n")
		local generated =
			'local r = Instance.new("RemoteEvent")\nr.Name = "BLINK_EVENT"\n_G.blink = r\nreturn {}\n'
		write(root .. "/modules/my-game/server/Net.luau", generated)
		write(root .. "/modules/my-game/client/init.luau", "return {}\n")
		write(root .. "/modules/my-game/client/Net.luau", generated)
		write(root .. "/src/GeneratedRemotes.luau", generated)
		local report = Audit.run(env, { root }, { write = false })
		local paths = {}
		for _, sc in report.scripts do
			table.insert(paths, sc.path)
		end
		table.sort(paths)
		expect(paths).toEqual({ "modules/my-game/client/init.luau", "modules/my-game/server/init.luau" })
		expect(#report.remotes).toBe(0)
		expect(#report.globals).toBe(0)
		fs.removeDir(root)
	end)

	it("rates paid_random_no_odds only for server randomness in a function that grants", function()
		local root = tmpRoot()
		write(
			root .. "/default.project.json",
			'{ "name": "x", "tree": { "$className": "DataModel", "ServerScriptService": { "$path": "src/server" }, "StarterPlayer": { "StarterPlayerScripts": { "$path": "src/client" } } } }'
		)
		-- the client: visual randomness next to a purchase prompt (agent c's orbs)
		write(
			root .. "/src/client/hud.client.luau",
			[[local MarketplaceService = game:GetService("MarketplaceService")
local function placeOrb(orb)
	orb.Position = Vector3.new(math.random(-50, 50), 3, math.random(-50, 50))
end
MarketplaceService:PromptProductPurchase(game.Players.LocalPlayer, 5555)
]]
		)
		-- the server: a receipt handler next to a roll that grants
		write(
			root .. "/src/server/Shop.server.luau",
			[[local MarketplaceService = game:GetService("MarketplaceService")
local Sessions = {}
local function spawnSparkle(part)
	part.Position = Vector3.new(math.random(1, 5), 0, 0)
end
MarketplaceService.ProcessReceipt = function(receipt)
	local data = Sessions[receipt.PlayerId]
	if data.Purchases[receipt.PurchaseId] then return Enum.ProductPurchaseDecision.PurchaseGranted end
	if receipt.ProductId == 6666 then
		data.gems += 10
	end
	data.Purchases[receipt.PurchaseId] = true
	return Enum.ProductPurchaseDecision.PurchaseGranted
end
]]
		)
		local report = Audit.run(env, { root }, { write = false })
		expect(riskKinds(report).paid_random_no_odds).toBeNil()
		-- the receipt history field isn't sold
		local p6666 = nil
		for _, pr in report.purchases.products do
			if pr.id == 6666 then
				p6666 = pr
			end
		end
		expect(p6666.sold).toEqual({ "gems" })
		write(
			root .. "/src/server/Roll.server.luau",
			[[local MarketplaceService = game:GetService("MarketplaceService")
local function rollPet(data)
	local pick = math.random(1, 100)
	table.insert(data.pets, pick)
end
MarketplaceService:PromptProductPurchase(game.Players:GetPlayers()[1], 7777)
]]
		)
		local report2 = Audit.run(env, { root }, { write = false })
		expect(riskKinds(report2, "high").paid_random_no_odds).toBe(true)
		fs.removeDir(root)
	end)

	it("adds a medium risk when a product handler writes save data but no sold field was found", function()
		local root = tmpRoot()
		write(
			root .. "/default.project.json",
			'{ "name": "x", "tree": { "$className": "DataModel", "ServerScriptService": { "$path": "src" } } }'
		)
		write(
			root .. "/src/shop.server.luau",
			[[local MarketplaceService = game:GetService("MarketplaceService")
MarketplaceService.ProcessReceipt = function(receipt)
	local plr = game.Players:GetPlayerByUserId(receipt.PlayerId)
	if receipt.ProductId == 5555 then
		_G.Stores[plr].coins:Increment(500, 0)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end
]]
		)
		local report = Audit.run(env, { root }, { write = false })
		expect(report.purchases.products[1].sold).toEqual({})
		expect(riskKinds(report, "medium").sold_unknown).toBe(true)
		fs.removeDir(root)
	end)

	it("derives keys built by a local helper: not critical", function()
		local root = tmpRoot()
		write(
			root .. "/default.project.json",
			'{ "name": "x", "tree": { "$className": "DataModel", "ServerScriptService": { "$path": "src" } } }'
		)
		write(
			root .. "/src/DataManager.server.luau",
			[[local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local store = DataStoreService:GetDataStore("PlayerSave_v3")
local function keyFor(player)
	return "Player_" .. player.UserId
end
Players.PlayerAdded:Connect(function(player)
	local ok, data = pcall(function()
		return store:UpdateAsync(keyFor(player), function(old) return old end)
	end)
end)
]]
		)
		local report = Audit.run(env, { root }, { write = false })
		expect(report.datastores[1].keyPatterns).toEqual({ "Player_{userId}" })
		expect(riskKinds(report, "critical").key_not_derivable).toBeNil()
		fs.removeDir(root)
	end)
end)

-- (v1.6.0 dogfood r3) a client value passed into a grant/save write; leaderstats in modules/**;
-- a stale $path fails --verify
describe("AdoptAudit round 3", function()
	it("rates a client argument passed into a write call high (client_value_trusted)", function()
		local root = tmpRoot()
		write(
			root .. "/default.project.json",
			'{ "name": "x", "tree": { "$className": "DataModel", "ServerScriptService": { "$path": "src" } } }'
		)
		write(
			root .. "/src/remotes.server.lua",
			[[local giveXp = Instance.new("RemoteEvent")
giveXp.Name = "GiveXP"
giveXp.OnServerEvent:Connect(function(plr, n)
	local s = _G.Stores[plr]
	if s then
		s.xp:Increment(n, 0)
	end
end)
]]
		)
		local report = Audit.run(env, { root }, { write = false })
		local found = nil
		for _, r in report.risks do
			if string.match(r.id, "^client_value_trusted:") then
				found = r
			end
		end
		expect(found ~= nil).toBe(true)
		expect(found.level).toBe("high")
		expect(found.message).toContain("GiveXP")
		expect(found.message).toContain("`n`")
		expect(found.message).toContain("Increment")
		fs.removeDir(root)
	end)

	it("leaderstats a StudWork module creates (modules/**) are not a risk; old code's still are", function()
		local root = tmpRoot()
		write(
			root .. "/default.project.json",
			'{ "name": "x", "tree": { "$className": "DataModel", "ServerScriptService": { "Old": { "$path": "src" }, "Mod": { "$path": "modules/my-game/server" } } } }'
		)
		local ls = [[local Players = game:GetService("Players")
Players.PlayerAdded:Connect(function(player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	stats.Parent = player
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Parent = stats
end)
]]
		write(root .. "/modules/my-game/server/init.luau", "--!strict\n" .. ls .. "return {}\n")
		local report = Audit.run(env, { root }, { write = false })
		expect(riskKinds(report).leaderstats).toBeNil()
		expect(#report.leaderstats).toBe(0)
		write(root .. "/src/Stats.server.luau", ls)
		local report2 = Audit.run(env, { root }, { write = false })
		expect(riskKinds(report2, "medium").leaderstats).toBe(true)
		expect(#report2.leaderstats).toBe(1)
		expect(report2.leaderstats[1].file).toBe("src/Stats.server.luau")
		fs.removeDir(root)
	end)

	it("--verify names a $path that doesn't exist (an optional one may be missing)", function()
		local root = tmpRoot()
		write(
			root .. "/default.project.json",
			'{ "name": "x", "tree": { "$className": "DataModel", "ServerScriptService": { "Server": { "$path": "src/server" }, "Gone": { "$path": "src/old" }, "Maybe": { "$path": { "optional": "src/maybe" } } } } }'
		)
		write(root .. "/src/server/Main.server.luau", "print(1)\n")
		local issues = Audit.verifyIssues(env, root)
		local text = table.concat(issues, "\n")
		expect(text).toContain(
			"stale $path: ServerScriptService.Gone -> src/old doesn't exist; remove the entry from default.project.json"
		)
		expect(string.find(text, "src/maybe", 1, true)).toBeNil()
		expect(string.find(text, "src/server", 1, true)).toBeNil()
		fs.removeDir(root)
	end)
end)
