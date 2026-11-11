--!nocheck
-- tools/adopt scanners (v1.6.0, docs/framework/adopting.md §1): pure, over one script's source.
local Scan = require("tools/lune/AdoptScan.luau")

local function store(res, name)
	for _, d in res.datastores do
		if d.name == name then
			return d
		end
	end
	return nil
end

local function ops(d)
	local out = {}
	for _, c in d.calls do
		table.insert(out, c.op .. "@" .. c.line .. "=" .. tostring(c.key))
	end
	return table.concat(out, " ")
end

describe("AdoptScan.mask", function()
	it("blanks comments, tokenizes strings and keeps line numbers", function()
		local m = Scan.mask(
			'local a = "x--y" -- note: store:SetAsync(k)\n--[[ long\ncomment ]] local b = [[s]]\nlocal c = `t{1}`'
		)
		expect(string.find(m.code, "SetAsync", 1, true)).toBeNil()
		expect(string.find(m.code, "long", 1, true)).toBeNil()
		expect(m.strings[1].value).toBe("x--y")
		expect(m.strings[2].value).toBe("s")
		expect(m.strings[3].kind).toBe("interp")
		local pos = string.find(m.code, "local b", 1, true)
		expect(Scan.lineOf(m, pos)).toBe(3)
	end)
end)

describe("AdoptScan DataStores", function()
	it("follows a service alias and a store assigned then used, over multi-line calls", function()
		local res = Scan.scan([[
local DSS = game:GetService("DataStoreService")
-- a comment that says store:SetAsync("nope") is ignored
local store = DSS:GetDataStore(
	"PlayerData",
	"v2"
)
local function save(player, data)
	store:SetAsync(
		"Player_" .. player.UserId,
		data
	)
end
]])
		local d = store(res, "PlayerData")
		expect(d).toBeTruthy()
		expect(d.scope).toBe("v2")
		expect(d.kind).toBe("global")
		expect(d.line).toBe(3)
		expect(ops(d)).toBe("SetAsync@8=Player_{userId}")
	end)

	it("finds chained, game.DataStoreService and ordered stores", function()
		local res = Scan.scan([[
local a = game:GetService("DataStoreService"):GetDataStore("Bans"):GetAsync("list")
local top = game.DataStoreService:GetOrderedDataStore("Top")
local pages = top:GetSortedAsync(false, 10)
]])
		expect(ops(store(res, "Bans"))).toBe("GetAsync@1=list")
		local top = store(res, "Top")
		expect(top.kind).toBe("ordered")
		expect(top.calls[1].op).toBe("GetSortedAsync")
		expect(top.calls[1].key).toBeNil()
	end)

	it("ignores GetDataStore on anything that isn't DataStoreService", function()
		local res = Scan.scan(
			'local x = Other:GetDataStore("Nope")\nlocal y = game:GetService("MemoryStoreService"):GetDataStore("Nope2")'
		)
		expect(#res.datastores).toBe(0)
	end)

	it("reports a store name built at runtime as <dynamic>", function()
		local res = Scan.scan(
			'local DSS = game:GetService("DataStoreService")\nlocal s = DSS:GetDataStore("Save" .. version)'
		)
		expect(res.datastores[1].name).toBe("<dynamic>")
	end)

	it("sees calls inside pcall forms and nested callbacks", function()
		local res = Scan.scan([[
local DSS = game:GetService("DataStoreService")
local s = DSS:GetDataStore("Main")
local ok, v = pcall(s.GetAsync, s, "Player_" .. plr.UserId)
local ok2 = pcall(function()
	return s:UpdateAsync(tostring(plr.UserId), function(old)
		s:RemoveAsync("x")
		return old
	end)
end)
]])
		expect(ops(store(res, "Main"))).toBe(
			"GetAsync@3=Player_{userId} UpdateAsync@5={userId} RemoveAsync@6=x"
		)
	end)
end)

describe("AdoptScan.keyPattern", function()
	local function key(src)
		local res = Scan.scan(
			'local DSS = game:GetService("DataStoreService")\nlocal s = DSS:GetDataStore("K")\n' .. src
		)
		local d = store(res, "K")
		return d.calls[#d.calls].key
	end
	it("turns userId expressions into {userId}", function()
		expect(key('s:GetAsync("Player_" .. player.UserId)')).toBe("Player_{userId}")
		expect(key("s:GetAsync(tostring(userId))")).toBe("{userId}")
		expect(key("s:GetAsync(`Player_{plr.UserId}`)")).toBe("Player_{userId}")
		expect(key('local id = player.UserId\ns:GetAsync("user_" .. id)')).toBe("user_{userId}")
		expect(key('local key = "Save_" .. tostring(player.UserId)\ns:GetAsync(key)')).toBe("Save_{userId}")
		expect(key('s:GetAsync(string.format("p_%d", player.UserId))')).toBe("p_{userId}")
		expect(key('s:GetAsync("r_" .. receiptInfo.PlayerId)')).toBe("r_{userId}")
	end)
	it("says <dynamic> when it can't tell, never a guess", function()
		expect(key("s:GetAsync(someKey)")).toBe("<dynamic>")
		expect(key('s:GetAsync("user_" .. id)')).toBe("<dynamic>")
		expect(key("s:GetAsync(player.Name)")).toBe("<dynamic>")
		expect(key("s:GetAsync(makeKey(player))")).toBe("<dynamic>")
	end)
end)

describe("AdoptScan save libraries", function()
	it("finds ProfileService with its store and key pattern", function()
		local res = Scan.scan([[
local ProfileService = require(script.ProfileService)
local Store = ProfileService.GetProfileStore("PlayerSaves", {})
game.Players.PlayerAdded:Connect(function(player)
	local profile = Store:LoadProfileAsync("Player_" .. player.UserId)
end)
]])
		expect(#res.libraries).toBe(1)
		expect(res.libraries[1].name).toBe("ProfileService")
		expect(res.libraries[1].store).toBe("PlayerSaves")
		expect(res.libraries[1].keyPattern).toBe("Player_{userId}")
		expect(res.libraries[1].line).toBe(2)
	end)
	it("finds ProfileStore.New and StartSessionAsync", function()
		local res = Scan.scan([[
local PlayerStore = ProfileStore.New("Saves", {})
local p = PlayerStore:StartSessionAsync(`{player.UserId}`)
]])
		expect(res.libraries[1].name).toBe("ProfileStore")
		expect(res.libraries[1].store).toBe("Saves")
		expect(res.libraries[1].keyPattern).toBe("{userId}")
	end)
	it("finds DataStore2 with Combine", function()
		local res = Scan.scan([[
local DataStore2 = require(x.DataStore2)
DataStore2.Combine("DATA", "coins", "inventory")
local coins = DataStore2("coins", player)
coins:Increment(1)
]])
		expect(#res.libraries).toBe(2)
		expect(res.libraries[1].store).toBe("DATA")
		expect(res.libraries[1].combined).toEqual({ "coins", "inventory" })
		expect(res.libraries[2].store).toBe("coins")
		expect(res.libraries[2].keyPattern).toBe("{userId}")
	end)
end)

describe("AdoptScan purchases", function()
	it("flags a ProcessReceipt without a history check, with products, sold fields and randomness", function()
		local res = Scan.scan([[
local MPS = game:GetService("MarketplaceService")
local GEMS = 1234567
MPS.ProcessReceipt = function(receiptInfo)
	if receiptInfo.ProductId == GEMS then
		data.Gems += 100
	elseif receiptInfo.ProductId == 7654321 then
		table.insert(data.Pets, math.random(1, 3))
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end
]])
		local p = res.purchases
		expect(#p.processReceipt).toBe(1)
		expect(p.processReceipt[1].historyCheck).toBe(false)
		expect(p.processReceipt[1].line).toBe(3)
		expect(#p.products).toBe(2)
		expect(p.products[1].id).toBe(1234567)
		expect(p.products[1].sold).toEqual({ "Gems" })
		expect(p.products[1].random).toBe(false)
		expect(p.products[2].id).toBe(7654321)
		expect(p.products[2].sold).toEqual({ "Pets" })
		expect(p.products[2].random).toBe(true)
	end)
	it("sees a history check in a named handler and a handlers table", function()
		local res = Scan.scan([[
local handlers = {}
handlers[1111111] = function(receipt, player)
	data.Coins += 10
end
local function onReceipt(receiptInfo)
	if history[receiptInfo.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	handlers[receiptInfo.ProductId](receiptInfo)
end
game:GetService("MarketplaceService").ProcessReceipt = onReceipt
]])
		expect(res.purchases.processReceipt[1].historyCheck).toBe(true)
		expect(res.purchases.products[1].id).toBe(1111111)
		expect(res.purchases.products[1].sold).toEqual({ "Coins" })
	end)
	it("finds prompts, passes and ownership checks", function()
		local res = Scan.scan([[
local PASS = 555555
MPS:PromptGamePassPurchase(player, PASS)
MPS:PromptProductPurchase(player, 444444)
MPS.PromptProductPurchaseFinished:Connect(function() end)
if MPS:UserOwnsGamePassAsync(player.UserId, 666666) then end
]])
		local p = res.purchases
		expect(#p.prompts).toBe(3)
		expect(#p.passes).toBe(2)
		expect(p.passes[1].id).toBe(555555)
		expect(p.passes[2].id).toBe(666666)
		expect(p.ownership[1].kind).toBe("UserOwnsGamePassAsync")
		expect(p.products[1].id).toBe(444444)
	end)
end)

describe("AdoptScan remotes", function()
	it("names handlers and fires, and flags a handler that writes a client value", function()
		local res = Scan.scan([[
local RS = game:GetService("ReplicatedStorage")
local buy = RS:WaitForChild("Remotes"):WaitForChild("Buy")
buy.OnServerEvent:Connect(function(player, itemId, amount)
	data.Coins -= amount
end)
RS.Remotes.Ping.OnServerInvoke = function(player, message)
	print(message)
end
local ev = Instance.new("RemoteEvent")
ev.Name = "Made"
ev:FireAllClients()
]])
		local r = res.remotes
		expect(#r.handlers).toBe(2)
		expect(r.handlers[1].name).toBe("Buy")
		expect(r.handlers[1].kind).toBe("OnServerEvent")
		expect(r.handlers[2].name).toBe("Ping")
		expect(r.created[1].name).toBe("Made")
		expect(r.created[1].class).toBe("RemoteEvent")
		expect(r.fires[1].name).toBe("Made")
		expect(#res.trusts).toBe(1)
		expect(res.trusts[1].param).toBe("amount")
	end)
end)

describe("AdoptScan leaderstats, globals, legacy bridge", function()
	it("finds leaderstats with their values", function()
		local res = Scan.scan([[
local ls = Instance.new("Folder")
ls.Name = "leaderstats"
ls.Parent = player
local coins = Instance.new("IntValue")
coins.Name = "Coins"
coins.Parent = ls
]])
		expect(#res.leaderstats).toBe(1)
		expect(res.leaderstats[1].line).toBe(2)
		expect(res.leaderstats[1].values).toEqual({ { name = "Coins", class = "IntValue" } })
	end)
	it("finds _G, shared, asset requires, loadstring and wait()", function()
		local res = Scan.scan(
			"_G.x = 1\nlocal y = shared.y\nlocal m = require(123456)\nloadstring('x')\nwait(1)\ntask.wait(1)"
		)
		local kinds = {}
		for _, g in res.globals do
			table.insert(kinds, g.kind)
		end
		expect(kinds).toEqual({ "_G", "shared", "require(asset)", "loadstring" })
		expect(#res.waits).toBe(1)
	end)
	it("counts onLegacyProduct calls but not mentions in comments or strings", function()
		local res = Scan.scan(
			'-- ctx.shop.onLegacyProduct("A", f)\nlocal s = "onLegacyProduct(x)"\nctx.shop.onLegacyProduct("B", f)'
		)
		expect(#res.onLegacyProduct).toBe(1)
		expect(res.onLegacyProduct[1].line).toBe(3)
	end)
	it("counts lines and empty scripts", function()
		expect(Scan.scan("a()\nb()\n").lines).toBe(2)
		expect(Scan.scan("-- only a comment\n").empty).toBe(true)
	end)
end)
